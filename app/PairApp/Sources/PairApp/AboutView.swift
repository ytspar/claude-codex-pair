import SwiftUI

struct AboutView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("Pair")
                .font(Theme.monoLarge)
                .foregroundColor(themeManager.text)

            Text("Claude + Codex")
                .font(Theme.monoSubtitle)
                .foregroundColor(themeManager.accent)

            Text(AppVersion.displayString)
                .font(Theme.mono)
                .foregroundColor(themeManager.textMuted)

            Divider().frame(width: 240)

            Text("A native macOS app that pairs Claude Code with OpenAI Codex for autonomous code review and task completion. Codex reviews Claude's work, provides feedback, answers questions, and ensures tasks are completed thoroughly.")
                .font(Theme.monoSmall)
                .foregroundColor(themeManager.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 360)

            Divider().frame(width: 240)

            VStack(spacing: 8) {
                Link("github.com/ytspar/claude-codex-pair", destination: URL(string: "https://github.com/ytspar/claude-codex-pair")!)
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.accent)

                Text("Created by ytspar")
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textMuted)

                Text("MIT License")
                    .font(Theme.monoSmall)
                    .foregroundColor(themeManager.textMuted)
            }

            Spacer().frame(height: 4)
        }
        .padding(28)
        .frame(width: 440, height: 560)
        .background(themeManager.bg)
    }
}

func showAboutWindow() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
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
