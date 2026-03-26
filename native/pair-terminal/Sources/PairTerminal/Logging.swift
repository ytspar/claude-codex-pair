import Foundation

/// Global flag to suppress NSLog in attach mode (prevents interleaving with PTY output)
var quietMode = false

func ptLog(_ message: String) {
    guard !quietMode else { return }
    NSLog(message)
}
