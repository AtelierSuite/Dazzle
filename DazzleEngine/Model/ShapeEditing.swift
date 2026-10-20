import CoreGraphics
import Foundation

extension SlideShape {
    /// A table's columns and rows stretched to its frame, after a resize.
    public mutating func fitTableToFrame() {
        guard case .table(var table) = kind else { return }
        let size = table.gridSize
        guard size.width != frame.width || size.height != frame.height else { return }
        table.scale(toWidth: frame.width, height: frame.height)
        kind = .table(table)
        edits.insert(.table)
    }

    /// The slide-space box a turned shape covers, in points.
    public var boundingBox: CGRect {
        let frame = self.frame.points
        guard rotation.truncatingRemainder(dividingBy: 180) != 0 else { return frame }
        let radians = rotation * .pi / 180
        let width = abs(frame.width * cos(radians)) + abs(frame.height * sin(radians))
        let height = abs(frame.width * sin(radians)) + abs(frame.height * cos(radians))
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// A group member as it stands on the slide once out of `group`: moved
    /// from the group's member space into slide space, and turned and
    /// flipped as the group turned and flipped it.
    public static func ungrouped(_ member: SlideShape, from group: SlideShape, childFrame: EMURect) -> SlideShape {
        var shape = SlideRenderer.placed(member, from: childFrame, into: group.frame)
        let groupFrame = group.frame.points
        let center = CGPoint(x: groupFrame.midX, y: groupFrame.midY)
        var frame = shape.frame.points
        var middle = CGPoint(x: frame.midX, y: frame.midY)
        if group.flipsHorizontally {
            middle.x = 2 * center.x - middle.x
            shape.flipsHorizontally.toggle()
            shape.rotation = -shape.rotation
        }
        if group.flipsVertically {
            middle.y = 2 * center.y - middle.y
            shape.flipsVertically.toggle()
            shape.rotation = -shape.rotation
        }
        if group.rotation != 0 {
            let radians = group.rotation * .pi / 180
            let dx = middle.x - center.x
            let dy = middle.y - center.y
            middle = CGPoint(x: center.x + dx * cos(radians) - dy * sin(radians), y: center.y + dx * sin(radians) + dy * cos(radians))
        }
        frame.origin = CGPoint(x: middle.x - frame.width / 2, y: middle.y - frame.height / 2)
        shape.frame = EMURect(points: frame)
        shape.rotation = normalized(shape.rotation + group.rotation)
        shape.hasOwnFrame = true
        shape.edits.insert(.transform)
        return shape
    }

    /// A copy with an identity of its own, everywhere down its children.
    public init(copying shape: SlideShape) {
        self = SlideShape.copy(of: shape)
    }

    private static func copy(of shape: SlideShape) -> SlideShape {
        var copy = SlideShape(id: UUID(), shapeID: shape.shapeID, name: shape.name, kind: shape.kind, frame: shape.frame)
        copy.hasOwnFrame = shape.hasOwnFrame
        copy.rotation = shape.rotation
        copy.flipsHorizontally = shape.flipsHorizontally
        copy.flipsVertically = shape.flipsVertically
        copy.placeholder = shape.placeholder
        copy.geometry = shape.geometry
        copy.fill = shape.fill
        copy.line = shape.line
        copy.shadow = shape.shadow
        copy.reflection = shape.reflection
        copy.style = shape.style
        copy.text = shape.text
        copy.textFrame = shape.textFrame
        copy.isTextBox = shape.isTextBox
        copy.altText = shape.altText
        copy.link = shape.link
        copy.isLocked = shape.isLocked
        copy.source = shape.source
        copy.edits = shape.edits
        return copy
    }
}
