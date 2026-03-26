import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must set activation policy BEFORE creating windows
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair — Claude + Codex"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal

        let contentView = PairWindowView()
        window.contentView = NSHostingView(rootView: contentView)

        // Force window to front
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        self.mainWindow = window

        // Activate the app and bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Double-ensure visibility after a brief delay (handles race with terminal focus)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

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
