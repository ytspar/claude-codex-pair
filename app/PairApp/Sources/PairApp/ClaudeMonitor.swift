import Foundation
import GhosttyKit

/// Monitors Claude's terminal output to detect when it pauses.
/// When Claude stops (shows prompt, finishes response), triggers Codex review.
///
/// This replaces the hook-based approach — PairApp watches the terminal
/// directly since it owns the PTY.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    @Published var isClaudeActive = false
    @Published var lastActivity: Date = Date()

    private var activityTimer: Timer?
    private var idleThreshold: TimeInterval = 3.0  // seconds of no output = idle

    func start() {
        // Poll every second to check for activity
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        PairLog.info("ClaudeMonitor started")
    }

    func stop() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    /// Called when terminal output is received (from Ghostty surface callback).
    func recordActivity() {
        let wasActive = isClaudeActive
        DispatchQueue.main.async { [weak self] in
            self?.lastActivity = Date()
            if !wasActive {
                self?.isClaudeActive = true
                PairLog.info("Claude became active")
            }
        }
    }

    private func checkActivity() {
        let idle = Date().timeIntervalSince(lastActivity)

        if isClaudeActive && idle > idleThreshold {
            // Claude went idle — it stopped producing output
            DispatchQueue.main.async {
                self.isClaudeActive = false
            }
            PairLog.info("Claude went idle after \(String(format: "%.1f", idle))s")
        }
    }
}
