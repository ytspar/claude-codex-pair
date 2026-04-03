import SwiftUI

struct SessionToolbar: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let sessions: [PairSession]
    let activeId: String?
    var showingBrowse: Bool = false
    var showingLogs: Bool = false
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onNew: () -> Void
    var onCloseBrowse: (() -> Void)?
    var onCloseLogs: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Session tabs
                    ForEach(sessions) { session in
                        ToolbarTab(
                            name: String(session.cwd.split(separator: "/").last ?? "session"),
                            isActive: session.id == activeId && !showingBrowse,
                            onSelect: { onSelect(session.id) },
                            onClose: { onClose(session.id) }
                        )
                    }

                    // Browse tab (when project picker is open)
                    if showingBrowse {
                        ToolbarTab(
                            name: "Browse",
                            icon: "folder",
                            isActive: true,
                            onSelect: {},
                            onClose: { onCloseBrowse?() }
                        )
                    }

                    // Logs tab (when log viewer is open)
                    if showingLogs {
                        ToolbarTab(
                            name: "Logs",
                            icon: "doc.text",
                            isActive: true,
                            onSelect: {},
                            onClose: { onCloseLogs?() }
                        )
                    }
                }
            }

            Spacer()

            HStack(spacing: 2) {
                if !showingBrowse {
                    ToolbarButton(icon: "plus", tooltip: "New Tab (⌘T)") {
                        onNew()
                    }
                }

                if let id = activeId, !showingBrowse {
                    ToolbarButton(icon: "xmark", tooltip: "Close Session (⌘W)") {
                        onClose(id)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.top, 6)
        .frame(height: 40)
        .background(themeManager.bg)
        .overlay(
            Rectangle().fill(themeManager.border).frame(height: 1),
            alignment: .bottom
        )
    }
}

struct ToolbarTab: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let name: String
    var icon: String? = nil
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(Theme.monoTiny)
                    .foregroundColor(themeManager.accent)
            } else if isActive {
                // Active tab: filled dot = monitored
                Circle()
                    .fill(themeManager.accent)
                    .frame(width: 6, height: 6)
            } else {
                // Inactive tab: hollow dot = paused
                Circle()
                    .strokeBorder(themeManager.textMuted, lineWidth: 1)
                    .frame(width: 6, height: 6)
            }
            Text(name)
                .font(Theme.monoSmall)
                .foregroundColor(isActive ? themeManager.text : themeManager.textSecondary)
                .lineLimit(1)

            // Always reserve space for the close button to prevent layout shift
            Image(systemName: "xmark")
                .font(.custom(Theme.fontName, size: 8))
                .foregroundColor(themeManager.textMuted)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .opacity(isActive || isHovered ? 1 : 0)
                .allowsHitTesting(isActive || isHovered)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? themeManager.bgElevated : (isHovered ? themeManager.bg.opacity(0.5) : Color.clear))
        .overlay(
            Rectangle()
                .fill(isActive ? themeManager.accent : Color.clear)
                .frame(height: 2)
                .offset(y: 1),
            alignment: .bottom
        )
        .onHover { isHovered = $0 }
    }
}

struct ToolbarButton: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.monoTiny)
                .foregroundColor(isHovered ? themeManager.text : themeManager.textMuted)
                .frame(width: 26, height: 26)
                .background(isHovered ? themeManager.accent.opacity(0.15) : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}
