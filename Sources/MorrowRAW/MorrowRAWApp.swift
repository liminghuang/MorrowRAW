import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs = urls
        NotificationCenter.default.post(name: .awayPhotoOpenURL, object: urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .awayPhotoWillTerminate, object: nil)
        return .terminateNow
    }

    func consumePendingURLs() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }
}

extension Notification.Name {
    static let awayPhotoOpenURL = Notification.Name("MorrowRAW.openURL")
    static let awayPhotoWillTerminate = Notification.Name("MorrowRAW.willTerminate")
}

@main
struct MorrowRAWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Morrow RAW") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
        Window("關於 Morrow RAW", id: "about") {
            AboutView()
        }
        .defaultSize(width: 430, height: 390)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("關於 Morrow RAW") {
                    openWindow(id: "about")
                }
            }
        }
    }
}
