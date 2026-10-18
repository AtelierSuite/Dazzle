import AppKit

/// A clip view that keeps a document smaller than itself in the middle,
/// rather than pinned to the top-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let document = documentView.frame
        if rect.width > document.width {
            rect.origin.x = document.midX - rect.width / 2
        }
        if rect.height > document.height {
            rect.origin.y = document.midY - rect.height / 2
        }
        return rect
    }
}
