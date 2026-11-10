import Foundation

extension SlideShape {
    /// The shape as a member of a group: moved from the group's child space
    /// into the group's frame.
    public func placed(from child: EMURect, into frame: EMURect) -> SlideShape {
        guard child.width > 0, child.height > 0 else { return self }
        let scaleX = Double(frame.width) / Double(child.width)
        let scaleY = Double(frame.height) / Double(child.height)
        func map(_ rect: EMURect) -> EMURect {
            EMURect(
                x: frame.x + Int((Double(rect.x - child.x) * scaleX).rounded()),
                y: frame.y + Int((Double(rect.y - child.y) * scaleY).rounded()),
                width: Int((Double(rect.width) * scaleX).rounded()),
                height: Int((Double(rect.height) * scaleY).rounded())
            )
        }
        var placed = self
        placed.frame = map(self.frame)
        placed.textFrame = textFrame.map(map)
        return placed
    }
}
