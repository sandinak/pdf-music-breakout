import SwiftUI
import PDFKit
import AppKit

/// Which page the preview sheet is showing.
struct PreviewTarget: Identifiable, Equatable {
    var id: Int
}

/// A read-only PDFKit view of one page, scaled to fit.
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        guard let page = document.page(at: pageIndex) else { return }
        if view.currentPage != page {
            view.go(to: page)
            // autoScales recomputes on the new page's size, which matters
            // when a landscape score sits between portrait parts.
            view.autoScales = true
        }
    }
}

/// The full-size look at a page, with its part boundary editable in place.
///
/// A thumbnail is too small to tell a second trumpet part from a first, which
/// is exactly when you need to check -- so the same controls that are in the
/// list are here too, and you can page through without closing.
struct PagePreview: View {
    @ObservedObject var model: AppModel
    @Binding var target: PreviewTarget?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var index: Int { target?.id ?? 0 }
    private var page: PageRow? {
        model.pages.indices.contains(index) ? model.pages[index] : nil
    }
    private var startsPart: Bool { page?.label != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                PDFPageView(document: document, pageIndex: index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 640, idealHeight: 900)
        .onAppear { draft = page?.label ?? "" }
        .onChange(of: target) { _, _ in
            nameFocused = false
            draft = page?.label ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                move(-1)
            } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous page")

            Button {
                move(1)
            } label: { Image(systemName: "chevron.right") }
                .disabled(index >= model.pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next page")

            VStack(alignment: .leading, spacing: 1) {
                Text("Page \(index + 1) of \(model.pages.count)")
                    .font(.headline)
                Text(belongsTo).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") { target = nil }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("starts a part", isOn: Binding(
                get: { startsPart },
                set: { on in
                    model.setBoundary(on, at: index)
                    draft = model.pages[index].label ?? ""
                }))
                .toggleStyle(.checkbox)

            if startsPart {
                TextField("part name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .focused($nameFocused)
                    .onSubmit { model.rename(draft, at: index) }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { model.rename(draft, at: index) }
                    }
            } else {
                Text(belongsTo).font(.callout).italic().foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var belongsTo: String {
        if let label = model.pages.indices.contains(index) ? model.pages[index].label : nil {
            return "starts \(label)"
        }
        if let above = model.inheritedLabel(before: index) {
            return "continues \(above)"
        }
        return "front matter (cover / copyright)"
    }

    private func move(_ delta: Int) {
        // Commit an edit in progress before the page changes under it.
        if nameFocused { model.rename(draft, at: index); nameFocused = false }
        let next = index + delta
        guard model.pages.indices.contains(next) else { return }
        target = PreviewTarget(id: next)
        draft = model.pages[next].label ?? ""
    }
}
