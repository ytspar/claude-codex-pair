import SwiftUI

struct ScratchpadView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Rectangle().fill(themeManager.border).frame(width: 12, height: 1)
                Text("SCRATCHPAD")
                    .font(Theme.monoTiny)
                    .foregroundColor(themeManager.accent.opacity(0.7))
                    .tracking(1.0)
                Rectangle().fill(themeManager.border).frame(height: 1)
            }

            // Terminal-style text editor with Ctrl+W, Ctrl+A/E, Ctrl+K/U
            ZStack(alignment: .topLeading) {
                TerminalTextView(
                    text: $text,
                    font: NSFont(name: Theme.fontName, size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular),
                    textColor: NSColor(themeManager.text),
                    cursorColor: NSColor(themeManager.accent),
                    onEscape: { text = "" },
                    onCommandReturn: { sendToClaudeAction() }
                )
                .frame(minHeight: 70, maxHeight: 130)

                if text.isEmpty {
                    Text("Draft a prompt for Claude")
                        .font(Theme.mono)
                        .foregroundColor(themeManager.textMuted)
                        .offset(x: 8, y: 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)

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
                }

                SendButton(isEmpty: text.isEmpty, themeManager: themeManager, action: sendToClaudeAction)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(themeManager.bg)
    }

    private func sendToClaudeAction() {
        guard !text.isEmpty else { return }
        let prompt = text
        text = ""

        if let session = SessionManager.shared.activeSession {
            session.injectInput(prompt)
            PairLog.info("Scratchpad sent \(prompt.count) chars to \(session.id)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let termView = session.terminalView {
                    termView.window?.makeFirstResponder(termView)
                }
            }
        }
    }
}

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
        .padding(.horizontal, 14)
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

