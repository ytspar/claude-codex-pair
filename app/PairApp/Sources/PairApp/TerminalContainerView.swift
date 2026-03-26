import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView in SwiftUI.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: PairSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let termView = LocalProcessTerminalView(frame: .zero)
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Store reference for IPC input injection
        context.coordinator.terminalView = termView

        // Start Claude in this terminal
        session.start(in: termView)

        return termView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // SwiftTerm handles its own updates
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    class Coordinator {
        let session: PairSession
        var terminalView: LocalProcessTerminalView?

        init(session: PairSession) {
            self.session = session
        }
    }
}
