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
            CommandGroup(replacing: .saveItem) {
                Button("Export Parts…") { model.chooseAndExport() }
                    .keyboardShortcut("e")
                    .disabled(model.files.isEmpty)
                Divider()
                Button("Close Document") { model.close() }
                    .keyboardShortcut("w")
                    .disabled(!model.isLoaded)
            }
        }
    }
}
