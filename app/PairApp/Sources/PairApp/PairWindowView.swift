import SwiftUI

/// Main window layout: Claude terminal on the left, Codex review panel on the right.
struct PairWindowView: View {
    @StateObject private var sessionManager = SessionManager.shared
    @State private var selectedSessionId: String?

    var body: some View {
        HSplitView {
            // Left: Claude terminal sessions (stacked if multiple)
            VStack(spacing: 0) {
                if sessionManager.sessions.isEmpty {
                    EmptyStateView()
                } else {
                    ForEach(sessionManager.sessions) { session in
                        TerminalContainerView(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: 500)

            // Right: Codex review panel
            CodexPanelView()
                .frame(minWidth: 300, idealWidth: 450)
        }
        .frame(minWidth: 900, minHeight: 500)
        // Sessions are created via IPC or pair launch command
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Claude sessions")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Launch with: pair launch <directory>")
                .font(.body)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
