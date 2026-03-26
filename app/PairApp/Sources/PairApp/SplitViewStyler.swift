import SwiftUI
import AppKit

/// Finds and styles the underlying NSSplitView created by SwiftUI's HSplitView.
/// This is applied as a .background modifier — it walks the view hierarchy to find
/// the NSSplitView and replaces it with our thin-divider subclass.
struct SplitViewStyler: NSViewRepresentable {
    let dividerColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Delay to let SwiftUI build the view hierarchy first
        DispatchQueue.main.async {
            styleSplitView(in: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        styleSplitView(in: nsView)
    }

    private func styleSplitView(in view: NSView) {
        // Walk up to find the NSSplitView that HSplitView creates
        guard let splitView = findSplitView(from: view) else { return }

        // Override the divider drawing
        if let styled = splitView as? StyledNSSplitView {
            styled.customDividerColor = dividerColor
            styled.needsDisplay = true
        } else {
            // Swizzle the divider drawing on the existing split view
            // by using the dividerColor appearance
            splitView.dividerStyle = .thin
            splitView.setValue(dividerColor, forKey: "dividerColor")
        }
    }

    private func findSplitView(from view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let v = current {
            if let split = v as? NSSplitView { return split }
            // Check siblings
            if let parent = v.superview {
                for sibling in parent.subviews {
                    if let split = sibling as? NSSplitView { return split }
                    // One level deeper
                    for child in sibling.subviews {
                        if let split = child as? NSSplitView { return split }
                    }
                }
            }
            current = v.superview
        }
        return nil
    }
}

/// Custom NSSplitView with thin divider.
class StyledNSSplitView: NSSplitView {
    var customDividerColor: NSColor = .separatorColor

    override var dividerThickness: CGFloat { 1.0 }

    override func drawDivider(in rect: NSRect) {
        customDividerColor.setFill()
        rect.fill()
    }
}
