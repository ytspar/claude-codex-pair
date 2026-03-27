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
                    // Toolbar — visible when sessions exist or picker is open
                    if !sessionManager.sessions.isEmpty || sessionManager.showProjectPicker {
                        SessionToolbar(
                            sessions: sessionManager.sessions,
                            activeId: sessionManager.showProjectPicker ? nil : sessionManager.activeSessionId,
                            showingBrowse: sessionManager.showProjectPicker,
                            onSelect: { id in
                                sessionManager.showProjectPicker = false
                                sessionManager.activeSessionId = id
                            },
                            onClose: { sessionManager.removeSession($0) },
                            onNew: { sessionManager.showProjectPicker = true },
                            onCloseBrowse: { sessionManager.showProjectPicker = false }
                        )
                        Spacer().frame(height: 6)
                    }

                    ZStack {
                        // Keep ALL terminal views alive
                        ForEach(sessionManager.sessions) { session in
                            GhosttySessionView(session: session)
                                .opacity(!sessionManager.showProjectPicker && session.id == sessionManager.activeSessionId ? 1 : 0)
                                .allowsHitTesting(!sessionManager.showProjectPicker && session.id == sessionManager.activeSessionId)
                        }

                        // Project picker as its own "tab"
                        if sessionManager.sessions.isEmpty || sessionManager.showProjectPicker {
                            ProjectPickerView { path in
                                sessionManager.createSession(cwd: path)
                                sessionManager.showProjectPicker = false
                            }
                        }
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
                        .font(.custom(Theme.fontName, size: 7))
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

// MARK: - Empty state

struct EmptyTerminalView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var onNewSession: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal")
                .font(.custom(Theme.fontName, size: 56))
                .foregroundColor(themeManager.textMuted)
            Text("Choose a project directory")
                .font(.custom(Theme.fontName, size: 22))
                .foregroundColor(themeManager.textSecondary)
            Text("Claude Code will launch in the selected directory")
                .font(Theme.monoSmall)
                .foregroundColor(themeManager.textMuted)

            Button(action: { onNewSession?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text("Open Directory")
                }
                .font(Theme.mono)
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
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.bgCard)
                    .cornerRadius(3)
                Text("to open later")
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textMuted)
            }
        }
    }
}
