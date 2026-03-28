import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession
    @ObservedObject var themeManager = ThemeManager.shared

    func makeNSView(context: Context) -> NSView {
        PairLog.info("makeNSView (SwiftTerm) for session \(session.id)")
        let termView = LocalProcessTerminalView(frame: .zero)

        // Font from Ghostty config or default
        let config = GhosttyConfig.load()
        if let fontName = config.fontFamily,
           let font = NSFont(name: fontName, size: config.fontSize ?? 13) {
            termView.font = font
        } else {
            termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        // Colors
        applyTheme(to: termView)

        // Layer-backed for smooth resize
        termView.wantsLayer = true
        termView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Hide scrollbar
        for subview in termView.subviews {
            if let scroller = subview as? NSScroller { scroller.isHidden = true }
        }

        // Store reference
        context.coordinator.terminalView = termView
        session.terminalView = termView

        // Start Claude
        session.start(in: termView)

        // Wrap in host for smooth resize
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

        // Auto-focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            termView.window?.makeFirstResponder(termView)
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let termView = context.coordinator.terminalView,
              termView.window != nil else { return }
        for subview in termView.subviews {
            if let scroller = subview as? NSScroller { scroller.isHidden = true }
        }
        applyTheme(to: termView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    private func applyTheme(to termView: LocalProcessTerminalView) {
        let useGhostty = themeManager.mode == .ghostty
        let config = useGhostty ? GhosttyConfig.load() : nil

        termView.nativeBackgroundColor = (useGhostty ? config?.background : nil) ?? GhosttyConfig.devbarBackground
        termView.nativeForegroundColor = (useGhostty ? config?.foreground : nil) ?? GhosttyConfig.devbarForeground
        termView.caretColor = (useGhostty ? config?.cursorColor : nil) ?? GhosttyConfig.devbarCursor

        // Set ANSI palette via OSC
        var osc = ""
        for i in 0..<16 {
            let hex: String
            if useGhostty, let c = config?.palette[i] { hex = c.hexString }
            else if let d = GhosttyConfig.devbarPalette[i] { hex = d }
            else { continue }
            let r = String(hex.prefix(2)), g = String(hex.dropFirst(2).prefix(2)), b = String(hex.dropFirst(4).prefix(2))
            osc += "\u{1B}]4;\(i);rgb:\(r)/\(g)/\(b)\u{07}"
        }
        let fg = termView.nativeForegroundColor.hexString, bg = termView.nativeBackgroundColor.hexString
        osc += "\u{1B}]10;rgb:\(fg.prefix(2))/\(fg.dropFirst(2).prefix(2))/\(fg.dropFirst(4).prefix(2))\u{07}"
        osc += "\u{1B}]11;rgb:\(bg.prefix(2))/\(bg.dropFirst(2).prefix(2))/\(bg.dropFirst(4).prefix(2))\u{07}"
        termView.getTerminal().feed(text: osc)
    }

    class Coordinator {
        let session: PairSession
        var terminalView: LocalProcessTerminalView?
        init(session: PairSession) { self.session = session }
    }
}

class TerminalHostView: NSView {
    override var isOpaque: Bool { true }
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        layer?.shouldRasterize = true
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layer?.shouldRasterize = false
        subviews.forEach { $0.needsDisplay = true }
    }
}
