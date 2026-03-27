import SwiftUI
import AppKit

/// NSTextView wrapper with terminal-style keybindings.
/// Supports: Ctrl+W (delete word), Ctrl+A/E (begin/end of line),
/// Ctrl+K (kill to end), Ctrl+U (kill to beginning), Option+Delete (delete word),
/// plus all standard macOS text keybindings (Cmd+A, Cmd+C/V, etc.)
struct TerminalTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var cursorColor: NSColor
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = ScratchpadNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = cursorColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onEscape = onEscape
        textView.onCommandReturn = onCommandReturn

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ScratchpadNSTextView else { return }

        // Only update if text changed externally (e.g. clear)
        if textView.string != text {
            textView.string = text
        }

        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = cursorColor
        textView.onEscape = onEscape
        textView.onCommandReturn = onCommandReturn
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

/// NSTextView subclass with terminal keybindings and Cmd+Enter / Escape handling.
class ScratchpadNSTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Enter → send
        if mods.contains(.command) && event.keyCode == 36 {
            onCommandReturn?()
            return
        }

        // Escape → clear
        if event.keyCode == 53 {
            onEscape?()
            return
        }

        // Ctrl+W → delete word backward
        if mods.contains(.control) && event.charactersIgnoringModifiers == "w" {
            deleteWordBackward(nil)
            return
        }

        // Ctrl+U → delete to beginning of line
        if mods.contains(.control) && event.charactersIgnoringModifiers == "u" {
            moveToBeginningOfLine(nil)
            deleteToEndOfLine(nil)
            return
        }

        // Ctrl+K → delete to end of line
        if mods.contains(.control) && event.charactersIgnoringModifiers == "k" {
            deleteToEndOfLine(nil)
            return
        }

        // Ctrl+A → beginning of line
        if mods.contains(.control) && event.charactersIgnoringModifiers == "a" {
            moveToBeginningOfLine(nil)
            return
        }

        // Ctrl+E → end of line
        if mods.contains(.control) && event.charactersIgnoringModifiers == "e" {
            moveToEndOfLine(nil)
            return
        }

        super.keyDown(with: event)
    }
}
