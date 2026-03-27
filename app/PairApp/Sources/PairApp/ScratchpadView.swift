import SwiftUI

/// Scratchpad for drafting Claude prompts without accidentally sending them.
/// Users can type multi-line text, press Enter for new lines, then click
/// "Send to Claude" to inject it into the active session.
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
                        .font(Theme.monoSmall)
                        .foregroundColor(themeManager.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }

                TextEditor(text: $text)
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 60, maxHeight: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Actions
            HStack(spacing: 8) {
                Spacer()

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Text("Clear")
                            .font(Theme.monoTiny)
                            .foregroundColor(themeManager.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: sendToClaudeAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 11))
                        Text("Send to Claude")
                            .font(Theme.monoTiny)
                    }
                    .foregroundColor(text.isEmpty ? themeManager.textMuted : themeManager.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
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

        // Send to the active session
        if let session = SessionManager.shared.activeSession {
            session.injectInput(prompt + "\n")
            PairLog.info("Scratchpad sent \(prompt.count) chars to \(session.id)")
        }
    }
}
