import Foundation
import os

/// Centralized logging for PairApp — writes to both os_log and a file.
enum PairLog {
    private static let subsystem = "com.ytspar.pairapp"
    private static let logger = os.Logger(subsystem: subsystem, category: "general")
    private static let logFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude-codex-pair"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/pairapp.log"
    }()

    static func info(_ message: String) {
        logger.info("\(message)")
        appendToFile("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message)")
        appendToFile("ERROR", message)
    }

    static func crash(_ message: String) {
        logger.fault("\(message)")
        appendToFile("CRASH", message)
    }

    private static func appendToFile(_ level: String, _ message: String) {
        let entry = "[\(ISO8601DateFormatter().string(from: Date()))] \(level): \(message)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    defer { handle.closeFile() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data)
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
