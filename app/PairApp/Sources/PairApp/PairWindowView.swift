import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        GeometryReader { geo in
            // Native NSSplitView via HSplitView — smooth native drag, no double bar
            HSplitView {
                // Left: Terminal sessions
                VStack(spacing: 0) {
                    if sessionManager.sessions.count > 1 {
                        SessionTabBar(
                            sessions: sessionManager.sessions,
                            selectedId: sessionManager.activeSessionId,
                            onSelect: { sessionManager.activeSessionId = $0 },
                            onClose: { sessionManager.removeSession($0) }
                        )
                    }

                    ZStack {
                        themeManager.bg

                        if sessionManager.sessions.isEmpty {
                            EmptyTerminalView()
                        } else if let active = sessionManager.activeSession {
                            TerminalContainerView(session: active)
                                .id(active.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 400, idealWidth: geo.size.width * 0.6)

                // Right: Codex panel
                CodexPanelView()
                    .frame(minWidth: 250, idealWidth: geo.size.width * 0.4)
            }
        }
        .background(themeManager.bg)
        .background(SessionShortcutButtons(sessionManager: sessionManager))
    }
}

// MARK: - Tab bar

struct SessionTabBar: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let sessions: [PairSession]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: session.id == selectedId,
                        onSelect: { onSelect(session.id) },
                        onClose: { onClose(session.id) }
                    )
                }
            }
        }
        .frame(height: 32)
        .background(themeManager.bg)
        .overlay(
            Rectangle().fill(themeManager.border).frame(height: 1),
            alignment: .bottom
        )
    }
}

struct SessionTab: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let session: PairSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var projectName: String {
        String(session.cwd.split(separator: "/").last ?? "session")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(themeManager.accent)
                .frame(width: 6, height: 6)
            Text(projectName)
                .font(Theme.monoTiny)
                .foregroundColor(isSelected ? themeManager.text : themeManager.textSecondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(themeManager.textMuted)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? themeManager.bgElevated : Color.clear)
        .overlay(
            Rectangle()
                .fill(isSelected ? themeManager.accent : Color.clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Empty state

struct EmptyTerminalView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(themeManager.textMuted)
            Text("No Claude sessions")
                .font(Theme.monoTitle)
                .foregroundColor(themeManager.textSecondary)
            HStack(spacing: 4) {
                Text("⌘N")
                    .font(Theme.monoSmall)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.bgCard)
                    .cornerRadius(3)
                Text("or")
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textMuted)
                Text("pair launch <dir>")
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textMuted)
            }
        }
    }
}
