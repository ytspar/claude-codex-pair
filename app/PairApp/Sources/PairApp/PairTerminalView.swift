import SwiftTerm
import AppKit

/// Subclass of SwiftTerm's LocalProcessTerminalView that preserves the user's
/// scroll position when new output arrives. Without this, any output from the
/// running process snaps the viewport back to the bottom — making it impossible
/// to read scrollback while Claude is working.
class PairTerminalView: LocalProcessTerminalView {

    /// True when the user has scrolled away from the bottom.
    private(set) var isScrolledBack = false

    // MARK: - Output handling

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let wasScrolledBack = scrollPosition < 0.999
        let savedYDisp = getTerminal().buffer.yDisp

        // Let SwiftTerm process the data normally (moves cursor, may scroll buffer)
        super.dataReceived(slice: slice)

        if wasScrolledBack {
            // Restore viewport to where the user was reading.
            scrollTo(row: savedYDisp, notifyAccessibility: false)
            isScrolledBack = true
        } else {
            isScrolledBack = false
        }
    }

    // MARK: - Scroll tracking

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        isScrolledBack = position < 0.999
    }

    /// Jump to the latest output (bottom of scrollback).
    func scrollToBottom() {
        scrollDown(lines: 999_999)
        isScrolledBack = false
    }
}
