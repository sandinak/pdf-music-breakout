import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.isLoaded {
                loaded
            } else {
                DropWell(targeted: $dropTargeted, onPick: openPanel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) { noticeBar }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(from: providers)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar { toolbarItems }
        .navigationTitle(model.isLoaded ? model.sourceName : "PDF Music Breakout")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { openPanel() } label: { Label("Open", systemImage: "doc.badge.plus") }
                .help("Choose a combined PDF")
        }
        ToolbarItem {
            Button { model.resetToDetected() } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.isLoaded)
            .help("Put every boundary back where detection found it")
        }
        ToolbarItem {
            Button { exportPanel() } label: { Label("Export…", systemImage: "square.and.arrow.down") }
                .disabled(model.files.isEmpty || model.busy)
                .keyboardShortcut("e")
                .help("Write one PDF per part into a folder")
        }
    }

    // MARK: - Loaded layout

    private var loaded: some View {
        HSplitView {
            pageList.frame(minWidth: 420)
            sidebar.frame(minWidth: 300, maxWidth: 420)
        }
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A ticked page starts a new part. Untick one that isn't really "
                 + "a new part, or tick one that was missed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
            Divider()
            List(model.pages) { page in
                PageRowView(page: page, model: model)
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
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

    // MARK: - Files

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the combined PDF to split"
        if panel.runModal() == .OK, let url = panel.url { model.open(url: url) }
    }

    private func exportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the part PDFs"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
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

/// One page in the review list.
private struct PageRowView: View {
    let page: PageRow
    @ObservedObject var model: AppModel
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var startsPart: Bool { page.label != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text("Page \(page.number) — \(Int(page.size.width))×\(Int(page.size.height)) pt"
                     + (page.isLandscape ? " · landscape" : ""))
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Toggle("starts a part", isOn: Binding(
                        get: { startsPart },
                        set: { model.setBoundary($0, at: page.id) }))
                        .toggleStyle(.checkbox)

                    if startsPart {
                        TextField("part name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .focused($focused)
                            .onSubmit { model.rename(draft, at: page.id) }
                            .onChange(of: focused) { _, isFocused in
                                if !isFocused { model.rename(draft, at: page.id) }
                            }
                    } else {
                        Text(continuationNote)
                            .font(.callout).italic().foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { draft = page.label ?? "" }
        .onChange(of: page.label) { _, new in
            if !focused { draft = new ?? "" }
        }
    }

    private var continuationNote: String {
        if let above = model.inheritedLabel(before: page.id) {
            return "↳ continues \(above)"
        }
        return "front matter (cover / copyright)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = page.thumbnail {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 74, height: 96)
        .overlay(Rectangle().strokeBorder(.separator))
    }
}
