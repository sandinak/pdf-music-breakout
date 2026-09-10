import SwiftUI
import AppKit

/// Handles PDFs opened from the Finder: double-clicked, dropped on the Dock
/// icon, or passed to `open -a`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" })
        else { return }
        Task { @MainActor in AppModel.shared.open(url: url) }
    }
}

@main
struct PDFMusicBreakoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            // The standard File menu: open another book, or put this one
            // away and start again, without hunting for the toolbar.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.chooseAndOpen() }
                    .keyboardShortcut("o")
            }
            // After, not replacing, so the system's own Close (⌘W) survives:
            // with a second window on screen, ⌘W has to mean that window.
            CommandGroup(after: .saveItem) {
                // The save dialog, under the key everyone's hand goes to.
                Button("Export Parts…") { model.chooseAndExport() }
                    .keyboardShortcut("s")
                    .disabled(model.files.isEmpty)
                Button("Close Document") { model.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.isLoaded)
                Divider()
            }
            CommandGroup(after: .sidebar) { previewCommands }
        }

        // The partner window. It follows the selection in the main window, so
        // there is only ever one of it.
        Window("Page Preview", id: pagePreviewWindowID) {
            PagePreview(model: AppModel.shared)
        }
        .defaultSize(width: 820, height: 1000)
        .defaultPosition(.topTrailing)
    }

    /// The View menu's half of the preview: raising the window, and the zoom
    /// that the window itself also offers. These live in the menu bar so they
    /// work from either window -- zooming the page you are looking at is still
    /// what you mean when the list has the focus.
    @ViewBuilder
    private var previewCommands: some View {
        ShowPreviewButton()
        Divider()
        Button("Zoom In") { model.zoom(by: 1.25) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!model.isLoaded)
        Button("Zoom Out") { model.zoom(by: 0.8) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!model.isLoaded)
        Button("Actual Size") { model.previewZoom = .factor(1) }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!model.isLoaded)
        Button("Fit Page") { model.previewZoom = .fitPage }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(!model.isLoaded)
        Button("Fit Width") { model.previewZoom = .fitWidth }
            .keyboardShortcut("8", modifiers: .command)
            .disabled(!model.isLoaded)
        Divider()
    }
}

/// `openWindow` is an environment value, so the menu item that uses it has to
/// be a view of its own.
private struct ShowPreviewButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Page Preview") { openWindow(id: pagePreviewWindowID) }
            .keyboardShortcut("p", modifiers: [.command, .option])
    }
}
