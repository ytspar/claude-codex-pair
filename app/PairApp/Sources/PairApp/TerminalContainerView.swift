import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI.
/// Uses Ghostty config colors if available, devbar palette as fallback.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession
    @ObservedObject var themeManager = ThemeManager.shared

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: .zero)
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Hide the scrollbar — it creates a gray bar on the right edge
        for subview in termView.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }

        applyTheme(to: termView)

        context.coordinator.terminalView = termView
        session.terminalView = termView
        session.start(in: termView)

        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Hide scrollbar on every update (it may be added lazily)
        for subview in nsView.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
        applyTheme(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    private func applyTheme(to termView: LocalProcessTerminalView) {
        let useGhostty = themeManager.mode == .ghostty
        let ghosttyConfig = useGhostty ? GhosttyConfig.load() : nil

        // Background / foreground — synced with ThemeManager
        if useGhostty, let config = ghosttyConfig, config.hasCustomColors {
            termView.nativeBackgroundColor = config.background ?? GhosttyConfig.devbarBackground
            termView.nativeForegroundColor = config.foreground ?? GhosttyConfig.devbarForeground
            termView.caretColor = config.cursorColor ?? GhosttyConfig.devbarCursor
        } else {
            termView.nativeBackgroundColor = GhosttyConfig.devbarBackground
            termView.nativeForegroundColor = GhosttyConfig.devbarForeground
            termView.caretColor = GhosttyConfig.devbarCursor
        }

        // Build OSC palette sequence
        var osc = ""

        for i in 0..<16 {
            let hex: String
            if useGhostty, let ghosttyColor = ghosttyConfig?.palette[i] {
                hex = ghosttyColor.hexString
            } else if let devbarHex = GhosttyConfig.devbarPalette[i] {
                hex = devbarHex
            } else {
                continue
            }

            let r = String(hex.prefix(2))
            let g = String(hex.dropFirst(2).prefix(2))
            let b = String(hex.dropFirst(4).prefix(2))
            osc += "\u{1B}]4;\(i);rgb:\(r)/\(g)/\(b)\u{07}"
        }

        // Set fg/bg via OSC 10/11
        let fg = (useGhostty ? ghosttyConfig?.foreground ?? GhosttyConfig.devbarForeground : GhosttyConfig.devbarForeground).hexString
        let bg = (useGhostty ? ghosttyConfig?.background ?? GhosttyConfig.devbarBackground : GhosttyConfig.devbarBackground).hexString
        osc += "\u{1B}]10;rgb:\(fg.prefix(2))/\(fg.dropFirst(2).prefix(2))/\(fg.dropFirst(4).prefix(2))\u{07}"
        osc += "\u{1B}]11;rgb:\(bg.prefix(2))/\(bg.dropFirst(2).prefix(2))/\(bg.dropFirst(4).prefix(2))\u{07}"

        termView.getTerminal().feed(text: osc)
    }

    class Coordinator {
        let session: PairSession
        var terminalView: LocalProcessTerminalView?

        init(session: PairSession) {
            self.session = session
        }
    }
}

extension NSColor {
    /// Convert to 6-char hex string (no #).
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02x%02x%02x",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
