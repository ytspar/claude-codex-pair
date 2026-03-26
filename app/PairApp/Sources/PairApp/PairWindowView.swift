import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left: Terminal — fills the space, no extra chrome
            ZStack {
                Theme.bg

                if sessionManager.sessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(Theme.textMuted)
                        Text("No Claude sessions")
                            .font(Theme.monoTitle)
                            .foregroundColor(Theme.textSecondary)
                        Text("pair launch <directory>")
                            .font(Theme.monoSmall)
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Theme.bgCard)
                            .cornerRadius(4)
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

            // Right: Codex panel
            CodexPanelView()
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 500)
        }
        .background(Theme.bg)
    }
}
