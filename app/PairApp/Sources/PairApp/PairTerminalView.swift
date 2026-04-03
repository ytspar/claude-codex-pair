import SwiftTerm
import AppKit

/// Subclass of SwiftTerm's LocalProcessTerminalView that preserves the user's
/// scroll position when new output arrives. Without this, any output from the
/// running process snaps the viewport back to the bottom — making it impossible
/// to read scrollback while Claude is working.
///
/// Strategy: when new data arrives while the user has scrolled back, we set a
/// temporary "scroll anchor" (the row the user was reading). For a short window
/// afterwards, any programmatic scroll (layout passes, ensureCaretIsVisible,
/// etc.) is detected and reverted. Real user scroll-wheel events clear the
/// anchor immediately so they're never blocked.
class PairTerminalView: LocalProcessTerminalView {

    /// True when the user has scrolled away from the bottom.
    private(set) var isScrolledBack = false

    /// The row to hold the viewport at while the anchor is active.
    private var scrollAnchor: Int?

    /// Cancels the anchor expiry timer when a new anchor is set.
    private var anchorWorkItem: DispatchWorkItem?

    // MARK: - Output handling

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let wasScrolledBack = isScrolledBack || scrollPosition < 0.999
        let savedYDisp = getTerminal().buffer.yDisp

        // Let SwiftTerm process the data normally (moves cursor, may scroll buffer)
        super.dataReceived(slice: slice)

        if wasScrolledBack {
            pinScroll(to: savedYDisp)
        } else {
            isScrolledBack = false
        }
    }

    // MARK: - Scroll-safe send

    /// Sends text to the terminal without yanking the viewport when scrolled back.
    /// SwiftTerm's `send(data:)` calls `ensureCaretIsVisible()` which we can't
    /// override, so we pin the scroll position around the call.
    func sendPreservingScroll(txt: String) {
        guard isScrolledBack else {
            send(txt: txt)
            return
        }
        let savedRow = getTerminal().buffer.yDisp
        send(txt: txt)
        pinScroll(to: savedRow)
    }

    // MARK: - Scroll tracking

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)

        if let anchor = scrollAnchor {
            // If this scroll came from a user scroll-wheel event, respect it
            // and release the anchor. Otherwise it's a programmatic scroll
            // (layout pass, ensureCaretIsVisible, etc.) — revert it.
            if NSApp.currentEvent?.type == .scrollWheel {
                clearAnchor()
            } else {
                scrollTo(row: anchor, notifyAccessibility: false)
                isScrolledBack = true
                return
            }
        }

        isScrolledBack = position < 0.999
    }

    /// Jump to the latest output (bottom of scrollback).
    func scrollToBottom() {
        clearAnchor()
        scrollDown(lines: 999_999)
        isScrolledBack = false
    }

    // MARK: - Private

    /// Pin the viewport at the given row for a short window, reverting any
    /// programmatic scrolls that try to move it.
    private func pinScroll(to row: Int) {
        scrollAnchor = row
        isScrolledBack = true
        scrollTo(row: row, notifyAccessibility: false)

        // Cancel any previous expiry timer.
        anchorWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scrollAnchor = nil
        }
        anchorWorkItem = work
        // Keep the anchor active for 250 ms — enough to survive SwiftTerm's
        // post-layout scroll passes without interfering with normal use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clearAnchor() {
        scrollAnchor = nil
        anchorWorkItem?.cancel()
        anchorWorkItem = nil
    }
}
