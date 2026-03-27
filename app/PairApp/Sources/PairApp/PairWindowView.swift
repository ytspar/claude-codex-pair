import SwiftUI

struct PairWindowView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var codexFraction: CGFloat = 0.35
    @State private var isDragging = false
    @GestureState private var dragOffset: CGFloat = 0
    @State private var authChecked = false

    var body: some View {
        ZStack {
            mainView

            // Auth overlay on first launch
            if !authChecked && sessionManager.sessions.isEmpty {
                ZStack {
                    themeManager.bg
                    AuthStatusView {
                        withAnimation(.easeOut(duration: 0.3)) {
                            authChecked = true
                        }
                    }
                }
            }
        }
    }

    var mainView: some View {
        GeometryReader { geo in
            let dividerX = geo.size.width * (1 - codexFraction) + dragOffset
            let clampedX = min(max(200, dividerX), geo.size.width - 200)
            let leftWidth = clampedX
            let rightWidth = geo.size.width - clampedX

            HStack(spacing: 0) {
                // Left: Terminal
                VStack(spacing: 0) {
                    if sessionManager.sessions.count > 1 {
                        SessionTabBar(
                            sessions: sessionManager.sessions,
                            selectedId: sessionManager.activeSessionId,
                            onSelect: { sessionManager.activeSessionId = $0 },
                            onClose: { sessionManager.removeSession($0) }
                        )
                    }

                    if sessionManager.sessions.isEmpty {
                        ProjectPickerView { path in
                            sessionManager.createSession(cwd: path)
                        }
                    } else if let active = sessionManager.activeSession {
                        TerminalContainerView(session: active)
                            .id(active.id)
                    }
                }
                .frame(width: leftWidth)
                .clipped()

                // Divider: 1px line, no padding, wide invisible hit area via overlay
                ZStack {
                    // Fill with exact terminal bg color (NSColor → Color to avoid color space mismatch)
                    Color(nsColor: themeManager.mode == .ghostty
                        ? (GhosttyConfig.load().background ?? GhosttyConfig.devbarBackground)
                        : GhosttyConfig.devbarBackground)
                    .frame(width: 12)

                    // Visible 1px line
                    Rectangle()
                        .fill(isDragging ? themeManager.accent : themeManager.accent.opacity(0.15))
                        .frame(width: 1)

                    // Drag grip icon centered
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 7))
                        .foregroundColor(themeManager.textMuted.opacity(isDragging ? 1 : 0.6))
                        .rotationEffect(.degrees(90))
                }
                .frame(width: 12)
                .contentShape(Rectangle())
                .onHover { h in
                    if h { NSCursor.resizeLeftRight.push() }
                    else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(coordinateSpace: .named("window"))
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.width
                        }
                        .onChanged { _ in isDragging = true }
                        .onEnded { value in
                            isDragging = false
                            let newX = geo.size.width * (1 - codexFraction) + value.translation.width
                            let clamped = min(max(200, newX), geo.size.width - 200)
                            codexFraction = 1 - (clamped / geo.size.width)
                        }
                )

                // Right: Codex panel
                CodexPanelView()
                    .frame(width: rightWidth - 12)  // subtract divider width
            }
        }
        .coordinateSpace(name: "window")
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
    var onNewSession: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal")
                .font(.system(size: 56))
                .foregroundColor(themeManager.textMuted)
            Text("Choose a project directory")
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.textSecondary)
            Text("Claude Code will launch in the selected directory")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(themeManager.textMuted)

            Button(action: { onNewSession?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text("Open Directory")
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(themeManager.accent, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            HStack(spacing: 6) {
                Text("⌘N")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.bgCard)
                    .cornerRadius(3)
                Text("to open later")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
            }
        }
    }
}
