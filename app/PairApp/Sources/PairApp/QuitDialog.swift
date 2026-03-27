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
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(Theme.mono)
                        .foregroundColor(themeManager.textSecondary)
                        .frame(width: 120)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(themeManager.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: onQuit) {
                    Text("Quit")
                        .font(Theme.mono)
                        .foregroundColor(themeManager.error)
                        .frame(width: 120)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(themeManager.error.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
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
            NSApp.reply(toApplicationShouldTerminate: true)
        },
        onCancel: {
            window.close()
        }
    ))
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
}
