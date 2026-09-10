import Foundation
import PDFKit
import CoreGraphics

/// What to do about page size on the way out.
enum Paper: String, CaseIterable, Identifiable {
    case auto, keep, letter, a4, tabloid, legal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:    return "Auto — match the document"
        case .keep:    return "Keep every page as-is"
        case .letter:  return "US Letter"
        case .a4:      return "A4"
        case .tabloid: return "Tabloid"
        case .legal:   return "US Legal"
        }
    }

    var fixedSize: CGSize? {
        switch self {
        case .letter:  return CGSize(width: 612, height: 792)
        case .legal:   return CGSize(width: 612, height: 1008)
        case .tabloid: return CGSize(width: 792, height: 1224)
        case .a4:      return CGSize(width: 595.28, height: 841.89)
        case .auto, .keep: return nil
        }
    }

    /// The target page size, or nil to leave every page exactly as it is.
    func resolve(for doc: PDFDocument) -> CGSize? {
        if self == .keep { return nil }
        if let fixed = fixedSize { return fixed }
        // Auto: whichever size most of the document already uses, so the
        // parts stay untouched and only an oversized score is fitted.
        var counts: [String: (CGSize, Int)] = [:]
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let s = p.bounds(for: .mediaBox).size
            let key = "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))"
            counts[key, default: (s, 0)].1 += 1
        }
        return counts.values.max { $0.1 < $1.1 }?.0
    }
}

enum Rotation: String, CaseIterable, Identifiable {
    case cw, ccw, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cw:   return "Clockwise"
        case .ccw:  return "Anticlockwise"
        case .none: return "Don't rotate"
        }
    }
}

enum FrontMatter: String, CaseIterable, Identifiable {
    case skip, attach
    var id: String { rawValue }
    var label: String {
        self == .skip ? "Leave out" : "Add to every part"
    }
}

struct ExportOptions {
    var title = ""
    var prefix = ""
    var paper: Paper = .auto
    var rotation: Rotation = .cw
    var margin: CGFloat = 0
    var frontMatter: FrontMatter = .skip
    var template = "{prefix}{title}-{part}.pdf"

    func filename(for part: Part) -> String {
        let name = template
            .replacingOccurrences(of: "{prefix}", with: prefix)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{part}", with: part.name)
        return Naming.safeFilename(name)
    }
}

enum Splitter {

    /// Redraw a page onto `paper`, rotating it if that makes it print larger.
    ///
    /// Drawing through Core Graphics keeps the page as vectors rather than
    /// rasterising it, so a fitted conductor score stays sharp.
    static func fitted(_ page: PDFPage, to paper: CGSize, margin: CGFloat,
                       rotation: Rotation) -> PDFPage? {
        guard let source = page.pageRef else { return nil }
        let box = page.bounds(for: .mediaBox)
        let sw = box.width, sh = box.height
        let availableW = paper.width - 2 * margin
        let availableH = paper.height - 2 * margin
        guard availableW > 0, availableH > 0, sw > 0, sh > 0 else { return nil }

        var turn = rotation
        if turn == .none {
            // nothing to decide
        } else {
            let upright = min(availableW / sw, availableH / sh)
            let turned = min(availableW / sh, availableH / sw)
            if turned <= upright * 1.01 { turn = .none }
        }

        let effectiveW = (turn == .none) ? sw : sh
        let effectiveH = (turn == .none) ? sh : sw
        let scale = min(availableW / effectiveW, availableH / effectiveH)
        let drawnW = effectiveW * scale, drawnH = effectiveH * scale
        let offsetX = (paper.width - drawnW) / 2
        let offsetY = (paper.height - drawnH) / 2

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.translateBy(x: offsetX, y: offsetY)
        ctx.scaleBy(x: scale, y: scale)
        switch turn {
        case .cw:
            // Source bottom-left lands top-left, so the page turns clockwise.
            ctx.translateBy(x: 0, y: sw)
            ctx.rotate(by: -.pi / 2)
        case .ccw:
            ctx.translateBy(x: sh, y: 0)
            ctx.rotate(by: .pi / 2)
        case .none:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(source)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()

        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Build one part's PDF. Pages that already fit are copied untouched, so
    /// they keep their original quality; only oversized pages are redrawn.
    static func build(part: Part, front: [Int], from doc: PDFDocument,
                      options: ExportOptions) -> (data: Data, refitted: Int)? {
        let out = PDFDocument()
        let paper = options.paper.resolve(for: doc)
        var refitted = 0
        var index = 0

        let attach = options.frontMatter == .attach ? front : []
        for pageNumber in attach + part.pages {
            guard let source = doc.page(at: pageNumber) else { continue }
            let size = source.bounds(for: .mediaBox).size
            let fits = paper == nil
                || (size.width <= paper!.width + 1 && size.height <= paper!.height + 1)

            if fits {
                guard let copy = source.copy() as? PDFPage else { continue }
                out.insert(copy, at: index)
            } else if let target = paper,
                      let redrawn = fitted(source, to: target,
                                           margin: options.margin,
                                           rotation: options.rotation) {
                out.insert(redrawn, at: index)
                refitted += 1
            } else {
                guard let copy = source.copy() as? PDFPage else { continue }
                out.insert(copy, at: index)
            }
            index += 1
        }
        guard index > 0 else { return nil }

        let author = (doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
        out.documentAttributes = [
            PDFDocumentAttribute.titleAttribute:
                options.title.isEmpty ? part.label : "\(options.title) - \(part.label)",
            PDFDocumentAttribute.authorAttribute: author,
            PDFDocumentAttribute.subjectAttribute: part.label,
            PDFDocumentAttribute.creatorAttribute: "pdf-music-breakout",
            PDFDocumentAttribute.producerAttribute: "pdf-music-breakout",
        ]
        guard let data = out.dataRepresentation() else { return nil }
        return (data, refitted)
    }

    struct Written {
        let url: URL
        let pages: Int
        let refitted: Int
    }

    /// Write every part into `folder`.
    static func export(parts: [Part], front: [Int], from doc: PDFDocument,
                       options: ExportOptions, into folder: URL) throws -> [Written] {
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        var written: [Written] = []
        for part in parts {
            guard let built = build(part: part, front: front, from: doc, options: options)
            else { continue }
            let url = folder.appendingPathComponent(options.filename(for: part))
            try built.data.write(to: url, options: .atomic)
            let extra = options.frontMatter == .attach ? front.count : 0
            written.append(Written(url: url,
                                   pages: part.pages.count + extra,
                                   refitted: built.refitted))
        }
        return written
    }
}
