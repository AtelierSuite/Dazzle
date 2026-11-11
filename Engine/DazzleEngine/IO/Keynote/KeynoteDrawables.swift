#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Writes one Keynote slide's drawables as `p:spTree` children, collecting
/// the relationships they need. A template slide is written as a layout:
/// its title and body placeholders are kept, sample text and all, to
/// format what slides made from it say.
public struct KeynoteSlideWriter {
    public let archive: KeynoteArchive
    public let styles: KeynoteStyles
    public let text: KeynoteText
    public let media: KeynoteMedia
    public let partName: String
    /// The document's locale, which table values are written in.
    public let locale: Locale

    public private(set) var relationships: [Relationship]
    public private(set) var skipped: Set<UInt32> = []
    /// Whether a chart Dazzle can't read was written as a stand-in.
    public private(set) var hasChartStandIns = false
    /// Whether a table Dazzle can't read was written as a stand-in.
    public private(set) var hasTableStandIns = false
    private var nextShapeID = 2
    /// Measured frames for text that grows to fit, by shape id.
    private let fittedFrames: [Int: EMURect]
    public let isLayout: Bool
    /// The template slide's placeholders by kind, whose frame and style a
    /// slide's placeholder takes when it has none of its own.
    public var templatePlaceholders: [Int: ProtoMessage] = [:]

    /// `parent` is the part's first relationship: a slide's layout, or a layout's master.
    public init(
        archive: KeynoteArchive, media: KeynoteMedia, partName: String, parent: Relationship,
        isLayout: Bool = false, fittedFrames: [Int: EMURect] = [:]
    ) {
        self.archive = archive
        styles = KeynoteStyles(archive: archive)
        text = KeynoteText(archive: archive, styles: styles)
        self.media = media
        self.partName = partName
        locale = archive.locale
        self.fittedFrames = fittedFrames
        self.isLayout = isLayout
        relationships = [parent]
    }

    /// A relationship to the picture, adding one the first time it is asked for.
    public mutating func imageRelationship(_ data: UInt64) -> String? {
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

    /// The shape id each drawable was written with, for builds to name.
    public private(set) var shapeIDs: [UInt64: Int] = [:]
    /// The storage each shape's text was read from, by shape id, so that
    /// text edited in Dazzle can be written back to it.
    public private(set) var textStorages: [Int: UInt64] = [:]

    public mutating func drawable(_ identifier: UInt64) -> String? {
        // A drawable's first id is its own; a group's children follow it.
        let shapeID = nextShapeID
        let xml = drawableXML(identifier)
        if xml != nil { shapeIDs[identifier] = shapeID }
        return xml
    }

    private mutating func drawableXML(_ identifier: UInt64) -> String? {
        guard let object = archive[identifier] else { return nil }
        switch object.type {
        case KeynoteType.shape:
            return shape(object.message, storage: nil, isTextBox: false)
        case KeynoteType.connectionLine:
            // A `TSD.ConnectionLineArchive` keeps its line as the shape it extends.
            guard let line = object.message.message(1) else { return nil }
            return shape(line, storage: nil, isTextBox: false, isConnector: true)
        case KeynoteType.shapeInfo:
            return shapeInfo(object.message)
        case KeynoteType.placeholder:
            guard let info = object.message.message(1) else { return nil }
            let type: String? = switch object.message.int(2) {
            case 2: "title"
            case 3: "body"
            default: nil
            }
            if isLayout {
                return type.flatMap { shapeInfo(info, placeholder: $0) }
            }
            // An empty placeholder shows only its prompt, which never plays.
            let storage = archive[info.reference(4) ?? info.reference(3) ?? info.reference(2)]
            guard !text.plainText(storage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let inherited = object.message.int(2).flatMap { templatePlaceholders[$0] }?.message(1)
            return shapeInfo(info, placeholder: type, inherited: inherited)
        case KeynoteType.image:
            if let image = image(object.message) { return image }
            // An equation keeps its place when its picture can't be shown.
            if Self.isEquation(object.message),
               let standIn = standIn(object.message.message(1), label: String(localized: "Object.Equation", bundle: .engine)) {
                hasEquationStandIns = true
                return standIn
            }
            return nil
        case KeynoteType.movie:
            return movie(object)
        case KeynoteType.group:
            return group(object.message)
        case KeynoteType.chart:
            if let chart = chart(object.message) { return chart }
            // A chart Dazzle can't read keeps its place, shown as a stand-in.
            if let standIn = chartStandIn(object.message) {
                hasChartStandIns = true
                return standIn
            }
            skipped.insert(object.type)
            return nil
        case KeynoteType.table:
            if let table = table(object.message) { return table }
            // A table Dazzle can't read keeps its place, shown as a stand-in.
            if let standIn = tableStandIn(object.message) {
                hasTableStandIns = true
                return standIn
            }
            skipped.insert(object.type)
            return nil
        case KeynoteType.olderChart:
            // Charts from before 2013 are kept in their place as stand-ins.
            if let standIn = chartStandIn(object.message) {
                hasChartStandIns = true
                return standIn
            }
            skipped.insert(object.type)
            return nil
        default:
            // Anything else with a place on the slide keeps it, as a stand-in.
            if let standIn = standIn(Self.drawableArchive(in: object.message), label: String(localized: "Object.Other", bundle: .engine)) {
                hasObjectStandIns = true
                return standIn
            }
            skipped.insert(object.type)
            return nil
        }
    }

    /// The `TSD.DrawableArchive` of an object of a kind Dazzle doesn't know.
    /// Every drawable keeps it first, or first within the drawable it
    /// extends: a shape's, a shape with text's, and so on. It is the first
    /// message along the way that holds a geometry with a size.
    static func drawableArchive(in message: ProtoMessage) -> ProtoMessage? {
        var candidate = message.message(1)
        for _ in 0..<4 {
            guard let current = candidate else { return nil }
            if let size = current.message(1)?.message(2), size.float(1) != nil, size.float(2) != nil { return current }
            candidate = current.message(1)
        }
        return nil
    }

    /// Whether a `TSD.ImageArchive` is an equation, which keeps the source
    /// it was typeset from alongside its picture.
    static func isEquation(_ image: ProtoMessage) -> Bool {
        image.has(103) || image.has(100)
    }

    /// Whether an equation was written as a stand-in.
    public private(set) var hasEquationStandIns = false
    /// Whether an object of a kind Dazzle doesn't know was written as a stand-in.
    public private(set) var hasObjectStandIns = false
    /// Whether a 3D object was written, which shows only a still picture of itself.
    public private(set) var has3DObjects = false

    /// An object Dazzle can't show, kept in its place as a stand-in: a box
    /// naming what it is. PowerPoint shows the box as it is; Dazzle reads it
    /// back as a stand-in by the extension it carries.
    private mutating func standIn(_ drawable: ProtoMessage?, label: String) -> String? {
        guard let frame = Frame(drawable?.message(1)), frame.size.width > 0, frame.size.height > 0 else { return nil }
        let nonVisual = nonVisual(drawable, name: label)
        let text = XMLLite.escape(label)
        return """
            <p:sp><p:nvSpPr>\(nonVisual)<p:cNvSpPr/><p:nvPr>\(StandIn.extensionXML(label: label))</p:nvPr></p:nvSpPr>\
            <p:spPr>\(frame.xml())<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
            <a:solidFill><a:srgbClr val="F2F2F5"/></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="B3B3BF"/>\
            </a:solidFill><a:prstDash val="dash"/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" anchor="ctr" rtlCol="0">\
            <a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="en-US" sz="1400">\
            <a:solidFill><a:srgbClr val="666673"/></a:solidFill></a:rPr><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
            """
    }

    /// Older documents keep a shape's text in the deprecated field 2.
    private mutating func shapeInfo(_ info: ProtoMessage, placeholder: String? = nil, inherited: ProtoMessage? = nil) -> String? {
        guard let shape = info.message(1) else { return nil }
        let storage = archive[info.reference(4) ?? info.reference(3) ?? info.reference(2)]
        return self.shape(
            shape, storage: storage, isTextBox: placeholder == nil && info.bool(6) == true,
            placeholder: placeholder, inherited: inherited
        )
    }

    private mutating func nonVisual(_ drawable: ProtoMessage?, name: String, playsMedia: Bool = false) -> String {
        let id = takeShapeID()
        var attributes = " id=\"\(id)\" name=\"\(XMLLite.escape(name)) \(id - 1)\""
        if let description = drawable?.string(8), !description.isEmpty {
            attributes += " descr=\"\(XMLLite.escape(description))\""
        }
        if let url = drawable?.string(4), let relationship = hyperlinkRelationship(url) {
            return "<p:cNvPr\(attributes)><a:hlinkClick r:id=\"\(relationship)\"/></p:cNvPr>"
        }
        if playsMedia {
            return "<p:cNvPr\(attributes)><a:hlinkClick r:id=\"\" action=\"ppaction://media\"/></p:cNvPr>"
        }
        return "<p:cNvPr\(attributes)/>"
    }

    /// `placeholder` is the `p:ph` type for a title or body; `inherited` the
    /// template's shape for it, which fills in what the shape leaves out.
    /// A connector, such as a connection line, is a `p:cxnSp`, which holds no text.
    private mutating func shape(
        _ shape: ProtoMessage, storage: KeynoteArchive.Object?, isTextBox: Bool, placeholder: String? = nil,
        inherited: ProtoMessage? = nil, isConnector: Bool = false
    ) -> String? {
        let ownDrawable = shape.message(1)
        let drawable = ownDrawable?.has(1) == true ? ownDrawable : inherited?.message(1) ?? ownDrawable
        guard var frame = Frame(drawable?.message(1)) else { return nil }
        let style = shape.reference(2) ?? inherited?.reference(2)
        let pathSource = shape.message(3).flatMap { $0.fields.isEmpty ? nil : $0 } ?? inherited?.message(3)
        let opacity = styles.opacity(style) * drawingOpacity

        let fill = KeynoteStyles.fill(styles.drawingProperty(style, .fill), opacity: opacity) { imageRelationship($0) }
            ?? "<a:noFill/>"
        let line = KeynoteStyles.line(
            styles.drawingProperty(style, .stroke),
            head: styles.drawingProperty(style, .headLineEnd), tail: styles.drawingProperty(style, .tailLineEnd),
            opacity: opacity
        )
        let effects = KeynoteStyles.effects(
            styles.drawingProperty(style, .shadow), reflection: styles.drawingProperty(style, .reflection), opacity: opacity
        ) ?? ""
        // The shape takes the id its non-visual properties are about to claim.
        // Text that sets its own width saves no size, only the point it grows
        // from; measuring it gives it one.
        let wraps = storage == nil || !frame.growsWide
        if let fitted = fittedFrames[nextShapeID] {
            frame.origin = CGPoint(x: EMU.points(fitted.x), y: EMU.points(fitted.y))
            frame.size = CGSize(width: EMU.points(fitted.width), height: EMU.points(fitted.height))
        }
        let transform = frame.xml(flipH: pathSource?.bool(1) ?? false, flipV: pathSource?.bool(2) ?? false)
        let geometry = KeynoteGeometry.xml(pathSource, size: frame.size)

        let name = switch placeholder {
        case "title"?: "Title"
        case "body"?: "Body"
        default: isConnector ? "Connector" : isTextBox ? "TextBox" : storage == nil ? "Shape" : "Text"
        }
        let shapeID = nextShapeID
        let nonVisual = nonVisual(drawable, name: name)
        if isConnector {
            return """
                <p:cxnSp><p:nvCxnSpPr>\(nonVisual)<p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>\
                <p:spPr>\(transform)\(geometry)\(fill)\(line)\(effects)</p:spPr></p:cxnSp>
                """
        }
        let textBody = textBody(storage, style: style, growsToFit: frame.growsToFit, wraps: wraps)
        if let storage, !textBody.isEmpty { textStorages[shapeID] = storage.identifier }
        let properties = switch placeholder {
        case "body"?: "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr>"
        case let type?: "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"\(type)\"/></p:nvPr>"
        case nil: "<p:cNvSpPr\(isTextBox ? " txBox=\"1\"" : "")/><p:nvPr/>"
        }
        return """
            <p:sp><p:nvSpPr>\(nonVisual)\(properties)</p:nvSpPr>\
            <p:spPr>\(transform)\(geometry)\(fill)\(line)\(effects)</p:spPr>\(textBody)</p:sp>
            """
    }

    private func textBody(_ storage: KeynoteArchive.Object?, style: UInt64?, growsToFit: Bool, wraps: Bool) -> String {
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
            <p:txBody><a:bodyPr wrap="\(wraps ? "square" : "none")" lIns="\(inset(1))" tIns="\(inset(2))" rIns="\(inset(3))" \
            bIns="\(inset(4))" anchor="\(anchor)" rtlCol="0"\(vertical)>\(autofit)</a:bodyPr>\
            \(isLayout ? text.listStyle(storage) : "<a:lstStyle/>")\
            \(paragraphs)</p:txBody>
            """
    }

    /// The first of the image's pictures that can be shown: the one it
    /// shows, the original, or failing those, its thumbnail, as an equation
    /// typeset into a PDF a platform can't draw may have one it can.
    private mutating func image(_ image: ProtoMessage) -> String? {
        let pictures = [11, 13, 12].compactMap { image.reference($0) }
        guard let data = pictures.first(where: { media.path(for: $0) != nil }) else { return nil }
        return picture(drawable: image.message(1), data: data, style: image.reference(3), mask: archive[image.reference(5)])
    }

    /// `media` is what a movie's `p:nvPr` says about the file it plays; a
    /// movie may have no picture to show until it does.
    private mutating func picture(
        drawable: ProtoMessage?, data: UInt64?, style: UInt64?, mask: KeynoteArchive.Object?, media: String? = nil
    ) -> String? {
        let relationship = data.flatMap { imageRelationship($0) }
        guard var frame = Frame(drawable?.message(1)), relationship != nil || media != nil else { return nil }
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
        let opacity = styles.opacity(style) * drawingOpacity
        let alpha = opacity < 0.999 ? "<a:alphaModFix amt=\"\(Int(opacity * 100_000))\"/>" : ""
        let line = KeynoteStyles.line(styles.drawingProperty(style, .stroke), head: nil, tail: nil, opacity: 1)
        let effects = KeynoteStyles.effects(
            styles.drawingProperty(style, .shadow), reflection: styles.drawingProperty(style, .reflection), opacity: opacity
        ) ?? ""
        let nonVisual = nonVisual(drawable, name: media == nil ? "Picture" : "Movie", playsMedia: media != nil)
        let blip = relationship.map { "<a:blip r:embed=\"\($0)\">\(alpha)</a:blip>" } ?? ""
        return """
            <p:pic><p:nvPicPr>\(nonVisual)<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr>\
            <p:nvPr\(media.map { ">\($0)</p:nvPr>" } ?? "/>")</p:nvPicPr><p:blipFill>\(blip)\(sourceRect)\
            <a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr>\(frame.xml())\(geometry)\(line)\(effects)</p:spPr></p:pic>
            """
    }

    /// A `TSD.MovieArchive`: its poster frame, or for a sound its icon,
    /// playing the movie's file, copied into the package as PowerPoint 2010
    /// and later embed one, or failing that, the address it streams from.
    /// A movie with neither shows its poster frame and nothing more.
    private mutating func movie(_ object: KeynoteArchive.Object) -> String? {
        let movie = object.message
        // A 3D object, a `TSA.Object3DInfo` extending the movie, can't turn
        // here; it shows the still picture it keeps of itself, or a stand-in.
        if let object3D = movie.message(200) {
            has3DObjects = true
            let still = [object3D.reference(5), movie.reference(15)].compactMap { $0 }.first { media.path(for: $0) != nil }
            if let still, let xml = picture(drawable: movie.message(1), data: still, style: movie.reference(19), mask: nil) {
                return xml
            }
            return standIn(movie.message(1), label: String(localized: "Object.3D", bundle: .engine))
        }
        let isAudio = movie.bool(9) == true
        let poster = isAudio ? movie.reference(16) ?? movie.reference(15) : movie.reference(15) ?? movie.reference(16)
        let linkType = isAudio ? OOXML.RelationshipType.audio : OOXML.RelationshipType.video
        let file = isAudio ? "audioFile" : "videoFile"
        var nvPr: String?
        if let data = movie.reference(14) ?? movie.reference(22), let path = media.mediaPath(for: data) {
            let target = PackagePath.relativeTarget(to: path, from: partName)
            let link = addRelationship(type: linkType, target: target)
            let embed = addRelationship(type: OOXML.RelationshipType.media, target: target)
            nvPr = """
                <a:\(file) r:link="\(link)"/><p:extLst><p:ext uri="{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}">\
                <p14:media xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" r:embed="\(embed)"/>\
                </p:ext></p:extLst>
                """
        } else if let url = movie.string(17), let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            let link = addRelationship(type: linkType, target: url, isExternal: true)
            nvPr = "<a:\(file) r:link=\"\(link)\"/>"
        }
        guard let nvPr else {
            skipped.insert(object.type)
            // The poster frame stands in for the movie.
            return poster.flatMap { picture(drawable: movie.message(1), data: $0, style: movie.reference(19), mask: nil) }
        }
        let shapeID = nextShapeID
        guard let xml = picture(drawable: movie.message(1), data: poster, style: movie.reference(19), mask: nil, media: nvPr)
        else { return nil }
        mediaDrawables.insert(object.identifier)
        // Keynote's volume runs from 0 to 1; PowerPoint's in thousandths of a percent.
        let volume = Int((min(max(Double(movie.float(7) ?? 1), 0), 1) * 100_000).rounded())
        let loops = (movie.int(24) ?? movie.int(6) ?? 0) != 0
        mediaNodes.append((shapeID: shapeID, isAudio: isAudio, volume: volume, loops: loops))
        return xml
    }

    private mutating func addRelationship(type: String, target: String, isExternal: Bool = false) -> String {
        let id = Relationship.unusedID(in: relationships)
        relationships.append(Relationship(id: id, type: type, target: target, isExternal: isExternal))
        return id
    }

    /// The movies and sounds that play, as PowerPoint's timing keeps each:
    /// how loud, and whether it starts over when it ends. Keynote's back and
    /// forth plays as a loop.
    public private(set) var mediaNodes: [(shapeID: Int, isAudio: Bool, volume: Int, loops: Bool)] = []
    /// The movies brought across as media, which builds can start.
    public private(set) var mediaDrawables: Set<UInt64> = []

    /// A `p:timing` holding the slide's media nodes, or nothing if it has none.
    public var mediaTiming: String {
        guard !mediaNodes.isEmpty else { return "" }
        var nextID = 2
        let nodes = mediaNodes.map { node -> String in
            defer { nextID += 1 }
            let element = node.isAudio ? "audio" : "video"
            return """
                <p:\(element)><p:cMediaNode vol="\(node.volume)"><p:cTn id="\(nextID)" fill="hold" display="0"\
                \(node.loops ? " repeatCount=\"indefinite\"" : "")><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst>\
                </p:cTn><p:tgtEl><p:spTgt spid="\(node.shapeID)"/></p:tgtEl></p:cMediaNode></p:\(element)>
                """
        }
        return """
            <p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>\
            \(nodes.joined())</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>
            """
    }

    private mutating func table(_ info: ProtoMessage) -> String? {
        guard var frame = Frame(info.message(1)?.message(1)), let model = archive[info.reference(2)],
              let table = KeynoteTable(archive: archive, styles: styles, text: text, locale: locale).graphic(model: model)
        else { return nil }
        // The rows and columns say how big the table is.
        frame.size = table.size
        let nonVisual = nonVisual(info.message(1), name: "Table")
        return """
            <p:graphicFrame><p:nvGraphicFramePr>\(nonVisual)<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/>\
            </p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
            \(frame.xml().replacingOccurrences(of: "a:xfrm", with: "p:xfrm"))\(table.xml)</p:graphicFrame>
            """
    }

    /// A table frame with no table in it, which reads as a table stand-in.
    /// It takes the size the table's rows and columns would give it, or the
    /// drawable's own when they say nothing.
    private mutating func tableStandIn(_ info: ProtoMessage) -> String? {
        guard var frame = Frame(info.message(1)?.message(1)) else { return nil }
        let table = KeynoteTable(archive: archive, styles: styles, text: text, locale: locale)
        if let size = archive[info.reference(2)].flatMap({ table.size(model: $0) }) { frame.size = size }
        guard frame.size.width > 0, frame.size.height > 0 else { return nil }
        let nonVisual = nonVisual(info.message(1), name: "Table")
        return """
            <p:graphicFrame><p:nvGraphicFramePr>\(nonVisual)<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/>\
            </p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
            \(frame.xml().replacingOccurrences(of: "a:xfrm", with: "p:xfrm"))<a:graphic>\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"/></a:graphic></p:graphicFrame>
            """
    }

    private mutating func chart(_ drawable: ProtoMessage) -> String? {
        guard let frame = Frame(drawable.message(1)?.message(1)),
              let chart = KeynoteChart(archive: archive, styles: styles).chart(drawable, path: media.nextChartPath),
              let data = ChartWriter.data(for: chart, original: nil) else { return nil }
        let path = media.addChart(data)
        let relationship = Relationship.unusedID(in: relationships)
        relationships.append(Relationship(
            id: relationship, type: OOXML.RelationshipType.chart, target: PackagePath.relativeTarget(to: path, from: partName)
        ))
        let nonVisual = nonVisual(drawable.message(1), name: "Chart")
        return """
            <p:graphicFrame><p:nvGraphicFramePr>\(nonVisual)<p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            \(frame.xml().replacingOccurrences(of: "a:xfrm", with: "p:xfrm"))<a:graphic>\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">\
            <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="\(relationship)"/>\
            </a:graphicData></a:graphic></p:graphicFrame>
            """
    }

    /// A chart frame with no chart in it, which reads as a chart stand-in.
    private mutating func chartStandIn(_ drawable: ProtoMessage) -> String? {
        guard let frame = Frame(drawable.message(1)?.message(1)), frame.size.width > 0, frame.size.height > 0 else { return nil }
        let nonVisual = nonVisual(drawable.message(1), name: "Chart")
        return """
            <p:graphicFrame><p:nvGraphicFramePr>\(nonVisual)<p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
            \(frame.xml().replacingOccurrences(of: "a:xfrm", with: "p:xfrm"))<a:graphic>\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"/></a:graphic></p:graphicFrame>
            """
    }

    /// How opaque the freehand drawing being written is, which DrawingML
    /// can't say of a group, so each of its strokes says it instead.
    private var drawingOpacity = 1.0

    /// A group, or a freehand drawing: a `TSD.GroupArchive` whose strokes
    /// are its children, each a shape with a path.
    private mutating func group(_ group: ProtoMessage) -> String? {
        guard let frame = Frame(group.message(1)?.message(1)) else { return nil }
        // Children are placed in the group's own space, from its top-left
        // corner. The group claims its id before they do.
        let isDrawing = group.has(100)
        let nonVisual = nonVisual(group.message(1), name: isDrawing ? "Drawing" : "Group")
        let outer = drawingOpacity
        if let opacity = group.message(100)?.float(2) { drawingOpacity *= min(max(opacity, 0), 1) }
        let children = group.references(2).compactMap { drawable($0) }
        drawingOpacity = outer
        guard !children.isEmpty else { return nil }
        return """
            <p:grpSp><p:nvGrpSpPr>\(nonVisual)<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>\
            \(frame.xml(children: CGRect(origin: .zero, size: frame.size)))</p:grpSpPr>\(children.joined())</p:grpSp>
            """
    }
}

/// A drawable's `TSD.GeometryArchive`: an unrotated frame and a rotation
/// about its centre.
public struct Frame {
    public var origin: CGPoint
    public var size: CGSize
    public var angle: Double
    /// Whether the height follows the text, in which case Keynote saves none.
    public var growsToFit: Bool
    /// Whether the width follows the text too, the text never wrapping.
    public var growsWide: Bool
    /// Whether the drawable is mirrored left to right.
    public var isFlipped: Bool

    public init?(_ geometry: ProtoMessage?) {
        guard let geometry else { return nil }
        let position = geometry.message(1)
        let size = geometry.message(2)
        origin = CGPoint(x: position?.float(1) ?? 0, y: position?.float(2) ?? 0)
        self.size = CGSize(width: size?.float(1) ?? 0, height: size?.float(2) ?? 0)
        angle = geometry.float(4) ?? 0
        // Flags say which of width and height are fixed.
        let flags = geometry.int(3) ?? 3
        growsToFit = flags & 2 == 0
        growsWide = flags & 1 == 0
        isFlipped = flags & 4 != 0
    }

    public var rect: CGRect { CGRect(origin: origin, size: size) }

    public func xml(flipH: Bool = false, flipV: Bool = false, children: CGRect? = nil) -> String {
        var attributes = ""
        // Keynote turns anticlockwise; DrawingML clockwise.
        var rotation = (-angle).truncatingRemainder(dividingBy: 360)
        if rotation < 0 { rotation += 360 }
        let rotationValue = Int((rotation * 60_000).rounded())
        if rotationValue != 0, rotationValue != 21_600_000 { attributes += " rot=\"\(rotationValue)\"" }
        if flipH != isFlipped { attributes += " flipH=\"1\"" }
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
