import SwiftUI
import GhosttyKit

/// Wraps GhosttyTerminalView for a PairSession, connecting IPC input injection.
struct GhosttySessionView: NSViewRepresentable {
    @ObservedObject var session: PairSession

    func makeNSView(context: Context) -> GhosttyTerminalView {
        PairLog.info("makeNSView (Ghostty) for session \(session.id)")

        // Initialize the Ghostty app controller once
        GhosttyAppController.shared.initialize()

        let view = GhosttyTerminalView(
            workingDirectory: session.cwd,
            command: "claude"
        )

        // Store reference for IPC input injection
        session.ghosttyView = view
        context.coordinator.ghosttyView = view

        view.onSurfaceClosed = {
            PairLog.info("Ghostty surface closed for \(session.id)")
        }

        // Auto-focus the terminal so user can type immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Ghostty handles its own rendering via Metal
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    class Coordinator {
        let session: PairSession
        var ghosttyView: GhosttyTerminalView?

        init(session: PairSession) {
            self.session = session
        }
    }
}
