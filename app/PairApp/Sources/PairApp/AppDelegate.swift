import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair — Claude + Codex"
        window.center()

        let contentView = PairWindowView()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window

        NSApp.activate(ignoringOtherApps: true)

        // Start IPC server
        IPCServer.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        IPCServer.shared.stop()
        SessionManager.shared.stopAll()
    }
}
