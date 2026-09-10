import SwiftUI
import PDFKit
import AppKit

/// The partner window's identifier, for `openWindow(id:)`.
let pagePreviewWindowID = "page-preview"

/// How the preview sizes the page: a fitting rule, which survives a window
/// resize, or an explicit factor once it has been zoomed by hand.
enum PageZoom: Equatable {
    case fitPage
    case fitWidth
    case factor(CGFloat)

    var isFitting: Bool { if case .factor = self { return false } else { return true } }
}

// MARK: - The page itself

/// A PDFView that zooms on pinch and on Command-scroll, and reports the new
/// scale back so the readout and the menu agree with what is on screen.
final class ZoomingPDFView: PDFView {
    var onZoom: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        onZoom?(1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY : event.scrollingDeltaY * 4
        guard delta != 0 else { return }
        onZoom?(min(1.25, max(0.8, 1 + delta / 120)))
    }
}

/// One page of the document, at whatever zoom the model is holding.
///
/// PDFKit's own `autoScales` only ever fits the whole page, which is the size
/// that was too small to read in the first place, so the scale is set here
/// instead: fit the width, fit the page, or an exact factor.
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    @Binding var zoom: PageZoom
    @Binding var scale: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = ZoomingPDFView()
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = false            // the coordinator owns the scale
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 10
        view.backgroundColor = .underPageBackgroundColor
        view.postsFrameChangedNotifications = true
        view.onZoom = { [weak coordinator = context.coordinator] factor in
            coordinator?.zoomByGesture(factor)
        }
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(document: document, page: pageIndex, zoom: zoom)
    }

    final class Coordinator: NSObject {
        var parent: PDFPageView
        private weak var view: PDFView?
        private var shownPage = -1
        /// The last scale we set ourselves, so a pinch can be told from it.
        private var applied: CGFloat = 0
        /// A new page still waiting to be scrolled to its top. The first
        /// layout happens before the view has a size, so the fit -- and the
        /// scroll that follows it -- has to wait for the real frame.
        private var pendingTop = false

        init(_ parent: PDFPageView) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(_ view: PDFView) {
            self.view = view
            let centre = NotificationCenter.default
            centre.addObserver(self, selector: #selector(scaleChanged),
                               name: .PDFViewScaleChanged, object: view)
            centre.addObserver(self, selector: #selector(frameChanged),
                               name: NSView.frameDidChangeNotification, object: view)
        }

        func show(document: PDFDocument, page index: Int, zoom: PageZoom) {
            guard let view else { return }
            if view.document !== document {
                view.document = document
                shownPage = -1
            }
            guard let page = document.page(at: index) else { return }
            if index != shownPage {
                view.go(to: page)
                shownPage = index
                // A part is identified by the name in its header, so a page
                // arriving under a magnifier should arrive at its top rather
                // than wherever the page before it was left scrolled to.
                pendingTop = true
            }
            apply(zoom, on: page, in: view)
            settle(page, in: view)
        }

        /// Command-scroll and pinch both land here: take the new scale as the
        /// reader's own choice, which drops any fitting rule.
        func zoomByGesture(_ factor: CGFloat) {
            guard let view else { return }
            let wanted = min(view.maxScaleFactor,
                             max(view.minScaleFactor, view.scaleFactor * factor))
            view.scaleFactor = wanted
            applied = wanted
            DispatchQueue.main.async { [weak self] in
                self?.parent.zoom = .factor(wanted)
                self?.parent.scale = wanted
            }
        }

        @objc private func frameChanged(_ note: Notification) {
            guard let view, let page = view.currentPage else { return }
            if parent.zoom.isFitting { apply(parent.zoom, on: page, in: view) }
            settle(page, in: view)
        }

        /// Once the view has a real size, put the page's top in view and tell
        /// the readout what scale it ended up at.
        private func settle(_ page: PDFPage, in view: PDFView) {
            if pendingTop, view.bounds.width > 40 {
                scrollToTop(of: page, in: view)
                pendingTop = false
            }
            publish(view.scaleFactor)
        }

        @objc private func scaleChanged(_ note: Notification) {
            guard let view else { return }
            let now = view.scaleFactor
            let ours = abs(now - applied) < 0.001
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !ours { self.parent.zoom = .factor(now) }
                if abs(self.parent.scale - now) > 0.001 { self.parent.scale = now }
            }
        }

        private func apply(_ zoom: PageZoom, on page: PDFPage, in view: PDFView) {
            let target = scale(for: zoom, page: page, in: view)
            guard target > 0, abs(view.scaleFactor - target) > 0.001 else { return }
            applied = target
            view.scaleFactor = target
        }

        private func scale(for zoom: PageZoom, page: PDFPage, in view: PDFView) -> CGFloat {
            if case .factor(let f) = zoom {
                return min(view.maxScaleFactor, max(view.minScaleFactor, f))
            }
            let box = page.bounds(for: view.displayBox)
            // A landscape score is often a portrait page turned on its side.
            let turned = abs(page.rotation) % 180 == 90
            let width = turned ? box.height : box.width
            let height = turned ? box.width : box.height
            let size = view.bounds.size
            guard width > 1, height > 1, size.width > 40, size.height > 40 else { return 1 }
            // Room for the page's own margin, and for a scroller beside it.
            let across = (size.width - 22) / width
            if case .fitWidth = zoom { return max(0.1, across) }
            return max(0.1, min(across, (size.height - 22) / height))
        }

        private func scrollToTop(of page: PDFPage, in view: PDFView) {
            let box = page.bounds(for: view.displayBox)
            view.go(to: CGRect(x: box.minX, y: box.maxY - 1, width: box.width, height: 1),
                    on: page)
        }

        private func publish(_ now: CGFloat) {
            guard abs(parent.scale - now) > 0.001 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.scale = now }
        }
    }
}

// MARK: - The window

/// The partner window: whatever page is selected in the main window, big
/// enough to read, with its part boundary editable while you look at it.
struct PagePreview: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var index: Int? { model.previewPage }

    var body: some View {
        Group {
            if let document = model.document, let index {
                page(document, index)
            } else {
                idle
            }
        }
        .frame(minWidth: 420, minHeight: 380)
        .navigationTitle(model.isLoaded ? "\(model.sourceName) — Page Preview"
                                        : "Page Preview")
        .onAppear { draft = label(at: index) }
        .onChange(of: model.selection) { _, _ in
            nameFocused = false
            draft = label(at: index)
        }
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.isLoaded ? "Select a page in the main window"
                                : "Open a combined PDF to look at its pages")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func page(_ document: PDFDocument, _ index: Int) -> some View {
        VStack(spacing: 0) {
            header(index)
            Divider()
            PDFPageView(document: document,
                        pageIndex: index,
                        zoom: $model.previewZoom,
                        scale: $model.previewScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(index)
        }
    }

    // MARK: Bars

    private func header(_ index: Int) -> some View {
        HStack(spacing: 10) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0 || nameFocused)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous page")

            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= model.pages.count - 1 || nameFocused)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next page")

            VStack(alignment: .leading, spacing: 1) {
                Text("Page \(index + 1) of \(model.pages.count)").font(.headline)
                Text(belongsTo(index)).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { model.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")

            Menu(percentage) {
                Button("Fit Page") { model.previewZoom = .fitPage }
                Button("Fit Width") { model.previewZoom = .fitWidth }
                Button("Actual Size") { model.previewZoom = .factor(1) }
                Divider()
                ForEach([0.5, 0.75, 1.5, 2, 3, 4], id: \.self) { f in
                    Button("\(Int(f * 100))%") { model.previewZoom = .factor(CGFloat(f)) }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 78)
            .help("Zoom to a set size, or fit the page or its width")

            Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                // ⌘+ is the menu's shortcut; ⌘= is the key most people press.
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
        }
    }

    private var percentage: String {
        switch model.previewZoom {
        case .fitPage:  return "Fit"
        case .fitWidth: return "Width"
        case .factor:   return "\(Int((model.previewScale * 100).rounded()))%"
        }
    }

    private func footer(_ index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("starts a part", isOn: Binding(
                get: { model.isPartStart(index) },
                set: { on in
                    if on { model.split(at: index) } else { model.mergeUp(at: index) }
                    draft = label(at: index)
                }))
                .toggleStyle(.checkbox)
                .disabled(index == 0)
                .help(index == 0 ? "The first page always starts something"
                                 : "Whether this page begins a part of its own")

            if model.isPartStart(index) {
                TextField("part name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .focused($nameFocused)
                    .onSubmit { rename(index) }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { rename(index) }
                    }
            } else {
                Text(belongsTo(index)).font(.callout).italic().foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Pieces

    private func label(at index: Int?) -> String {
        guard let index, model.pages.indices.contains(index) else { return "" }
        return model.pages[index].part ?? ""
    }

    /// Rename the whole part, not just this page: they are one thing now.
    private func rename(_ index: Int) {
        guard model.pages.indices.contains(index) else { return }
        model.rename(draft, forPart: model.pages[index].part)
    }

    private func belongsTo(_ index: Int) -> String {
        guard let part = model.pages[index].part else {
            return "front matter (cover / copyright)"
        }
        return model.isPartStart(index) ? "starts \(part)" : "continues \(part)"
    }

    private func move(_ delta: Int) {
        // Commit an edit in progress before the page changes under it.
        if nameFocused, let index { rename(index); nameFocused = false }
        model.stepSelection(by: delta)
    }
}
