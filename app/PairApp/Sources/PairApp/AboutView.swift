import SwiftUI

struct AboutView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("Pair")
                .font(.custom(Theme.fontName, size: 28))
                .foregroundColor(themeManager.text)

            Text("Claude + Codex")
                .font(Theme.mono)
                .foregroundColor(themeManager.accent)

            Text("v0.1.0 · March 2026")
                .font(Theme.monoSmall)
                .foregroundColor(themeManager.textMuted)

            Divider().frame(width: 200)

            Text("A native macOS app that pairs Claude Code with OpenAI Codex for autonomous code review and task completion. Codex reviews Claude's work, provides feedback, answers questions, and ensures tasks are completed thoroughly.")
                .font(Theme.monoTiny)
                .foregroundColor(themeManager.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Link("github.com/ytspar/claude-codex-pair", destination: URL(string: "https://github.com/ytspar/claude-codex-pair")!)
                    .font(Theme.monoTiny)
                    .foregroundColor(themeManager.accent)

                Text("Created by Yury Tspar")
                    .font(Theme.monoTiny)
                    .foregroundColor(themeManager.textMuted)

                Text("MIT License")
                    .font(Theme.monoTiny)
                    .foregroundColor(themeManager.textMuted)
            }

            Spacer().frame(height: 8)
        }
        .padding(24)
        .frame(width: 400, height: 480)
        .background(themeManager.bg)
    }
}

/// Shows the About window.
func showAboutWindow() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = "About Pair"
    window.center()
    window.isReleasedWhenClosed = false
    window.backgroundColor = NSColor(ThemeManager.shared.bg)
    window.titlebarAppearsTransparent = true
    window.contentView = NSHostingView(rootView: AboutView())
    window.makeKeyAndOrderFront(nil)
}
