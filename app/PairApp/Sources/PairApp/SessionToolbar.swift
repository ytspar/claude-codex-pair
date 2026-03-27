import SwiftUI

/// Toolbar above the terminal — shows tabs, new/close buttons.
struct SessionToolbar: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let sessions: [PairSession]
    let activeId: String?
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Session tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        ToolbarTab(
                            name: String(session.cwd.split(separator: "/").last ?? "session"),
                            isActive: session.id == activeId,
                            onSelect: { onSelect(session.id) },
                            onClose: { onClose(session.id) }
                        )
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 2) {
                ToolbarButton(icon: "plus", tooltip: "New Session (⌘N)") {
                    onNew()
                }

                if let id = activeId {
                    ToolbarButton(icon: "xmark", tooltip: "Close Session (⌘W)") {
                        onClose(id)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 34)
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
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Clickable area for selecting the tab
            HStack(spacing: 6) {
                Circle()
                    .fill(themeManager.accent)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(Theme.monoSmall)
                    .foregroundColor(isActive ? themeManager.text : themeManager.textSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            // Close button — separate hit target
            if isActive || isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(themeManager.textMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? themeManager.bgElevated : (isHovered ? themeManager.bg.opacity(0.5) : Color.clear))
        .overlay(
            Rectangle()
                .fill(isActive ? themeManager.accent : Color.clear)
                .frame(height: 2),
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
                .font(.system(size: 11, weight: .medium))
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
