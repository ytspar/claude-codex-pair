import SwiftUI
import AppKit

/// A thin NSSplitView wrapper that replaces macOS's thick default divider
/// with a 1px line matching our theme.
struct ThinSplitView<Left: View, Right: View>: NSViewRepresentable {
    let left: Left
    let right: Right
    let dividerColor: NSColor
    @Binding var rightWidth: CGFloat

    func makeNSView(context: Context) -> ThinNSSplitView {
        let splitView = ThinNSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.thinDividerColor = dividerColor
        splitView.delegate = context.coordinator

        let leftHost = NSHostingView(rootView: left)
        let rightHost = NSHostingView(rootView: right)

        splitView.addArrangedSubview(leftHost)
        splitView.addArrangedSubview(rightHost)

        // Set holding priorities
        leftHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightHost.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        return splitView
    }

    func updateNSView(_ nsView: ThinNSSplitView, context: Context) {
        nsView.thinDividerColor = dividerColor
        nsView.needsDisplay = true

        // Update right pane width
        if nsView.subviews.count == 2 {
            let rightView = nsView.subviews[1]
            if abs(rightView.frame.width - rightWidth) > 10 {
                nsView.setPosition(nsView.frame.width - rightWidth, ofDividerAt: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rightWidth: $rightWidth)
    }

    class Coordinator: NSObject, NSSplitViewDelegate {
        @Binding var rightWidth: CGFloat

        init(rightWidth: Binding<CGFloat>) {
            _rightWidth = rightWidth
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            return 300  // Min left pane width
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            return splitView.frame.width - 200  // Min right pane width
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView,
                  splitView.subviews.count == 2 else { return }
            let newWidth = splitView.subviews[1].frame.width
            if abs(newWidth - rightWidth) > 1 {
                DispatchQueue.main.async {
                    self.rightWidth = newWidth
                }
            }
        }
    }
}

/// NSSplitView subclass that draws a 1px divider instead of the default thick one.
class ThinNSSplitView: NSSplitView {
    var thinDividerColor: NSColor = NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 0.2)

    override var dividerThickness: CGFloat { 1.0 }

    override func drawDivider(in rect: NSRect) {
        thinDividerColor.setFill()
        rect.fill()
    }
}
