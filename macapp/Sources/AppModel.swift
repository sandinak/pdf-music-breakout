import Foundation
import PDFKit
import AppKit
import SwiftUI

/// One page as the review list shows it.
struct PageRow: Identifiable {
    let id: Int          // 0-based page index
    var label: String?   // set where a part begins, nil where it continues
    var detected: String?// what detection originally proposed
    var size: CGSize
    var thumbnail: NSImage?

    var number: Int { id + 1 }
    var isLandscape: Bool { size.width > size.height }
}

/// A file that would be written, recomputed as the boundaries are edited.
struct PlannedFile: Identifiable {
    let id = UUID()
    let filename: String
    let label: String
    let pageCount: Int
    let ranges: String
}

@MainActor
final class AppModel: ObservableObject {
    /// One model for the window and for files opened from the Finder.
    static let shared = AppModel()

    @Published private(set) var document: PDFDocument?
    @Published private(set) var sourceName = ""
    @Published private(set) var pages: [PageRow] = []
    @Published private(set) var front: [Int] = []
    @Published private(set) var parts: [Part] = []
    @Published private(set) var files: [PlannedFile] = []
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published private(set) var busy = false

    @Published var options = ExportOptions() {
        didSet { replan() }
    }

    var isLoaded: Bool { document != nil }

    // MARK: - Loading

    func open(url: URL) {
        busy = true
        notice = nil
        defer { busy = false }

        guard let doc = PDFDocument(url: url) else {
            fail("That file could not be opened as a PDF.")
            return
        }
        guard !doc.isLocked else {
            fail("This PDF is password-protected. Unlock it first.")
            return
        }
        guard doc.pageCount > 0 else {
            fail("This PDF has no pages.")
            return
        }

        document = doc
        sourceName = url.lastPathComponent

        let (labels, title) = Detection.pageLabels(doc)
        options.title = title.isEmpty ? Self.titleFromFilename(url) : title
        options.prefix = Self.prefixFromFolder(url)

        pages = (0..<doc.pageCount).map { i in
            let page = doc.page(at: i)
            return PageRow(id: i,
                           label: labels[i],
                           detected: labels[i],
                           size: page?.bounds(for: .mediaBox).size ?? .zero,
                           thumbnail: nil)
        }
        replan()
        warnIfSuspicious(doc: doc, labels: labels)
        loadThumbnails()
    }

    private func fail(_ message: String) {
        document = nil
        pages = []
        parts = []
        files = []
        notice = message
        noticeIsError = true
    }

    /// Detection is quiet when it goes wrong, so say so when the result looks
    /// implausible rather than letting it pass unremarked.
    private func warnIfSuspicious(doc: PDFDocument, labels: [String?]) {
        let textPages = (0..<doc.pageCount).reduce(0) { count, i in
            let s = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return count + ((s?.isEmpty == false) ? 1 : 0)
        }
        if textPages < doc.pageCount / 2 {
            notice = "These pages have little or no text, so this looks like a scan. "
                   + "Detection will be poor — tick the pages that start each part by hand."
            noticeIsError = false
        } else if parts.count > max(6, doc.pageCount * 6 / 10) {
            notice = "Nearly every page looks like a new part, which usually means the "
                   + "header was misread. Check the ticks before exporting."
            noticeIsError = false
        }
    }

    private func loadThumbnails() {
        guard let doc = document else { return }
        let indices = pages.map(\.id)
        Task.detached(priority: .userInitiated) {
            for i in indices {
                guard let page = doc.page(at: i) else { continue }
                let image = page.thumbnail(of: CGSize(width: 108, height: 140),
                                           for: .mediaBox)
                await MainActor.run { [weak self] in
                    guard let self, i < self.pages.count else { return }
                    self.pages[i].thumbnail = image
                }
            }
        }
    }

    // MARK: - Editing

    func setBoundary(_ on: Bool, at index: Int) {
        guard pages.indices.contains(index) else { return }
        if on {
            let fallback = pages[index].detected ?? "Part \(index + 1)"
            pages[index].label = fallback
        } else {
            pages[index].label = nil
        }
        replan()
    }

    func rename(_ text: String, at index: Int) {
        guard pages.indices.contains(index) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        pages[index].label = trimmed.isEmpty ? nil : trimmed
        replan()
    }

    func resetToDetected() {
        for i in pages.indices { pages[i].label = pages[i].detected }
        replan()
    }

    /// What part a page belongs to, for the "continues …" hint.
    func inheritedLabel(before index: Int) -> String? {
        for i in stride(from: index, through: 0, by: -1) {
            if let l = pages[i].label { return l }
        }
        return nil
    }

    private func replan() {
        guard let doc = document else { parts = []; files = []; return }
        let labels = pages.map(\.label)
        let grouped = Detection.group(labels: labels,
                                      aliases: Naming.defaultAliases,
                                      pageCount: doc.pageCount)
        parts = grouped.parts
        front = grouped.front
        let extra = options.frontMatter == .attach ? front.count : 0
        files = grouped.parts.map {
            PlannedFile(filename: options.filename(for: $0),
                        label: $0.label,
                        pageCount: $0.pages.count + extra,
                        ranges: $0.ranges)
        }
    }

    // MARK: - Export

    func export(to folder: URL) {
        guard let doc = document else { return }
        busy = true
        defer { busy = false }
        do {
            let written = try Splitter.export(parts: parts, front: front, from: doc,
                                              options: options, into: folder)
            let refitted = written.reduce(0) { $0 + $1.refitted }
            var message = "Wrote \(written.count) part\(written.count == 1 ? "" : "s") "
                        + "to \(folder.lastPathComponent)."
            if refitted > 0 { message += " \(refitted) page(s) were fitted to the paper size." }
            notice = message
            noticeIsError = false
        } catch {
            notice = "Could not write the parts: \(error.localizedDescription)"
            noticeIsError = true
        }
    }

    // MARK: - Defaults

    /// "Abracadabra-ALL.pdf" -> "Abracadabra"
    private static func titleFromFilename(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return RE(#"[-_ ]+(all|full|complete|combined|book)$"#)
            .replacing(stem, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A folder named "03-Abracadabra" means the files want an "03-" prefix.
    private static func prefixFromFolder(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard let n = RE(#"^(\d{1,3})[-_ ]"#).group(folder, 1) else { return "" }
        return "\(n)-"
    }
}
