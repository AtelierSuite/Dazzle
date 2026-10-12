import CoreGraphics
import Foundation

/// Writes one Keynote slide's drawables as `p:spTree` children, collecting
/// the relationships they need.
struct KeynoteSlideWriter {
    let archive: KeynoteArchive
    let styles: KeynoteStyles
    let text: KeynoteText
    let media: KeynoteMedia
    let partName: String

    private(set) var relationships: [Relationship]
    private(set) var skipped: Set<UInt32> = []
    private var nextShapeID = 2
    /// Measured frames for text that grows to fit, by shape id.
    private let fittedFrames: [Int: EMURect]

    init(archive: KeynoteArchive, media: KeynoteMedia, partName: String, layout: String, fittedFrames: [Int: EMURect] = [:]) {
        self.archive = archive
        styles = KeynoteStyles(archive: archive)
        text = KeynoteText(archive: archive, styles: styles)
        self.media = media
        self.partName = partName
        self.fittedFrames = fittedFrames
        relationships = [Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout, target: layout)]
    }

    /// A relationship to the picture, adding one the first time it is asked for.
    mutating func imageRelationship(_ data: UInt64) -> String? {
        guard let path = media.path(for: data) else { return nil }
        let target = PackagePath.relativeTarget(to: path, from: partName)
        if let existing = relationships.first(where: { $0.type == OOXML.RelationshipType.image && $0.target == target }) {
            return existing.id
        }
        let id = Relationship.unusedID(in: relationships)
        relationships.append(Relationship(id: id, type: OOXML.RelationshipType.image, target: target))
        return id
    }

    private mutating func hyperlinkRelationship(_ url: String) -> String? {
        guard let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return nil
        }
        let id = Relationship.unusedID(in: relationships)
        relationships.append(Relationship(id: id, type: OOXML.RelationshipType.hyperlink, target: url, isExternal: true))
        return id
    }

    private mutating func takeShapeID() -> Int {
        defer { nextShapeID += 1 }
        return nextShapeID
    }

    // MARK: - Drawables

    mutating func drawable(_ identifier: UInt64) -> String? {
        guard let object = archive[identifier] else { return nil }
        switch object.type {
        case KeynoteType.shape, KeynoteType.connectionLine:
            return shape(object.message, storage: nil, isTextBox: false)
        case KeynoteType.shapeInfo:
            return shapeInfo(object.message)
        case KeynoteType.placeholder:
            guard let info = object.message.message(1) else { return nil }
            // An empty placeholder shows only its prompt, which never plays.
            let storage = archive[info.reference(4) ?? info.reference(3)]
            guard !text.plainText(storage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return shapeInfo(info)
        case KeynoteType.image:
            return image(object.message)
        case KeynoteType.movie:
            skipped.insert(object.type)
            // The poster frame stands in for the movie.
            guard let poster = object.message.reference(15) else { return nil }
            return picture(drawable: object.message.message(1), data: poster, style: object.message.reference(19), mask: nil)
        case KeynoteType.group:
            return group(object.message)
        default:
            skipped.insert(object.type)
            return nil
        }
    }

    private mutating func shapeInfo(_ info: ProtoMessage) -> String? {
        guard let shape = info.message(1) else { return nil }
        let storage = archive[info.reference(4) ?? info.reference(3)]
        return self.shape(shape, storage: storage, isTextBox: info.bool(6) ?? false)
    }

    private mutating func nonVisual(_ drawable: ProtoMessage?, name: String) -> String {
        let id = takeShapeID()
        var attributes = " id=\"\(id)\" name=\"\(XMLLite.escape(name)) \(id - 1)\""
        if let description = drawable?.string(8), !description.isEmpty {
            attributes += " descr=\"\(XMLLite.escape(description))\""
        }
        if let url = drawable?.string(4), let relationship = hyperlinkRelationship(url) {
            return "<p:cNvPr\(attributes)><a:hlinkClick r:id=\"\(relationship)\"/></p:cNvPr>"
        }
        return "<p:cNvPr\(attributes)/>"
    }

    private mutating func shape(_ shape: ProtoMessage, storage: KeynoteArchive.Object?, isTextBox: Bool) -> String? {
        let drawable = shape.message(1)
        guard var frame = Frame(drawable?.message(1)) else { return nil }
        let style = shape.reference(2)
        let pathSource = shape.message(3)
        let opacity = styles.opacity(style)

        let fill = KeynoteStyles.fill(styles.drawingProperty(style, .fill), opacity: opacity) { imageRelationship($0) }
            ?? "<a:noFill/>"
        let line = KeynoteStyles.line(
            styles.drawingProperty(style, .stroke),
            head: styles.drawingProperty(style, .headLineEnd), tail: styles.drawingProperty(style, .tailLineEnd),
            opacity: opacity
        )
        let effects = KeynoteStyles.effects(styles.drawingProperty(style, .shadow), opacity: opacity) ?? ""
        // The shape takes the id its non-visual properties are about to claim.
        if let fitted = fittedFrames[nextShapeID] {
            frame.origin.y = EMU.points(fitted.y)
            frame.size.height = EMU.points(fitted.height)
        }
        let transform = frame.xml(flipH: pathSource?.bool(1) ?? false, flipV: pathSource?.bool(2) ?? false)
        let geometry = KeynoteGeometry.xml(pathSource, size: frame.size)

        let name = isTextBox ? "TextBox" : storage == nil ? "Shape" : "Text"
        let nonVisual = nonVisual(drawable, name: name)
        let textBody = textBody(storage, style: style, growsToFit: frame.growsToFit)
        return """
            <p:sp><p:nvSpPr>\(nonVisual)<p:cNvSpPr\(isTextBox ? " txBox=\"1\"" : "")/><p:nvPr/></p:nvSpPr>\
            <p:spPr>\(transform)\(geometry)\(fill)\(line)\(effects)</p:spPr>\(textBody)</p:sp>
            """
    }

    private func textBody(_ storage: KeynoteArchive.Object?, style: UInt64?, growsToFit: Bool) -> String {
        guard let paragraphs = text.paragraphs(storage) else { return "" }
        func property<Value>(_ read: (ProtoMessage) -> Value?) -> Value? {
            styles.resolve(style) { object in
                object.type == KeynoteType.textShapeStyle ? object.message.message(11).flatMap(read) : nil
            }
        }
        let anchor = switch property({ $0.int(2) }) ?? 0 {
        case 1: "ctr"
        case 2: "b"
        default: "t"
        }
        let padding = property { $0.bool(5) == true ? nil : $0.message(6) }
        // Keynote insets text by 4 points unless the style says otherwise.
        func inset(_ field: Int) -> Int { KeynoteUnits.emu(padding?.float(field) ?? 4) }
        let autofit = if growsToFit {
            "<a:spAutoFit/>"
        } else {
            property({ $0.bool(1) }) == true ? "<a:normAutofit/>" : "<a:noAutofit/>"
        }
        let vertical = property({ $0.bool(8) ?? $0.bool(11) }) == true ? " vert=\"eaVert\"" : ""
        return """
            <p:txBody><a:bodyPr wrap="square" lIns="\(inset(1))" tIns="\(inset(2))" rIns="\(inset(3))" \
            bIns="\(inset(4))" anchor="\(anchor)" rtlCol="0"\(vertical)>\(autofit)</a:bodyPr><a:lstStyle/>\
            \(paragraphs)</p:txBody>
            """
    }

    private mutating func image(_ image: ProtoMessage) -> String? {
        guard let data = image.reference(11) ?? image.reference(13) ?? image.reference(12) else { return nil }
        return picture(drawable: image.message(1), data: data, style: image.reference(3), mask: archive[image.reference(5)])
    }

    private mutating func picture(drawable: ProtoMessage?, data: UInt64, style: UInt64?, mask: KeynoteArchive.Object?) -> String? {
        guard var frame = Frame(drawable?.message(1)), let relationship = imageRelationship(data) else { return nil }
        var sourceRect = ""
        var geometry = "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        // A mask crops the picture: its frame is in the picture's own space.
        if let mask, let maskFrame = Frame(mask.message.message(1)?.message(1)),
           frame.size.width > 0, frame.size.height > 0 {
            let image = frame
            frame.origin.x += maskFrame.origin.x
            frame.origin.y += maskFrame.origin.y
            frame.size = maskFrame.size
            func fraction(_ value: Double, of length: Double) -> Int { Int((value / length * 100_000).rounded()) }
            let left = fraction(maskFrame.origin.x, of: image.size.width)
            let top = fraction(maskFrame.origin.y, of: image.size.height)
            let right = fraction(image.size.width - maskFrame.origin.x - maskFrame.size.width, of: image.size.width)
            let bottom = fraction(image.size.height - maskFrame.origin.y - maskFrame.size.height, of: image.size.height)
            sourceRect = "<a:srcRect l=\"\(left)\" t=\"\(top)\" r=\"\(right)\" b=\"\(bottom)\"/>"
            geometry = KeynoteGeometry.xml(mask.message.message(2), size: frame.size)
        }
        let opacity = styles.opacity(style)
        let alpha = opacity < 0.999 ? "<a:alphaModFix amt=\"\(Int(opacity * 100_000))\"/>" : ""
        let line = KeynoteStyles.line(styles.drawingProperty(style, .stroke), head: nil, tail: nil, opacity: 1)
        let effects = KeynoteStyles.effects(styles.drawingProperty(style, .shadow), opacity: opacity) ?? ""
        let nonVisual = nonVisual(drawable, name: "Picture")
        return """
            <p:pic><p:nvPicPr>\(nonVisual)<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="\(relationship)">\(alpha)</a:blip>\(sourceRect)\
            <a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr>\(frame.xml())\(geometry)\(line)\(effects)</p:spPr></p:pic>
            """
    }

    private mutating func group(_ group: ProtoMessage) -> String? {
        guard let frame = Frame(group.message(1)?.message(1)) else { return nil }
        // Children are placed in the group's own space, from its top-left
        // corner. The group claims its id before they do.
        let nonVisual = nonVisual(group.message(1), name: "Group")
        let children = group.references(2).compactMap { drawable($0) }
        guard !children.isEmpty else { return nil }
        return """
            <p:grpSp><p:nvGrpSpPr>\(nonVisual)<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>\
            \(frame.xml(children: CGRect(origin: .zero, size: frame.size)))</p:grpSpPr>\(children.joined())</p:grpSp>
            """
    }
}

/// A drawable's `TSD.GeometryArchive`: an unrotated frame and a rotation
/// about its centre.
struct Frame {
    var origin: CGPoint
    var size: CGSize
    var angle: Double
    /// Whether the height follows the text, in which case Keynote saves none.
    var growsToFit: Bool

    init?(_ geometry: ProtoMessage?) {
        guard let geometry else { return nil }
        let position = geometry.message(1)
        let size = geometry.message(2)
        origin = CGPoint(x: position?.float(1) ?? 0, y: position?.float(2) ?? 0)
        self.size = CGSize(width: size?.float(1) ?? 0, height: size?.float(2) ?? 0)
        angle = geometry.float(4) ?? 0
        // Flags say which of width and height are fixed.
        growsToFit = (geometry.int(3) ?? 3) & 2 == 0
    }

    var rect: CGRect { CGRect(origin: origin, size: size) }

    func xml(flipH: Bool = false, flipV: Bool = false, children: CGRect? = nil) -> String {
        var attributes = ""
        // Keynote turns anticlockwise; DrawingML clockwise.
        var rotation = (-angle).truncatingRemainder(dividingBy: 360)
        if rotation < 0 { rotation += 360 }
        let rotationValue = Int((rotation * 60_000).rounded())
        if rotationValue != 0, rotationValue != 21_600_000 { attributes += " rot=\"\(rotationValue)\"" }
        if flipH { attributes += " flipH=\"1\"" }
        if flipV { attributes += " flipV=\"1\"" }
        var body = """
            <a:off x="\(KeynoteUnits.emu(origin.x))" y="\(KeynoteUnits.emu(origin.y))"/>\
            <a:ext cx="\(KeynoteUnits.emu(size.width))" cy="\(KeynoteUnits.emu(size.height))"/>
            """
        if let children {
            body += """
                <a:chOff x="\(KeynoteUnits.emu(children.minX))" y="\(KeynoteUnits.emu(children.minY))"/>\
                <a:chExt cx="\(KeynoteUnits.emu(children.width))" cy="\(KeynoteUnits.emu(children.height))"/>
                """
        }
        return "<a:xfrm\(attributes)>\(body)</a:xfrm>"
    }
}
