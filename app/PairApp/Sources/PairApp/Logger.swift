import Foundation
import os

/// Centralized logging for PairApp  - writes to both os_log and a file.
/// Two log files:
///   pairapp.log       — INFO/ERROR/CRASH (concise, always on)
///   pairapp-debug.log — DEBUG level (verbose, full state dumps for replay)
enum PairLog {
    private static let subsystem = "com.ytspar.pairapp"
    private static let logger = os.Logger(subsystem: subsystem, category: "general")
    private static let dir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let d = "\(home)/.claude-codex-pair"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    private static let logFile = "\(dir)/pairapp.log"
    private static let debugLogFile = "\(dir)/pairapp-debug.log"

    /// Formatter shared across all log calls (thread-local via queue)
    private static let writeQueue = DispatchQueue(label: "com.ytspar.pairapp.log", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message)")
        appendToFile("INFO", message, file: logFile)
        appendToFile("INFO", message, file: debugLogFile)
    }

    static func error(_ message: String) {
        logger.error("\(message)")
        appendToFile("ERROR", message, file: logFile)
        appendToFile("ERROR", message, file: debugLogFile)
    }

    static func crash(_ message: String) {
        logger.fault("\(message)")
        appendToFile("CRASH", message, file: logFile)
        appendToFile("CRASH", message, file: debugLogFile)
    }

    /// Verbose debug logging — only goes to pairapp-debug.log, not the main log.
    static func debug(_ message: String) {
        appendToFile("DEBUG", message, file: debugLogFile)
    }

    /// Log full screen text snapshot — truncated to last N lines to keep size manageable.
    static func screen(_ sessionId: String, _ screenText: String, context: String = "") {
        let lines = screenText.split(separator: "\n", omittingEmptySubsequences: false)
        let last30 = lines.suffix(30).joined(separator: "\n")
        let prefix = context.isEmpty ? "" : " (\(context))"
        appendToFile("SCREEN", "[\(sessionId)]\(prefix) lines=\(lines.count) last30:\n\(last30)", file: debugLogFile)
    }

    /// Log a structured poll decision with all relevant state.
    static func pollState(_ sessionId: String,
                          screenLen: Int, hashChanged: Bool,
                          stableCount: Int, changeCount: Int,
                          atPrompt: Bool, atInterrupted: Bool,
                          promptEmpty: Bool, isStuck: Bool,
                          queueRunning: Bool, queuePending: Int,
                          activeTask: String?,
                          reviewInProgress: Bool, lastWasApprove: Bool,
                          lastInputSource: String, userRecentlyTyped: Bool,
                          decision: String) {
        let msg = """
        [\(sessionId)] POLL screen=\(screenLen) hash=\(hashChanged ? "changed" : "same") \
        stable=\(stableCount) changes=\(changeCount) | \
        prompt=\(atPrompt) interrupted=\(atInterrupted) empty=\(promptEmpty) stuck=\(isStuck) | \
        queue=\(queueRunning ? "running" : "stopped") pending=\(queuePending) active=\(activeTask ?? "none") | \
        review=\(reviewInProgress) lastApprove=\(lastWasApprove) | \
        input=\(lastInputSource) userRecent=\(userRecentlyTyped) | \
        -> \(decision)
        """
        appendToFile("POLL", msg, file: debugLogFile)
    }

    /// Log inject/dequeue actions with full context.
    static func action(_ sessionId: String, action: String, detail: String) {
        appendToFile("ACTION", "[\(sessionId)] \(action): \(detail)", file: debugLogFile)
    }

    private static func appendToFile(_ level: String, _ message: String, file: String) {
        let entry = "[\(formatter.string(from: Date()))] \(level): \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }
        writeQueue.async {
            if FileManager.default.fileExists(atPath: file) {
                if let handle = FileHandle(forWritingAtPath: file) {
                    defer { handle.closeFile() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                }
            } else {
                FileManager.default.createFile(atPath: file, contents: data)
            }
        }
    }

    /// Install global exception/signal handlers to catch crashes.
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            PairLog.crash("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")")
            PairLog.crash("Stack: \(exception.callStackSymbols.joined(separator: "\n"))")
        }

        // Signal handlers for SIGSEGV, SIGABRT, etc.
        for sig: Int32 in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
            signal(sig) { signum in
                PairLog.crash("Signal \(signum) received")
                // Re-raise to get default behavior (core dump)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }

        PairLog.info("Crash handlers installed")
    }
}
