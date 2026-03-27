import SwiftUI

struct QuitDialogView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let sessionCount: Int
    let onQuit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }

            Text("Quit Pair?")
                .font(.custom(Theme.fontName, size: 20))
                .foregroundColor(themeManager.text)

            Text("\(sessionCount) active Claude session\(sessionCount == 1 ? "" : "s") will be closed.")
                .font(Theme.mono)
                .foregroundColor(themeManager.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Text("Cancel")
                    .font(Theme.mono)
                    .foregroundColor(themeManager.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(themeManager.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)

                Text("Quit")
                    .font(Theme.mono)
                    .foregroundColor(themeManager.error)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(themeManager.error.opacity(0.5), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onQuit)
            }
        }
        .padding(32)
        .frame(width: 340)
        .background(themeManager.bg)
    }
}

func showQuitDialog(sessionCount: Int) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = ""
    window.center()
    window.isReleasedWhenClosed = false
    window.backgroundColor = NSColor(ThemeManager.shared.bg)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden

    // Prevent Pair from closing while dialog is open
    window.level = .modalPanel

    let hostingView = NSHostingView(rootView: QuitDialogView(
        sessionCount: sessionCount,
        onQuit: {
            window.close()
            (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
            NSApp.terminate(nil)
        },
        onCancel: {
            window.close()
        }
    ))
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
}
