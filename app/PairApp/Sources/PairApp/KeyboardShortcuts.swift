import SwiftUI

/// Hidden buttons that provide keyboard shortcuts for session management.
/// Add this as a background view to enable Cmd+1-9 session switching.
struct SessionShortcutButtons: View {
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        Group {
            ForEach(1...9, id: \.self) { index in
                Button("") {
                    if index <= sessionManager.sessions.count {
                        sessionManager.activeSessionId = sessionManager.sessions[index - 1].id
                        ClaudeMonitor.shared.activeSessionChanged()
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
