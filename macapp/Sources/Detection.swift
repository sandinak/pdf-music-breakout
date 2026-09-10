import Foundation
import PDFKit

/// One instrument's part: a display name plus the pages that make it up.
struct Part: Identifiable {
    let id = UUID()
    var name: String     // normalised, filename-safe, e.g. "Clarinet1"
    var label: String    // as printed in the PDF, e.g. "Clarinet in Bb 1"
    var pages: [Int]     // 0-based page indices

    /// Page numbers as a human range string, e.g. "8-14" (1-based).
    var ranges: String {
        var out: [String] = []
        var start: Int? = nil
        var prev = 0
        for p in pages {
            if start == nil { start = p; prev = p }
            else if p == prev + 1 { prev = p }
            else {
                out.append(start! == prev ? "\(start! + 1)" : "\(start! + 1)-\(prev + 1)")
                start = p; prev = p
            }
        }
        if let s = start {
            out.append(s == prev ? "\(s + 1)" : "\(s + 1)-\(prev + 1)")
        }
        return out.joined(separator: ", ")
    }
}

/// A line of text in a page's header band, in top-down coordinates so the
/// geometry reads the same way it does on the printed page.
struct HeaderLine {
    let text: String
    let x0: CGFloat
    let x1: CGFloat
    let yTop: CGFloat
    let pageWidth: CGFloat

    /// True when the line hugs the left or right page margin. Part names on
    /// continuation pages sit in the outer corner, opposite the page number.
    var isOuter: Bool { x0 <= pageWidth * 0.10 || x1 >= pageWidth * 0.90 }
}

enum Detection {

    static let headerBand: CGFloat = 0.15
    static let boilerplateThreshold = 0.4

    /// One line of the header band as PDFKit reports it.
    struct RawRow {
        let text: String
        let x0: CGFloat
        let x1: CGFloat
        let yTop: CGFloat
        let pageWidth: CGFloat
    }

    /// The header band's text rows, in reading order.
    ///
    /// selectionsByLine is the only PDFKit reading API that gives reading
    /// order with positions: page.string runs in content-stream order, and
    /// character bounds are glyph boxes whose heights vary letter by letter,
    /// so they cannot be sorted into rows without scrambling words.
    static func rawRows(_ page: PDFPage, band: CGFloat = headerBand) -> [RawRow] {
        let box = page.bounds(for: .mediaBox)
        guard box.height > 0, box.width > 0 else { return [] }
        // PDF space has its origin bottom-left, so the header is high y.
        let strip = CGRect(x: box.minX, y: box.maxY - box.height * band,
                           width: box.width, height: box.height * band)
        guard let selection = page.selection(for: strip) else { return [] }

        return selection.selectionsByLine().compactMap { line in
            let text = Naming.clean(line.string ?? "")
            guard !text.isEmpty else { return nil }
            let r = line.bounds(for: page)
            guard !r.isNull else { return nil }
            return RawRow(text: text,
                          x0: r.minX - box.minX,
                          x1: r.maxX - box.minX,
                          yTop: box.maxY - r.maxY,
                          pageWidth: box.width)
        }
    }

    /// Break a row that holds several header items into separate lines.
    ///
    /// On continuation pages the part name, the title and the page number sit
    /// side by side on one baseline, and PDFKit hands them back as a single
    /// line -- "Piano/Vocal Abracadabra 3". Only the title is known well
    /// enough to split on, which is enough: what remains on either side is
    /// the part name and the page number, and each keeps the outer edge it
    /// actually sits against.
    static func split(_ row: RawRow, title: String) -> [HeaderLine] {
        let whole = HeaderLine(text: row.text, x0: row.x0, x1: row.x1,
                               yTop: row.yTop, pageWidth: row.pageWidth)
        guard !title.isEmpty,
              row.text.localizedCaseInsensitiveContains(title),
              row.text.compare(title, options: .caseInsensitive) != .orderedSame
        else { return [whole] }

        let pieces = row.text.components(separatedBy: title)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:")) }
            .enumerated()
            .filter { !$0.element.isEmpty }
        let middle = row.pageWidth / 2
        var out: [HeaderLine] = []
        for (i, piece) in pieces {
            // A piece keeps only the outer edge it genuinely sits against;
            // anything from the middle of the row gets neither.
            let touchesLeft = (i == 0)
            let touchesRight = (i == row.text.components(separatedBy: title).count - 1)
            out.append(HeaderLine(text: piece,
                                  x0: touchesLeft ? row.x0 : middle,
                                  x1: touchesRight ? row.x1 : middle,
                                  yTop: row.yTop,
                                  pageWidth: row.pageWidth))
        }
        return out.isEmpty ? [] : out
    }

    /// Text lines in the top `band` fraction of a page.
    static func headerLines(_ page: PDFPage, band: CGFloat = headerBand,
                            title: String = "") -> [HeaderLine] {
        rawRows(page, band: band).flatMap { split($0, title: title) }
    }

    /// The document's own title, if it says anything useful.
    static func metadataTitle(_ doc: PDFDocument) -> String {
        let attrs = doc.documentAttributes ?? [:]
        var meta = Naming.clean(attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "")
        guard !meta.isEmpty, meta.count < 80, !Naming.junkTitle.matches(meta) else { return "" }

        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        if creator == "pdf-music-breakout" {
            // One of our own part files, titled "Song - Part". Drop the part
            // so a second pass over it doesn't stack the name up again.
            let subject = Naming.clean(attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? "")
            let suffix = " - \(subject)"
            if !subject.isEmpty, meta.lowercased().hasSuffix(suffix.lowercased()) {
                meta = String(meta.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return meta
    }

    /// Best guess at the song title, so it can be excluded from labels.
    ///
    /// The printed page beats the metadata: conversion tools cheerfully stamp
    /// things like "Merged with PDFCreator Online" into the title field.
    static func findTitle(_ doc: PDFDocument, _ pagesLines: [[HeaderLine]]) -> String {
        let n = pagesLines.count
        var counts: [String: Int] = [:]

        for lines in pagesLines {
            var seen = Set<String>()
            for text in Set(lines.map(\.text)) {
                guard text.count >= 2, text.count <= 70, Int(text) == nil else { continue }
                // The part name is not the title, however often it appears.
                if !Naming.isInstrumentName(text) { seen.insert(text) }
                // A running head reads "Song - Part - p.2", so its leading
                // segment is the title even though the whole line is unique.
                let segments = Naming.runningHeadSplit
                    .replacing(text, with: "\u{0000}").components(separatedBy: "\u{0000}")
                if segments.count >= 2 {
                    let lead = segments[0].trimmingCharacters(in: .whitespaces)
                    if lead.count >= 2, lead.count <= 60, !Naming.isInstrumentName(lead) {
                        seen.insert(lead)
                    }
                }
            }
            for s in seen { counts[s, default: 0] += 1 }
        }

        // Highest count wins; ties break on the lexicographically smaller
        // string so the answer is stable run to run.
        if let best = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }) {
            if Double(best.value) >= max(2.0, Double(n) * 0.3) { return best.key }
        }
        return metadataTitle(doc)
    }

    /// Header strings repeated on most pages that are not instrument names:
    /// the arranger credit, the dedication line, licence notices.
    static func findBoilerplate(_ pagesLines: [[HeaderLine]],
                                threshold: Double = boilerplateThreshold) -> Set<String> {
        let n = pagesLines.count
        var counts: [String: Int] = [:]
        for lines in pagesLines {
            for text in Set(lines.map(\.text)) { counts[text, default: 0] += 1 }
        }
        let floor = max(3.0, Double(n) * threshold)
        return Set(counts.filter { Double($0.value) >= floor && !Naming.isInstrumentName($0.key) }
                         .map(\.key))
    }

    /// Pick the part name printed on one page, or nil if there isn't one.
    static func detectLabel(_ lines: [HeaderLine], title: String,
                            boilerplate: Set<String>) -> String? {
        let candidates = lines.filter { line in
            let t = line.text
            if t.isEmpty || t.count > 48 { return false }
            // Notation set as text: no font information here, so judge by shape.
            if !Naming.looksLikeWords(t) { return false }
            if !title.isEmpty, t.lowercased() == title.lowercased() { return false }
            if boilerplate.contains(t) { return false }
            if Naming.boilerplate.matchesPrefix(t) { return false }
            if Naming.expression.matchesPrefix(t) { return false }
            return true
        }
        guard !candidates.isEmpty else { return nil }

        let topY = candidates.map(\.yTop).min() ?? 0
        func score(_ line: HeaderLine) -> Int {
            var s = 0
            if Naming.instrument.matches(line.text) { s += 100 }
            if line.isOuter { s += 30 }
            if line.yTop <= topY + 4.0 { s += 20 }
            return s
        }

        let best = candidates
            .map { (score($0), -$0.yTop, $0) }
            .max { a, b in (a.0, a.1) < (b.0, b.1) }
        guard let winner = best, winner.0 >= 50 else { return nil }
        return winner.2.text
    }

    /// Read the part name printed on each page.
    ///
    /// Returns one entry per page -- the label where a part begins, nil where
    /// the page carries no name of its own -- plus the song title.
    static func pageLabels(_ doc: PDFDocument,
                           band: CGFloat = headerBand) -> (labels: [String?], title: String) {
        var pagesRows: [[RawRow]] = []
        for i in 0..<doc.pageCount {
            pagesRows.append(doc.page(at: i).map { rawRows($0, band: band) } ?? [])
        }

        // First pass finds the title from the rows as PDFKit reports them:
        // pages that print the title on its own line are enough to settle it.
        let unsplit = pagesRows.map { rows in
            rows.map { HeaderLine(text: $0.text, x0: $0.x0, x1: $0.x1,
                                  yTop: $0.yTop, pageWidth: $0.pageWidth) }
        }
        let title = findTitle(doc, unsplit)

        // Second pass can now break apart the rows that ran the part name,
        // the title and the page number together.
        let pagesLines = pagesRows.map { rows in rows.flatMap { split($0, title: title) } }
        let boilerplate = findBoilerplate(pagesLines)

        let labels: [String?] = pagesLines.map { lines in
            guard let raw = detectLabel(lines, title: title, boilerplate: boilerplate) else {
                return nil
            }
            let stripped = Naming.stripRunningHead(raw, title: title)
            return stripped.isEmpty ? nil : stripped
        }
        return (labels, title)
    }

    /// Turn per-page labels into parts, plus any leading front matter.
    ///
    /// An unlabelled page continues the part above it. Parts are grouped by
    /// normalised name, so one interrupted and resumed later lands in a
    /// single file rather than two.
    static func group(labels: [String?], aliases: [String: String],
                      pageCount: Int) -> (parts: [Part], front: [Int]) {
        guard let first = labels.firstIndex(where: { $0 != nil }) else {
            return ([], Array(0..<pageCount))
        }
        let front = Array(0..<first)

        var parts: [Part] = []
        var index: [String: Int] = [:]
        var current: String? = nil
        for i in first..<pageCount {
            if let l = labels[i] { current = l }
            guard let label = current else { continue }
            let name = Naming.normalise(label, aliases: aliases)
            if let at = index[name] {
                parts[at].pages.append(i)
            } else {
                index[name] = parts.count
                parts.append(Part(name: name, label: label, pages: [i]))
            }
        }
        return (parts, front)
    }
}
