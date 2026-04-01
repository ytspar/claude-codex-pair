import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's PairTerminalView in SwiftUI.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeNSView(context: Context) -> NSView {
        PairLog.info("makeNSView (SwiftTerm) for session \(session.id)")
        let termView = PairTerminalView(frame: .zero)

        // Font from Ghostty config or default
        let config = GhosttyConfig.load()
        if let fontName = config.fontFamily,
           let font = NSFont(name: fontName, size: config.fontSize ?? 13) {
            termView.font = font
        } else {
            termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        // Colors
        applyTheme(to: termView)

        // Layer-backed for smooth resize
        termView.wantsLayer = true
        termView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Hide scrollbar
        for subview in termView.subviews {
            if let scroller = subview as? NSScroller { scroller.isHidden = true }
        }

        // Store reference
        context.coordinator.terminalView = termView
        session.terminalView = termView

        // Start Claude
        session.start(in: termView)

        // Wrap in host for smooth resize
        let container = TerminalHostView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        termView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.topAnchor.constraint(equalTo: container.topAnchor),
            termView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            termView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Auto-focus (only if this session is still active when the delay fires)
        let sessionId = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if SessionManager.shared.activeSessionId == sessionId {
                termView.window?.makeFirstResponder(termView)
            }
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let termView = context.coordinator.terminalView,
              termView.window != nil else { return }

        // Focus the terminal when this session becomes active
        let isActive = session.id == SessionManager.shared.activeSessionId
            && !SessionManager.shared.showProjectPicker
        if isActive && termView.window?.firstResponder !== termView {
            termView.window?.makeFirstResponder(termView)
        }

        // Only reapply theme when it actually changes (avoid disk I/O + OSC rebuild on every SwiftUI tick)
        let currentMode = themeManager.mode
        if context.coordinator.lastAppliedThemeMode != currentMode {
            context.coordinator.lastAppliedThemeMode = currentMode
            for subview in termView.subviews {
                if let scroller = subview as? NSScroller { scroller.isHidden = true }
            }
            applyTheme(to: termView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    private func applyTheme(to termView: PairTerminalView) {
        let useGhostty = themeManager.mode == .ghostty
        let config = useGhostty ? GhosttyConfig.load() : nil

        termView.nativeBackgroundColor = (useGhostty ? config?.background : nil) ?? GhosttyConfig.devbarBackground
        termView.nativeForegroundColor = (useGhostty ? config?.foreground : nil) ?? GhosttyConfig.devbarForeground
        termView.caretColor = (useGhostty ? config?.cursorColor : nil) ?? GhosttyConfig.devbarCursor

        // Set ANSI palette via OSC
        var osc = ""
        for i in 0..<16 {
            let hex: String
            if useGhostty, let c = config?.palette[i] { hex = c.hexString }
            else if let d = GhosttyConfig.devbarPalette[i] { hex = d }
            else { continue }
            let r = String(hex.prefix(2)), g = String(hex.dropFirst(2).prefix(2)), b = String(hex.dropFirst(4).prefix(2))
            osc += "\u{1B}]4;\(i);rgb:\(r)/\(g)/\(b)\u{07}"
        }
        let fg = termView.nativeForegroundColor.hexString, bg = termView.nativeBackgroundColor.hexString
        osc += "\u{1B}]10;rgb:\(fg.prefix(2))/\(fg.dropFirst(2).prefix(2))/\(fg.dropFirst(4).prefix(2))\u{07}"
        osc += "\u{1B}]11;rgb:\(bg.prefix(2))/\(bg.dropFirst(2).prefix(2))/\(bg.dropFirst(4).prefix(2))\u{07}"
        termView.getTerminal().feed(text: osc)
    }

    class Coordinator {
        let session: PairSession
        var terminalView: PairTerminalView?
        var keyMonitor: Any?
        var mouseMonitor: Any?
        var lastAppliedThemeMode: ThemeManager.ThemeMode?

        init(session: PairSession) {
            self.session = session
            // Monitor local key events to detect user typing
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self,
                      let termView = self.terminalView,
                      termView.window?.firstResponder === termView else { return event }
                self.session.lastInputSource = .user
                return event
            }

            // Option+click bypasses mouse reporting for text selection.
            // When Option is held, temporarily disable allowMouseReporting so
            // SwiftTerm handles mouse events for selection instead of sending
            // them to the running application (Claude Code's TUI).
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self = self, let termView = self.terminalView else { return event }
                let optionHeld = event.modifierFlags.contains(.option)
                if optionHeld {
                    termView.allowMouseReporting = false
                }
                // Re-enable after mouseUp so normal mouse interactions resume
                if event.type == .leftMouseUp && !termView.allowMouseReporting {
                    // Defer re-enable so the current mouseUp is processed without reporting
                    DispatchQueue.main.async {
                        termView.allowMouseReporting = true
                    }
                }
                return event
            }
        }

        deinit {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
            if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

class TerminalHostView: NSView {
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Prevent SwiftUI from intercepting arrow keys, Tab, Escape, etc.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘F → open SwiftTerm's built-in find bar
        // ⌘G → find next, ⇧⌘G → find previous
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
            if let termView = subviews.first as? PairTerminalView {
                let item = NSMenuItem()
                if chars == "f" {
                    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    termView.performFindPanelAction(item)
                    return true
                } else if chars == "g" {
                    item.tag = event.modifierFlags.contains(.shift)
                        ? Int(NSFindPanelAction.previous.rawValue)
                        : Int(NSFindPanelAction.next.rawValue)
                    termView.performFindPanelAction(item)
                    return true
                }
            }
        }

        // Arrow keys, Tab, Escape must reach the terminal, not SwiftUI.
        // SwiftUI hosting views eat these for focus navigation. Ensure the
        // terminal is first responder so its interpretKeyEvents → doCommand
        // path handles them (including Kitty protocol).
        if let termView = subviews.first as? PairTerminalView {
            let dominated: Set<UInt16> = [123, 124, 125, 126, 48, 53]  // ←→↑↓ Tab Esc
            if dominated.contains(event.keyCode) {
                if window?.firstResponder !== termView {
                    window?.makeFirstResponder(termView)
                }
                termView.keyDown(with: event)
                return true
            }
        }

        if let termView = subviews.first {
            if termView.performKeyEquivalent(with: event) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let termView = subviews.first as? PairTerminalView else {
            super.keyDown(with: event)
            return
        }

        // Fix: SwiftTerm's doCommand(by: insertNewline:) drops the Shift modifier
        // when Kitty keyboard protocol is active. Detect Shift+Enter and send the
        // correct Kitty-encoded sequence directly: CSI 13;2u
        // (13 = CR codepoint, 2 = shift modifier flag + 1)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            let terminal = termView.getTerminal()
            if !terminal.keyboardEnhancementFlags.isEmpty {
                // Kitty protocol is active — send CSI 13;2u for Shift+Enter
                termView.send(txt: "\u{1B}[13;2u")
                return
            }
        }

        termView.keyDown(with: event)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        layer?.shouldRasterize = true
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layer?.shouldRasterize = false
        subviews.forEach { $0.needsDisplay = true }
    }
}
