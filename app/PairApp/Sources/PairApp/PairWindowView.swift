import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var codexWidth: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
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

                // 1px divider — just a colored rectangle, no NSSplitView
                Rectangle()
                    .fill(themeManager.accent.opacity(0.3))
                    .frame(width: 1)

                // Right: Codex panel
                CodexPanelView()
                    .frame(width: codexWidth)
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
        .frame(height: 36)
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
        HStack(spacing: 8) {
            Circle()
                .fill(themeManager.accent)
                .frame(width: 7, height: 7)
            Text(projectName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(isSelected ? themeManager.text : themeManager.textSecondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(themeManager.textMuted)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 56))
                .foregroundColor(themeManager.textMuted)
            Text("No Claude sessions")
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.textSecondary)
            HStack(spacing: 6) {
                Text("⌘N")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.bgCard)
                    .cornerRadius(4)
                Text("or")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
                Text("pair launch <dir>")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
            }
        }
    }
}
