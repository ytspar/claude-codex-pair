import SwiftUI
import SwiftTerm

// MARK: - Tabbed container (Scratchpad + Terminal)

struct ScratchpadView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var activeTab: BottomTab = .scratchpad

    enum BottomTab { case scratchpad, terminal }

    var body: some View {
        VStack(spacing: 0) {
            // Top separator
            Rectangle().fill(themeManager.border).frame(height: 1)
                .padding(.leading, 14).padding(.trailing, 20)

            // Tab bar
            HStack(spacing: 0) {
                tabButton("SCRATCHPAD", tab: .scratchpad)
                tabButton("TERMINAL", tab: .terminal)
                Spacer()
            }
            .padding(.leading, 14).padding(.trailing, 20)
            .padding(.top, 6)

            // Content — both tabs share the same height constraints
            switch activeTab {
            case .scratchpad:
                ScratchpadContentView()
            case .terminal:
                SidebarTerminalView()
                    .frame(minHeight: 70, maxHeight: 160)
                    .clipped()
            }

            // Separator above footer
            Rectangle().fill(themeManager.border).frame(height: 1)
                .padding(.leading, 14).padding(.trailing, 20)
        }
        .background(themeManager.bg)
    }

    private func tabButton(_ label: String, tab: BottomTab) -> some View {
        let isActive = activeTab == tab
        return Text(label)
            .font(Theme.monoTiny)
            .foregroundColor(isActive ? themeManager.accent : themeManager.textMuted)
            .tracking(1.0)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(
                Rectangle()
                    .fill(isActive ? themeManager.accent : Color.clear)
                    .frame(height: 1),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture { activeTab = tab }
    }
}

// MARK: - Scratchpad content (extracted from old ScratchpadView)

struct ScratchpadContentView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            // Terminal-style text editor with Ctrl+W, Ctrl+A/E, Ctrl+K/U
            ZStack(alignment: .topLeading) {
                TerminalTextView(
                    text: $text,
                    font: NSFont(name: Theme.fontName, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
                    textColor: NSColor(themeManager.text),
                    cursorColor: NSColor(themeManager.accent),
                    onEscape: { text = "" },
                    onCommandReturn: { sendToClaudeAction() }
                )
                .frame(minHeight: 70, maxHeight: 130)

                if text.isEmpty {
                    Text("Draft a prompt for Claude")
                        .font(Theme.monoSmall)
                        .foregroundColor(themeManager.textMuted)
                        .offset(x: 8, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)

            // Actions
            HStack(spacing: 8) {
                Spacer()

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        HStack(spacing: 4) {
                            Text("Clear")
                                .font(Theme.monoSmall)
                            Text("esc")
                                .font(Theme.monoTiny)
                                .opacity(0.5)
                        }
                        .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)

                    // Queue for later
                    Button(action: queueTaskAction) {
                        Text("Queue")
                            .font(Theme.monoSmall)
                            .foregroundColor(text.isEmpty ? themeManager.textMuted : themeManager.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(text.isEmpty ? themeManager.border : themeManager.cyan.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                SendButton(isEmpty: text.isEmpty, themeManager: themeManager, action: sendToClaudeAction)
            }
            .padding(.leading, 14).padding(.trailing, 20)
            .padding(.bottom, 8)
        }
    }

    private func queueTaskAction() {
        guard !text.isEmpty else { return }
        TaskQueue.shared.addTask(prompt: text)
        PairLog.info("Queued task: \(text.prefix(60))")
        text = ""
    }

    private func sendToClaudeAction() {
        guard !text.isEmpty else { return }
        let prompt = text
        text = ""

        if let session = SessionManager.shared.activeSession {
            session.pasteInput(prompt)
            PairLog.info("Scratchpad pasted \(prompt.count) chars to \(session.id) (awaiting Enter)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let termView = session.terminalView {
                    termView.window?.makeFirstResponder(termView)
                }
            }
        }
    }
}

// MARK: - Sidebar terminal (shell in the Codex panel)

struct SidebarTerminalView: NSViewRepresentable {
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: .zero)

        // Font
        let config = GhosttyConfig.load()
        if let fontName = config.fontFamily,
           let font = NSFont(name: fontName, size: config.fontSize ?? 12) {
            termView.font = font
        } else {
            termView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        // Colors — use same theme as the rest of the app
        applyTheme(to: termView)

        termView.wantsLayer = true

        // Hide scrollbar
        for subview in termView.subviews {
            if let scroller = subview as? NSScroller { scroller.isHidden = true }
        }

        // Start shell in the active session's cwd or home
        let cwd = SessionManager.shared.activeSession?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        termView.startProcess(executable: shell, args: [],
                              environment: nil, execName: nil, currentDirectory: cwd)

        context.coordinator.terminalView = termView
        context.coordinator.lastAppliedThemeMode = themeManager.mode
        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        guard let termView = context.coordinator.terminalView else { return }
        let currentMode = themeManager.mode
        if context.coordinator.lastAppliedThemeMode != currentMode {
            context.coordinator.lastAppliedThemeMode = currentMode
            applyTheme(to: termView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func applyTheme(to termView: LocalProcessTerminalView) {
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
        var terminalView: LocalProcessTerminalView?
        var lastAppliedThemeMode: ThemeManager.ThemeMode?
    }
}

// MARK: - Send button

struct SendButton: View {
    let isEmpty: Bool
    let themeManager: ThemeManager
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Send")
                .font(Theme.monoSmall)
            if isHovered {
                Text("⌘↩")
                    .font(Theme.monoTiny)
                    .transition(.opacity)
            }
        }
        .foregroundColor(isEmpty ? themeManager.textMuted : themeManager.accent)
        .padding(.leading, 14).padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(isEmpty ? Color.clear : (isHovered ? themeManager.accent.opacity(0.1) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isEmpty ? themeManager.border : themeManager.accent, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !isEmpty { action() } }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
