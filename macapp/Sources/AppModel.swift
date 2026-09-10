import Foundation
import PDFKit
import AppKit
import SwiftUI

/// One page, and the part it belongs to.
///
/// Detection marks where parts begin; every page after one of those marks
/// carries the same part forward. Keeping the answer on each page rather than
/// only on the page that starts a part is what lets a page be dragged out of
/// the wrong part and into the right one.
struct PageRow: Identifiable {
    let id: Int             // 0-based page index
    var part: String?       // the part it belongs to; nil is front matter
    var detected: String?   // the name read off this page's own header
    var detectedPart: String?  // what it belonged to when detection ran
    var size: CGSize
    var thumbnail: NSImage?

    var number: Int { id + 1 }
    var isLandscape: Bool { size.width > size.height }
}

/// A row in the tree. Parts sit at the root, their remaining pages beneath.
enum NodeID: Hashable {
    case part(String)   // keyed by normalised name, so renames regroup
    case front
    case page(Int)
}

/// One root of the tree: a part that will be written, or the front matter
/// that is attached to (or left out of) every part.
struct PartGroup: Identifiable {
    let id: NodeID
    let label: String       // as printed, or as renamed since
    let filename: String?   // what will be written; nil for front matter
    let pages: [Int]
    let ranges: String

    var isFront: Bool { id == .front }
    /// The page the root row stands for, and the ones nested under it.
    var first: Int? { pages.first }
    var rest: [Int] { Array(pages.dropFirst()) }
}

/// A row as the list draws it, once the collapsed groups are folded away.
enum TreeRow: Identifiable {
    case group(PartGroup)
    case page(Int, in: PartGroup)

    var id: NodeID {
        switch self {
        case .group(let g): return g.id
        case .page(let i, _): return .page(i)
        }
    }
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

    /// The roots of the tree: one per part, plus the front matter.
    @Published private(set) var groups: [PartGroup] = []
    /// Which roots are open. Collapsed by default, so the top level reads as
    /// the list of files that will be written.
    @Published var expanded: Set<NodeID> = []
    /// What is selected in the main window, and so what the partner preview
    /// window shows -- the two always agree about what is being looked at.
    @Published var selection: NodeID?
    /// How that window sizes the page. Kept here so the View menu can drive it
    /// whichever window happens to be in front.
    @Published var previewZoom: PageZoom = .fitWidth
    /// The scale actually in force, reported back by the preview for its readout.
    @Published var previewScale: CGFloat = 1

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

        // A page with no name of its own belongs to the part above it.
        var owner: String? = nil
        pages = (0..<doc.pageCount).map { i in
            if let read = labels[i] { owner = read }
            let page = doc.page(at: i)
            return PageRow(id: i,
                           part: owner,
                           detected: labels[i],
                           detectedPart: owner,
                           size: page?.bounds(for: .mediaBox).size ?? .zero,
                           thumbnail: nil)
        }
        expanded = []
        replan()
        selection = node(for: 0)
        warnIfSuspicious(doc: doc, labels: labels)
        loadThumbnails()
    }

    private func fail(_ message: String) {
        document = nil
        pages = []
        groups = []
        selection = nil
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

    /// Split a part so that `index` begins one of its own.
    ///
    /// The pages that ran on from it come too: a boundary that detection put
    /// one page late is fixed by ticking the page it should have been on.
    func split(at index: Int) {
        guard pages.indices.contains(index) else { return }
        var name = pages[index].detected ?? "Part \(index + 1)"
        if normalised(name) == pages[index].part.map(normalised) {
            // Its header names the part it is already in, so a split needs a
            // name of its own -- grouping would otherwise put it straight
            // back, and the tick would appear to do nothing.
            name = fresh("Part \(index + 1)")
        }
        assign(name, toRunAt: index)
    }

    private func normalised(_ label: String) -> String {
        Naming.normalise(label, aliases: Naming.defaultAliases)
    }

    /// A name no existing part answers to.
    private func fresh(_ base: String) -> String {
        let taken = Set(parts.map(\.name))
        var candidate = base
        var n = 2
        while taken.contains(normalised(candidate)) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Fold a part into the one above it, for a boundary that is not real.
    func mergeUp(at index: Int) {
        guard index > 0, pages.indices.contains(index) else { return }
        assign(pages[index - 1].part, toRunAt: index)
    }

    /// Rename a whole part, from any of its pages.
    func rename(_ text: String, forPart old: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { return }
        for i in pages.indices where pages[i].part == old { pages[i].part = trimmed }
        replan()
    }

    /// Act on a drag from one row onto another.
    func drop(_ source: NodeID, on target: NodeID) {
        guard source != target else { return }
        let moved: [Int]
        switch source {
        case .page(let i):  moved = [i]
        case .part, .front: moved = groups.first { $0.id == source }?.pages ?? []
        }
        guard !moved.isEmpty else { return }
        // A page dropped on itself, or a part on one of its own pages.
        if case .page(let onto) = target, moved.contains(onto) { return }
        move(pages: moved, to: target)
    }

    /// Move pages into another part, or out to the front matter.
    func move(pages moved: [Int], to target: NodeID) {
        let label = self.label(of: target)
        for i in moved where pages.indices.contains(i) { pages[i].part = label }
        replan()
        // Land the selection on what was moved, and open the part it went to.
        if let first = moved.sorted().first {
            reveal(first)
            selection = node(for: first)
        }
    }

    func resetToDetected() {
        for i in pages.indices { pages[i].part = pages[i].detectedPart }
        replan()
    }

    /// Give `index` and the pages running on from it a new owner.
    private func assign(_ label: String?, toRunAt index: Int) {
        let old = pages[index].part
        guard old != label else { return }
        var i = index
        while i < pages.count, pages[i].part == old {
            pages[i].part = label
            i += 1
        }
        replan()
        // Show what just happened, wherever the page ended up.
        reveal(index)
        selection = node(for: index)
    }

    private func label(of target: NodeID) -> String? {
        switch target {
        case .front:            return nil
        case .part:             return groups.first { $0.id == target }?.label
        case .page(let index):  return pages.indices.contains(index)
                                     ? pages[index].part : nil
        }
    }

    // MARK: - The tree

    /// The rows to draw, with collapsed groups folded away.
    var rows: [TreeRow] {
        groups.flatMap { group -> [TreeRow] in
            guard expanded.contains(group.id) else { return [.group(group)] }
            return [.group(group)] + group.rest.map { .page($0, in: group) }
        }
    }

    func group(containing index: Int) -> PartGroup? {
        groups.first { $0.pages.contains(index) }
    }

    /// The row that stands for a page: its own, or the root it begins.
    func node(for index: Int) -> NodeID {
        guard let group = group(containing: index) else { return .page(index) }
        return group.first == index ? group.id : .page(index)
    }

    /// Whether a page begins its part, which is what the preview's tick means.
    func isPartStart(_ index: Int) -> Bool {
        group(containing: index)?.first == index
    }

    /// Open the group a page sits in, so the row can be seen and selected.
    func reveal(_ index: Int) {
        guard let group = group(containing: index), group.first != index else { return }
        expanded.insert(group.id)
    }

    func toggle(_ id: NodeID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func expandAll()   { expanded = Set(groups.map(\.id)) }
    func collapseAll() { expanded = [] }

    // MARK: - Preview

    /// The page the partner preview window is showing: the selected page, or
    /// the first page of the selected part.
    var previewPage: Int? {
        switch selection {
        case .page(let i):  return pages.indices.contains(i) ? i : nil
        case .part, .front: return groups.first { $0.id == selection }?.first
        case nil:           return nil
        }
    }

    /// Show a page in the partner window, and mark it in the tree.
    func select(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        reveal(index)
        selection = node(for: index)
    }

    /// Page the preview forwards or back, stopping at either end.
    func stepSelection(by delta: Int) {
        let next = (previewPage ?? 0) + delta
        guard pages.indices.contains(next) else { return }
        select(next)
    }

    /// Zoom relative to what is on screen now, which is what the reader means
    /// by "bigger" whether they were fitting the width or at an exact size.
    func zoom(by factor: CGFloat) {
        previewZoom = .factor(min(10, max(0.1, previewScale * factor)))
    }

    /// Rebuild the parts, the files they would produce, and the tree.
    ///
    /// Pages are grouped by name rather than by position, so a part that is
    /// interrupted and resumed later -- or one dragged back together by
    /// hand -- lands in a single file, as `Detection.group` does.
    private func replan() {
        guard document != nil else { parts = []; files = []; groups = []; front = []; return }
        var built: [Part] = []
        var index: [String: Int] = [:]
        var frontPages: [Int] = []
        for page in pages {
            guard let label = page.part else { frontPages.append(page.id); continue }
            let name = Naming.normalise(label, aliases: Naming.defaultAliases)
            if let at = index[name] {
                built[at].pages.append(page.id)
            } else {
                index[name] = built.count
                built.append(Part(name: name, label: label, pages: [page.id]))
            }
        }
        parts = built
        front = frontPages

        let extra = options.frontMatter == .attach ? front.count : 0
        files = built.map {
            PlannedFile(filename: options.filename(for: $0),
                        label: $0.label,
                        pageCount: $0.pages.count + extra,
                        ranges: $0.ranges)
        }

        var roots = built.map {
            PartGroup(id: .part($0.name), label: $0.label,
                      filename: options.filename(for: $0),
                      pages: $0.pages, ranges: $0.ranges)
        }
        if !front.isEmpty {
            roots.insert(PartGroup(id: .front, label: "Front matter",
                                   filename: nil, pages: front,
                                   ranges: Part(name: "", label: "", pages: front).ranges),
                         at: 0)
        }
        groups = roots
        expanded.formIntersection(roots.map(\.id))   // drop groups that are gone
    }

    // MARK: - Documents

    /// Ask for a combined PDF and load it.
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the combined PDF to split"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Ask where the parts should go, then write them.
    func chooseAndExport() {
        guard !parts.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the part PDFs"
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }

    /// Put the window back to the drop target, ready for another file.
    func close() {
        document = nil
        sourceName = ""
        pages = []
        groups = []
        expanded = []
        selection = nil
        parts = []
        files = []
        front = []
        notice = nil
        noticeIsError = false
        options = ExportOptions()
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
