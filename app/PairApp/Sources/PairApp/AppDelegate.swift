import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?
    private var themeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Disable native macOS window tabbing — we manage our own session tabs
        NSWindow.allowsAutomaticWindowTabbing = false

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
        window.titleVisibility = .hidden
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

        // Auto-restore sessions from previous run (e.g., after rebuild)
        SessionManager.shared.restoreSessions()
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
        // Persist session directories for restore after rebuild
        SessionManager.shared.persistSessionDirs()
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
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Browse\u{2026}", action: #selector(browseForProject), keyEquivalent: "o")

        // Open Recent submenu
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "")
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

        // Dev menu
        let devMenu = NSMenu(title: "Dev")
        devMenu.autoenablesItems = false
        let rebuildItem = NSMenuItem(title: "Rebuild & Relaunch", action: #selector(rebuildAndRelaunch), keyEquivalent: "r")
        rebuildItem.keyEquivalentModifierMask = [.command, .shift]
        devMenu.addItem(rebuildItem)

        let devMenuItem = NSMenuItem()
        devMenuItem.submenu = devMenu
        mainMenu.addItem(devMenuItem)

        // Log menu
        let logMenu = NSMenu(title: "Log")
        logMenu.autoenablesItems = false
        let showLogsItem = NSMenuItem(title: "Show Logs", action: #selector(showLogs), keyEquivalent: "l")
        showLogsItem.keyEquivalentModifierMask = [.command, .shift]
        logMenu.addItem(showLogsItem)
        logMenu.addItem(withTitle: "Open Log in Finder", action: #selector(openLogInFinder), keyEquivalent: "")
        logMenu.addItem(withTitle: "Clear Debug Log", action: #selector(clearDebugLog), keyEquivalent: "")

        let logMenuItem = NSMenuItem()
        logMenuItem.submenu = logMenu
        mainMenu.addItem(logMenuItem)

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

    @objc func showLogs() {
        SessionManager.shared.showProjectPicker = false
        SessionManager.shared.showLogViewer = true
    }

    @objc func openLogInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(home)/.claude-codex-pair"
        NSWorkspace.shared.selectFile("\(logDir)/pairapp-debug.log", inFileViewerRootedAtPath: logDir)
    }

    @objc func clearDebugLog() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try? "".write(toFile: "\(home)/.claude-codex-pair/pairapp-debug.log", atomically: true, encoding: .utf8)
    }

    @objc func browseForProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/git")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                RecentProjectsStore.shared.recordOpen(url.path)
                SessionManager.shared.createSession(cwd: url.path)
            }
        }
    }

    @objc func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        RecentProjectsStore.shared.recordOpen(path)
        SessionManager.shared.createSession(cwd: path)
    }

    @objc func rebuildAndRelaunch() {
        // Persist sessions, then spawn the rebuild script and quit
        SessionManager.shared.persistSessionDirs()

        let scriptPath = findRebuildScript()
        guard let script = scriptPath else {
            PairLog.error("rebuild.sh not found")
            return
        }

        PairLog.info("Rebuild & relaunch: \(script)")

        // Launch rebuild script in background, then quit
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "--run"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        // Give the script a moment to start, then quit cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.quitConfirmed = true
            NSApp.terminate(nil)
        }
    }

    private func findRebuildScript() -> String? {
        // Walk up from the binary to find the project root
        let binary = ProcessInfo.processInfo.arguments[0]
        var dir = URL(fileURLWithPath: binary).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("scripts/rebuild.sh").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: check common locations
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/git/ytspar/claude-codex-pair/scripts/rebuild.sh",
        ]
        return paths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }
}

// MARK: - Recent Projects menu

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()

        let projects = RecentProjectsStore.shared.recentProjects.prefix(10)
        if projects.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for project in projects {
            let item = NSMenuItem(title: "", action: #selector(openRecentProject(_:)), keyEquivalent: "")
            item.representedObject = project.path

            // Attributed title: name on top, short path below in gray
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: project.name + "\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            ))
            title.append(NSAttributedString(
                string: project.shortPath,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            item.attributedTitle = title
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentProjects), keyEquivalent: "")
    }
}

extension AppDelegate {
    @objc func clearRecentProjects() {
        RecentProjectsStore.shared.clearAll()
    }
}
