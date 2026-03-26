import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI.
/// Uses Ghostty config colors if available, devbar palette as fallback.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession
    @ObservedObject var themeManager = ThemeManager.shared

    func makeNSView(context: Context) -> NSView {
        let termView = LocalProcessTerminalView(frame: .zero)
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Layer-backed for smooth resize (prevents flashing)
        termView.wantsLayer = true
        termView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        termView.canDrawConcurrently = true

        hideScroller(termView)
        applyTheme(to: termView)

        context.coordinator.terminalView = termView
        session.terminalView = termView
        session.start(in: termView)

        // Wrap in a container that clips and handles resize smoothly
        let container = TerminalHostView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        termView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(termView)
        NSLayoutConstraint.activate([
            termView.topAnchor.constraint(equalTo: container.topAnchor),
            termView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            termView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        context.coordinator.container = container

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let termView = context.coordinator.terminalView else { return }
        hideScroller(termView)
        applyTheme(to: termView)
    }

    private func hideScroller(_ view: NSView) {
        for subview in view.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
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
        var container: TerminalHostView?

        init(session: PairSession) {
            self.session = session
        }
    }
}

/// Host view that prevents flashing during live resize by using layer caching.
class TerminalHostView: NSView {
    override var isOpaque: Bool { true }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        // Freeze the layer content during resize to prevent flashing
        layer?.shouldRasterize = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layer?.shouldRasterize = false
        // Force terminal to redraw at new size
        for subview in subviews {
            subview.needsDisplay = true
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
