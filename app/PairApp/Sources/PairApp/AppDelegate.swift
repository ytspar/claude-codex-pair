import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?
    private var themeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Install crash handlers + logging
        PairLog.installCrashHandlers()
        PairLog.info("PairApp launching")

        // Register Departure Mono font
        if let fontURL = Bundle.module.url(forResource: "DepartureMono-Regular", withExtension: "otf", subdirectory: "Resources") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            PairLog.info("Registered Departure Mono font")
        }

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
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair  - Claude + Codex"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(ThemeManager.shared.bg)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)

        let contentView = PairWindowView()
        window.contentView = NSHostingView(rootView: contentView)

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.mainWindow = window

        // Keep window background in sync with theme changes
        themeObserver = ThemeManager.shared.$bg.sink { [weak window] newBg in
            window?.backgroundColor = NSColor(newBg)
        }

        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Disable App Nap - the monitor needs to stay active when idle
        ProcessInfo.processInfo.disableAutomaticTermination("Monitoring Claude sessions")
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "ClaudeMonitor polling active sessions"
        )

        IPCServer.shared.start()
        ClaudeMonitor.shared.start()
    }

    var quitConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }

        let sessions = SessionManager.shared.sessions
        guard !sessions.isEmpty else { return .terminateNow }

        showQuitDialog(sessionCount: sessions.count)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Focus the Claude terminal (left pane) when the app window is activated
        guard let window = mainWindow else { return }
        if let session = SessionManager.shared.activeSession,
           let termView = session.terminalView {
            window.makeFirstResponder(termView)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        IPCServer.shared.stop()
        SessionManager.shared.stopAll()
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pair", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Pair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.autoenablesItems = false
        fileMenu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newSession), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "w")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "W")

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
        viewMenu.autoenablesItems = false
        viewMenu.addItem(withTitle: "Toggle Theme (Devbar/Ghostty)", action: #selector(toggleTheme), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)

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

    @objc func showAbout() {
        showAboutWindow()
    }

    @objc func closeSession() {
        if let id = SessionManager.shared.activeSessionId {
            SessionManager.shared.removeSession(id)
        }
    }

    @objc func closeWindow() {
        mainWindow?.performClose(nil)
    }

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
    }

    @objc func newSession() {
        SessionManager.shared.showProjectPicker = true
    }
}
