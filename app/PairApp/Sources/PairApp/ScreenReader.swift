import Foundation
import SwiftTerm

/// Reads terminal screen content from a SwiftTerm terminal view.
class ScreenReader {

    /// Read the visible screen content as plain text.
    static func readScreen(from termView: LocalProcessTerminalView, scrollback: Bool = false) -> String {
        let terminal = termView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows

        var lines: [String] = []

        for row in 0..<rows {
            var line = ""
            for col in 0..<cols {
                if let ch = terminal.getCharacter(col: col, row: row) {
                    line.append(ch)
                } else {
                    line.append(" ")
                }
            }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }

        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
}
