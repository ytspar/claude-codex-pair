import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
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
                        Theme.bg

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

                // Draggable divider
                Rectangle()
                    .fill(isDragging ? Theme.emerald : Theme.border)
                    .frame(width: isDragging ? 2 : 1)
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
        .background(Theme.bg)
    }
}

// MARK: - Tab bar for multiple sessions

struct SessionTabBar: View {
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
        .background(Theme.bg)
        .overlay(
            Rectangle().fill(Theme.border).frame(height: 1),
            alignment: .bottom
        )
    }
}

struct SessionTab: View {
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
                .fill(Theme.emerald)
                .frame(width: 6, height: 6)
            Text(projectName)
                .font(Theme.monoTiny)
                .foregroundColor(isSelected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.bgElevated : Color.clear)
        .overlay(
            Rectangle()
                .fill(isSelected ? Theme.emerald : Color.clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Empty state

struct EmptyTerminalView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(Theme.textMuted)
            Text("No Claude sessions")
                .font(Theme.monoTitle)
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: 4) {
                Text("⌘N")
                    .font(Theme.monoSmall)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.bgCard)
                    .cornerRadius(3)
                Text("or")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textMuted)
                Text("pair launch <dir>")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}
