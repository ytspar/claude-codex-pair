import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Install crash handlers + logging
        PairLog.installCrashHandlers()
        PairLog.info("PairApp launching")

        // Set app icon
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Set up menu bar
        setupMenuBar()

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair — Claude + Codex"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(ThemeManager.shared.bg)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)

        let contentView = PairWindowView()
        window.contentView = NSHostingView(rootView: contentView)

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.mainWindow = window

        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        IPCServer.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        IPCServer.shared.stop()
        SessionManager.shared.stopAll()
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pair", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Pair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (for copy/paste in terminal)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Theme (Devbar/Ghostty)", action: #selector(toggleTheme), keyEquivalent: "t")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
    }

    @objc func newSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Launch Claude"
        panel.message = "Choose a directory for the new Claude session"
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/git")

        panel.begin { response in
            if response == .OK, let url = panel.url {
                SessionManager.shared.createSession(cwd: url.path)
            }
        }
    }
}
