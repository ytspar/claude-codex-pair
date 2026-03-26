import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left: Terminal area
            ZStack {
                Color.black

                if sessionManager.sessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("No Claude sessions")
                            .font(.title2)
                            .foregroundColor(.gray)
                        Text("Use: pair launch <directory>")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.6))
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(sessionManager.sessions) { session in
                            TerminalContainerView(session: session)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)

            // Right: Codex panel
            CodexPanelView()
                .frame(width: 400)
        }
    }
}
