import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var codexPanelWidth: CGFloat = 420
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left: Terminal tabs
                VStack(spacing: 0) {
                    // Tab bar (when multiple sessions)
                    if sessionManager.sessions.count > 1 {
                        SessionTabBar(
                            sessions: sessionManager.sessions,
                            selectedId: sessionManager.activeSessionId,
                            onSelect: { sessionManager.activeSessionId = $0 },
                            onClose: { sessionManager.removeSession($0) }
                        )
                    }

                    // Active terminal
                    ZStack {
                        themeManager.bg

                        if sessionManager.sessions.isEmpty {
                            EmptyTerminalView()
                        } else if let active = sessionManager.activeSession {
                            TerminalContainerView(session: active)
                                .id(active.id)  // Force re-render on tab switch
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Draggable divider with grip icon
                ZStack {
                    Rectangle()
                        .fill(isDragging ? themeManager.accent : themeManager.border)
                        .frame(width: 1)
                    // Drag grip icon
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8))
                        .foregroundColor(isDragging ? themeManager.accent : themeManager.textMuted)
                        .rotationEffect(.degrees(90))
                        .frame(width: 12, height: 24)
                        .background(themeManager.bg.opacity(0.8))
                        .cornerRadius(4)
                }
                .frame(width: 12)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDragging = true
                            let newWidth = geo.size.width - value.location.x
                            codexPanelWidth = min(max(250, newWidth), geo.size.width * 0.6)
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )

                // Right: Codex panel
                CodexPanelView()
                    .frame(width: codexPanelWidth)
            }
        }
        .background(themeManager.bg)
        .background(SessionShortcutButtons(sessionManager: sessionManager))
    }
}

// MARK: - Tab bar for multiple sessions

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
            Rectangle().fill(ThemeManager.shared.border).frame(height: 1),
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
                .fill(ThemeManager.shared.accent)
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
                .fill(isSelected ? ThemeManager.shared.accent : Color.clear)
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
