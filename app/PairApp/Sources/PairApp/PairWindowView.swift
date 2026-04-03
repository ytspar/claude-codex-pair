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
        .ignoresSafeArea()
    }

    var mainView: some View {
        GeometryReader { geo in
            let dividerX = geo.size.width * (1 - codexFraction) + dragOffset
            let clampedX = min(max(200, dividerX), geo.size.width - 200)
            let leftWidth = clampedX
            let rightWidth = geo.size.width - clampedX

            VStack(spacing: 0) {
                // Spacer for titlebar traffic lights (fullSizeContentView)
                Spacer().frame(height: 28)

                HStack(spacing: 0) {
                // Left: Terminal
                VStack(spacing: 0) {
                    // Toolbar  - visible when sessions exist or picker is open
                    if !sessionManager.sessions.isEmpty || sessionManager.showProjectPicker || sessionManager.showLogViewer {
                        SessionToolbar(
                            sessions: sessionManager.sessions,
                            activeId: (sessionManager.showProjectPicker || sessionManager.showLogViewer) ? nil : sessionManager.activeSessionId,
                            showingBrowse: sessionManager.showProjectPicker,
                            showingLogs: sessionManager.showLogViewer,
                            onSelect: { id in
                                sessionManager.showProjectPicker = false
                                sessionManager.showLogViewer = false
                                sessionManager.activeSessionId = id
                                ClaudeMonitor.shared.activeSessionChanged()
                                // Focus the terminal after tab switch
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    if let session = SessionManager.shared.findSession(id),
                                       let termView = session.terminalView {
                                        termView.window?.makeFirstResponder(termView)
                                    }
                                }
                            },
                            onClose: { sessionManager.removeSession($0) },
                            onNew: { sessionManager.showProjectPicker = true },
                            onCloseBrowse: { sessionManager.showProjectPicker = false },
                            onCloseLogs: { sessionManager.showLogViewer = false }
                        )
                        Spacer().frame(height: 0)
                    }

                    ZStack {
                        // Keep ALL terminal views alive
                        ForEach(sessionManager.sessions) { session in
                            TerminalContainerView(session: session)
                                .opacity(!sessionManager.showProjectPicker && !sessionManager.showLogViewer && session.id == sessionManager.activeSessionId ? 1 : 0)
                                .allowsHitTesting(!sessionManager.showProjectPicker && !sessionManager.showLogViewer && session.id == sessionManager.activeSessionId)
                        }

                        // Log viewer tab
                        if sessionManager.showLogViewer {
                            LogViewerView()
                                .onKeyPress(.escape) {
                                    sessionManager.showLogViewer = false
                                    if sessionManager.sessions.isEmpty {
                                        sessionManager.showProjectPicker = true
                                    }
                                    return .handled
                                }
                        }

                        // Project picker as its own "tab"
                        if !sessionManager.showLogViewer && (sessionManager.sessions.isEmpty || sessionManager.showProjectPicker) {
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

                // Right: Codex panel when session active, recent projects when browsing
                if sessionManager.showProjectPicker || sessionManager.showLogViewer || sessionManager.sessions.isEmpty {
                    BrowseSidebarView { path in
                        sessionManager.createSession(cwd: path)
                        sessionManager.showProjectPicker = false
                    }
                    .frame(width: rightWidth - 12)
                } else {
                    CodexPanelView()
                        .frame(width: rightWidth - 12)
                }
            }
            } // VStack with titlebar spacer
        }
        .coordinateSpace(name: "window")
        .background(themeManager.bg)
        .background(SessionShortcutButtons(sessionManager: sessionManager))
    }
}

// MARK: - Browse sidebar (shown instead of Codex panel when no active session)

struct BrowseSidebarView: View {
    @ObservedObject private var tm = ThemeManager.shared
    @ObservedObject private var store = RecentProjectsStore.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("RECENT PROJECTS")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted)
                    .tracking(1.0)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle().fill(tm.border).frame(height: 1).padding(.horizontal, 14)

            // Project list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.recentProjects.prefix(20)) { project in
                        Button(action: { onSelect(project.path) }) {
                            HStack(spacing: 8) {
                                Image(systemName: project.hasGit ? "chevron.left.forwardslash.chevron.right" : "folder")
                                    .font(.system(size: 10))
                                    .foregroundColor(project.hasGit ? tm.accent.opacity(0.6) : tm.textMuted)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.name)
                                        .font(Theme.monoSmall)
                                        .foregroundColor(tm.text)
                                        .lineLimit(1)
                                    Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(Theme.monoTiny)
                                        .foregroundColor(tm.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let date = project.lastOpened {
                                    Text(relativeDate(date))
                                        .font(Theme.monoTiny)
                                        .foregroundColor(tm.textMuted.opacity(0.6))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { h in
                            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }

                    if store.recentProjects.isEmpty {
                        Text("No recent projects")
                            .font(Theme.monoTiny)
                            .foregroundColor(tm.textMuted.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.top, 20)
                    }
                }
                .padding(.top, 8)
            }

            Spacer()

            // Footer
            Rectangle().fill(tm.border).frame(height: 1)
            HStack {
                Text("Click to open")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted.opacity(0.5))
                Spacer()
                Text(AppVersion.displayString)
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .background(tm.bg)
    }

    private func relativeDate(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        let days = Int(s / 86400)
        return days == 1 ? "1d ago" : "\(days)d ago"
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
                .font(Theme.monoHeading)
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
