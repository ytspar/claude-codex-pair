import SwiftUI
import GhosttyKit

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

            // Text editor
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Draft a prompt for Claude...")
                        .font(Theme.mono)
                        .foregroundColor(themeManager.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $text)
                    .font(Theme.mono)
                    .foregroundColor(themeManager.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 2)
                    .frame(minHeight: 70, maxHeight: 130)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Actions
            HStack(spacing: 8) {
                Spacer()

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Text("Clear")
                            .font(Theme.monoSmall)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: sendToClaudeAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12))
                        Text("Send to Claude")
                            .font(Theme.monoSmall)
                    }
                    .foregroundColor(text.isEmpty ? themeManager.textMuted : themeManager.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(text.isEmpty ? themeManager.border : themeManager.accent, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(themeManager.bgElevated)
    }

    private func sendToClaudeAction() {
        guard !text.isEmpty else { return }
        let prompt = text
        text = ""

        if let session = SessionManager.shared.activeSession {
            session.injectInput(prompt)
            PairLog.info("Scratchpad sent \(prompt.count) chars to \(session.id)")

            // Move focus to the terminal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let ghosttyView = session.ghosttyView {
                    ghosttyView.window?.makeFirstResponder(ghosttyView)
                }
            }
        }
    }
}
