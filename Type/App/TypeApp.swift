import SwiftUI

@main
struct TypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    init() {
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    var body: some Scene {
        // The notebook library is the primary window.
        WindowGroup("Library", id: "library") {
            LibraryWindow()
                .environmentObject(settings)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            TypeCommands(settings: settings)
        }

        // Standalone Markdown / text files opened from Finder.
        DocumentGroup(newDocument: TypeDocument()) { file in
            DocumentWindow(document: file.$document, fileURL: file.fileURL)
                .environmentObject(settings)
        }
        .defaultSize(width: 980, height: 720)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch into the library rather than an untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If nothing was restored (or only panels are up), show the library.
        // (Plain async rather than a timer: timers are throttled by App Nap while no window is visible.)
        DispatchQueue.main.async { Self.showLibraryIfNoWindows() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showLibraryIfNoWindows() }
        return false
    }

    static func showLibraryIfNoWindows() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.className != "TUINSWindow" }
        guard !hasWindow else { return }
        // Trigger File ▸ Show Library (wired to SwiftUI's openWindow).
        for top in NSApp.mainMenu?.items ?? [] {
            if let menu = top.submenu, let index = menu.items.firstIndex(where: { $0.title == "Show Library" }) {
                menu.update()
                menu.performActionForItem(at: index)
                return
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LibraryStore.shared.saveAll() }
    }
}
