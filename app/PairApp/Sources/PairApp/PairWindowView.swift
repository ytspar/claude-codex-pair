import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left: Terminal area
            VStack(spacing: 0) {
                // Terminal header bar
                HStack {
                    // Wing + title
                    Rectangle().fill(Theme.border).frame(width: 12, height: 1)
                    Text("CLAUDE CODE")
                        .font(Theme.monoSmall)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.emerald)
                        .tracking(1.5)
                    Rectangle().fill(Theme.border).frame(height: 1)

                    if let session = sessionManager.sessions.first {
                        Text(session.cwd.split(separator: "/").last ?? "")
                            .font(Theme.monoTiny)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.bg)

                // Terminal content
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

                // Terminal footer
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionManager.sessions.isEmpty ? Theme.textMuted : Theme.emerald)
                        .frame(width: 5, height: 5)
                    if let session = sessionManager.sessions.first {
                        Text(session.id)
                            .font(Theme.monoTiny)
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Text("no session")
                            .font(Theme.monoTiny)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Text("Opus 4.6")
                        .font(Theme.monoTiny)
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.bg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right: Codex panel
            CodexPanelView()
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 500)
        }
        .background(Theme.bg)
    }
}
