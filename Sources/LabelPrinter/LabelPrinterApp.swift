import SwiftUI

@main
struct LabelPrinterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Label Printer") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Files dropped on the Dock icon or opened with "Open With" in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            OpenedFiles.shared.pending = url
        }
    }
}

/// Hands files opened through the app delegate to ContentView. Publishing the current value on
/// subscribe means a file that launched the app is still picked up once the window appears.
final class OpenedFiles: ObservableObject {
    static let shared = OpenedFiles()
    @Published var pending: URL?
}
