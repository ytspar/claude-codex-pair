import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI with devbar color scheme.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: .zero)
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Apply devbar color scheme
        applyTheme(to: termView)

        // Store reference for IPC input injection
        context.coordinator.terminalView = termView
        session.terminalView = termView

        // Start Claude in this terminal
        session.start(in: termView)

        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    /// Apply devbar-inspired dark theme to the terminal.
    private func applyTheme(to termView: LocalProcessTerminalView) {
        // Background and foreground
        termView.nativeBackgroundColor = NSColor(red: 0.039, green: 0.059, blue: 0.102, alpha: 1.0)  // #0A0F1A
        termView.nativeForegroundColor = NSColor(red: 0.945, green: 0.961, blue: 0.976, alpha: 1.0)  // #F1F5F9

        // Caret
        termView.caretColor = NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1.0)  // Emerald #10B981

        // Set ANSI palette via OSC 4 escape sequences (works with any terminal emulator)
        let palette: [String] = [
            "1e293b",  // 0: Black (dark slate)
            "ef4444",  // 1: Red
            "10b981",  // 2: Green (emerald)
            "f59e0b",  // 3: Yellow/amber
            "3b82f6",  // 4: Blue
            "a855f7",  // 5: Magenta/purple
            "06b6d4",  // 6: Cyan
            "94a3b8",  // 7: White (slate gray)
            "6b7280",  // 8: Bright black (gray)
            "fc8781",  // 9: Bright red
            "34d399",  // 10: Bright green
            "fbbf24",  // 11: Bright yellow
            "60a5fa",  // 12: Bright blue
            "c084fc",  // 13: Bright magenta
            "22d3ee",  // 14: Bright cyan
            "f1f5f9",  // 15: Bright white
        ]

        // OSC 4;index;rgb:rr/gg/bb ST — sets ANSI color
        var oscSequence = ""
        for (i, hex) in palette.enumerated() {
            let r = String(hex.prefix(2))
            let g = String(hex.dropFirst(2).prefix(2))
            let b = String(hex.dropFirst(4).prefix(2))
            oscSequence += "\u{1B}]4;\(i);rgb:\(r)/\(g)/\(b)\u{07}"
        }
        // Also set default foreground (OSC 10) and background (OSC 11)
        oscSequence += "\u{1B}]10;rgb:f1/f5/f9\u{07}"  // fg: bright white
        oscSequence += "\u{1B}]11;rgb:0a/0f/1a\u{07}"  // bg: dark navy

        termView.getTerminal().feed(text: oscSequence)
    }

    class Coordinator {
        let session: PairSession
        var terminalView: LocalProcessTerminalView?

        init(session: PairSession) {
            self.session = session
        }
    }
}
