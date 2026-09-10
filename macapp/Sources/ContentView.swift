import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // In the layout rather than over it: a notice that covered the
            // instructions underneath was how this window used to look.
            noticeBar
            if model.isLoaded {
                loaded
            } else {
                DropWell(targeted: $dropTargeted) { model.chooseAndOpen() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(from: providers)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar { toolbarItems }
        .navigationTitle(model.isLoaded ? model.sourceName : "PDF Music Breakout")
    }

    /// Put a page in the partner window, opening it if it is not up yet.
    private func preview(page index: Int) {
        model.select(index)
        openWindow(id: pagePreviewWindowID)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.chooseAndOpen() } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open a different combined PDF (⌘O)")
        }
        ToolbarItem {
            Button { model.close() } label: {
                Label("Close", systemImage: "xmark.circle")
            }
            .disabled(!model.isLoaded)
            .help("Close this PDF and start again (⇧⌘W)")
        }
        ToolbarItem {
            Button { preview(page: model.previewPage ?? 0) } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!model.isLoaded)
            .help("Show the selected page in the preview window (⌥⌘P)")
        }
        ToolbarItem {
            Button { model.resetToDetected() } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.isLoaded)
            .help("Put every boundary back where detection found it")
        }
        ToolbarItem {
            Button { model.chooseAndExport() } label: {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.files.isEmpty || model.busy)
            .help("Write one PDF per part into a folder (⌘S)")
        }
    }

    // MARK: - Loaded layout

    private var loaded: some View {
        HSplitView {
            pageList.frame(minWidth: 440)
            sidebar.frame(minWidth: 300, maxWidth: 420)
        }
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader
            Divider()
            // The preview window can page through the document itself, so
            // keep the tree scrolled to whatever it has landed on.
            ScrollViewReader { list in
                List(model.rows, selection: $model.selection) { row in
                    treeRow(row)
                        .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: model.selection) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.15)) { list.scrollTo(new) }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Each part is a row, with its remaining pages inside it. Drag a "
                 + "page's picture onto another part to move it there.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Expand All") { withAnimation { model.expandAll() } }
                .disabled(model.groups.allSatisfy { model.expanded.contains($0.id) })
            Button("Collapse All") { withAnimation { model.collapseAll() } }
                .disabled(model.expanded.isEmpty)
        }
        .controlSize(.small)
        .padding(12)
    }

    @ViewBuilder
    private func treeRow(_ row: TreeRow) -> some View {
        switch row {
        case .group(let group):
            GroupRowView(group: group, model: model) { preview(page: $0) }
        case .page(let index, let group):
            PageRowView(index: index, group: group, model: model) { preview(page: $0) }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Naming") {
                    labelled("Song title") { TextField("", text: $model.options.title) }
                    labelled("Filename prefix") {
                        TextField("e.g. 03-", text: $model.options.prefix)
                    }
                }
                section("Paper") {
                    labelled("Page size") {
                        Picker("", selection: $model.options.paper) {
                            ForEach(Paper.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    if model.options.paper != .keep {
                        labelled("Oversized pages") {
                            Picker("", selection: $model.options.rotation) {
                                ForEach(Rotation.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden()
                        }
                    }
                    labelled("Cover / copyright page") {
                        Picker("", selection: $model.options.frontMatter) {
                            ForEach(FrontMatter.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    Text("Pages that already fit are copied untouched; only oversized "
                         + "ones are rotated and scaled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                section("Files to be written") {
                    if model.files.isEmpty {
                        Text("Nothing yet — tick a page to start a part.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.files) { file in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.filename)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Text("\(file.pageCount) pp · pages \(file.ranges)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !model.front.isEmpty {
                            Text(frontMatterNote)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var frontMatterNote: String {
        let pages = model.front.map { String($0 + 1) }.joined(separator: ", ")
        let verb = model.options.frontMatter == .attach
            ? "added to every part" : "left out"
        return "Front matter: page\(model.front.count > 1 ? "s" : "") \(pages) — \(verb)."
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary).kerning(0.6)
            content()
        }
    }

    @ViewBuilder
    private func labelled(_ title: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var noticeBar: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.noticeIsError
                            ? Color.red.opacity(0.16) : Color.yellow.opacity(0.18))
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top))
        }
    }

    private func load(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in model.open(url: url) }
        }
        return true
    }
}

/// The empty state: a target to drop a PDF onto.
private struct DropWell: View {
    @Binding var targeted: Bool
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a combined PDF here").font(.title3.weight(.medium))
            Text("or click to choose one — nothing leaves this Mac")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
    }
}

/// What a dragged row carries. A plain string keeps the drag inside this app
/// without having to declare a uniform type identifier in the bundle.
enum DragPayload {
    static let types: [UTType] = [.utf8PlainText, .plainText, .text]

    static func text(for id: NodeID) -> String {
        switch id {
        case .part(let name): return "pmb:part:\(name)"
        case .front:          return "pmb:front"
        case .page(let index): return "pmb:page:\(index)"
        }
    }

    static func id(from text: String) -> NodeID? {
        if text == "pmb:front" { return .front }
        if text.hasPrefix("pmb:part:") { return .part(String(text.dropFirst(9))) }
        if text.hasPrefix("pmb:page:"), let i = Int(text.dropFirst(9)) { return .page(i) }
        return nil
    }
}

/// Accepting a drop: read the payload, and move what it names onto `target`.
private struct DropTarget: ViewModifier {
    @ObservedObject var model: AppModel
    let target: NodeID
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(over ? Color.accentColor.opacity(0.22) : .clear))
            .onDrop(of: DragPayload.types, isTargeted: $over) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String,
                          let source = DragPayload.id(from: text) else { return }
                    Task { @MainActor in model.drop(source, on: target) }
                }
                return true
            }
    }
}

private extension View {
    func acceptsDrops(on target: NodeID, model: AppModel) -> some View {
        modifier(DropTarget(model: model, target: target))
    }

    func draggable(as id: NodeID) -> some View {
        onDrag { NSItemProvider(object: DragPayload.text(for: id) as NSString) }
    }
}

/// A part at the root of the tree: its first page, its name, and the file it
/// will be written to.
private struct GroupRowView: View {
    let group: PartGroup
    @ObservedObject var model: AppModel
    let onPreview: (Int) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var first: Int { group.first ?? 0 }
    private var showing: Bool { model.previewPage == first }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            disclosure
            Thumbnail(page: model.pages.indices.contains(first) ? model.pages[first] : nil,
                      size: CGSize(width: 62, height: 80), highlighted: showing,
                      hint: group.isFront ? "Drag onto a part to attach these pages to it"
                                          : "Drag onto another part to merge this one into it")
                .draggable(as: group.id)
                .onTapGesture(count: 2) { onPreview(first) }
            VStack(alignment: .leading, spacing: 3) {
                name
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if let filename = group.filename {
                    Text(filename)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(model.options.frontMatter == .attach
                         ? "added to the front of every part"
                         : "left out of the exported parts")
                        .font(.caption).italic().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { onPreview(first) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show this page in the preview window")
        }
        .contentShape(Rectangle())
        .acceptsDrops(on: group.id, model: model)
        .contextMenu { menu }
        .onAppear { draft = group.label }
        .onChange(of: group.label) { _, new in if !focused { draft = new } }
    }

    @ViewBuilder
    private var disclosure: some View {
        if group.rest.isEmpty {
            Color.clear.frame(width: 16, height: 16)
        } else {
            Button { withAnimation { model.toggle(group.id) } } label: {
                Image(systemName: model.expanded.contains(group.id)
                      ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(model.expanded.contains(group.id) ? "Hide these pages"
                                                    : "Show the rest of this part")
        }
    }

    @ViewBuilder
    private var name: some View {
        if group.isFront {
            Text("Front matter (cover / copyright)").font(.body.weight(.medium))
        } else {
            TextField("part name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit { model.rename(draft, forPart: group.label) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { model.rename(draft, forPart: group.label) }
                }
        }
    }

    private var summary: String {
        let count = group.pages.count
        return "\(count) page\(count == 1 ? "" : "s") · \(group.ranges)"
    }

    @ViewBuilder
    private var menu: some View {
        Button("Show Page \(first + 1) in Preview") { onPreview(first) }
        if !group.isFront, first > 0 {
            Button("Merge Into the Part Above") { model.mergeUp(at: first) }
        }
        if !group.isFront {
            Button("Move to Front Matter") { model.move(pages: group.pages, to: .front) }
        }
    }
}

/// A page nested under the part it belongs to.
private struct PageRowView: View {
    let index: Int
    let group: PartGroup
    @ObservedObject var model: AppModel
    let onPreview: (Int) -> Void

    private var page: PageRow? {
        model.pages.indices.contains(index) ? model.pages[index] : nil
    }
    private var showing: Bool { model.previewPage == index }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 30, height: 1)     // indent under the part
            Thumbnail(page: page, size: CGSize(width: 44, height: 58), highlighted: showing,
                      hint: "Drag onto the part this page belongs to")
                .draggable(as: .page(index))
                .onTapGesture(count: 2) { onPreview(index) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(measurements).font(.caption).foregroundStyle(.secondary)
                    Button { onPreview(index) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Show this page in the preview window")
                }
                Toggle("starts a part of its own", isOn: Binding(
                    get: { false },
                    set: { on in if on { model.split(at: index) } }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Tick this if the part below should have begun here")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .acceptsDrops(on: .page(index), model: model)
        .contextMenu {
            Button("Show Page \(index + 1) in Preview") { onPreview(index) }
            Button("Start a New Part Here") { model.split(at: index) }
            if !group.isFront {
                Button("Move to Front Matter") { model.move(pages: [index], to: .front) }
            }
        }
    }

    private var measurements: String {
        guard let page else { return "Page \(index + 1)" }
        return "Page \(page.number) — \(Int(page.size.width))×\(Int(page.size.height)) pt"
             + (page.isLandscape ? " · landscape" : "")
    }
}

/// A page's picture, marked when it is the one the preview window has up.
private struct Thumbnail: View {
    let page: PageRow?
    let size: CGSize
    let highlighted: Bool
    let hint: String

    var body: some View {
        Group {
            if let image = page?.thumbnail {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(Rectangle()
            .strokeBorder(highlighted ? AnyShapeStyle(Color.accentColor)
                                      : AnyShapeStyle(.separator),
                          lineWidth: highlighted ? 2 : 1))
        .help(hint + ". Double-click to see it full size.")
    }
}
