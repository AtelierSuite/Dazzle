import Foundation

/// `a:scene3d`: the camera a shape is seen through and the lights on it.
/// Dazzle draws an approximation of it, keeps it as the file had it, and
/// writes it again when its bevel, depth or camera are changed.
public struct Scene3D: Equatable, Hashable, Sendable {
    /// `a:camera prst`, such as `orthographicFront`, `obliqueTopLeft` or `perspectiveRelaxed`.
    public var camera: String
    /// `a:camera/a:rot`, degrees: turned up or down, left or right, and about the line of sight.
    public var cameraRotation: Rotation?
    /// `a:lightRig rig`, such as `threePt`, `harsh` or `flat`.
    public var lightRig: String
    /// `a:lightRig dir`: where the light comes from, `t`, `tl`, `l`, `bl`, `b`, `br`, `r` or `tr`.
    public var lightDirection: String
    /// `a:lightRig/a:rot`, degrees.
    public var lightRotation: Rotation?

    public struct Rotation: Equatable, Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var revolution: Double

        public init(latitude: Double = 0, longitude: Double = 0, revolution: Double = 0) {
            self.latitude = latitude
            self.longitude = longitude
            self.revolution = revolution
        }

        init?(element: XMLElement?) {
            guard let element else { return nil }
            func degrees(_ key: String) -> Double { Double(element.attribute(key).flatMap(Int.init) ?? 0) / 60_000 }
            self.init(latitude: degrees("lat"), longitude: degrees("lon"), revolution: degrees("rev"))
        }

        var xml: String {
            func angle(_ degrees: Double) -> Int { Int((degrees * 60_000).rounded()) }
            return "<a:rot lat=\"\(angle(latitude))\" lon=\"\(angle(longitude))\" rev=\"\(angle(revolution))\"/>"
        }
    }

    public init(
        camera: String = "orthographicFront", cameraRotation: Rotation? = nil, lightRig: String = "threePt",
        lightDirection: String = "t", lightRotation: Rotation? = nil
    ) {
        self.camera = camera
        self.cameraRotation = cameraRotation
        self.lightRig = lightRig
        self.lightDirection = lightDirection
        self.lightRotation = lightRotation
    }

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        let camera = element.firstChild(named: "camera")
        let light = element.firstChild(named: "lightRig")
        self.init(
            camera: camera?.attribute("prst") ?? "orthographicFront",
            cameraRotation: Rotation(element: camera?.firstChild(named: "rot")),
            lightRig: light?.attribute("rig") ?? "threePt",
            lightDirection: light?.attribute("dir") ?? "t",
            lightRotation: Rotation(element: light?.firstChild(named: "rot"))
        )
    }

    /// The scene as `a:scene3d`.
    public var xml: String {
        let camera = cameraRotation.map { "<a:camera prst=\"\(XMLLite.escape(self.camera))\">\($0.xml)</a:camera>" }
            ?? "<a:camera prst=\"\(XMLLite.escape(self.camera))\"/>"
        let rig = "<a:lightRig rig=\"\(XMLLite.escape(lightRig))\" dir=\"\(XMLLite.escape(lightDirection))\""
        let light = lightRotation.map { rig + ">\($0.xml)</a:lightRig>" } ?? rig + "/>"
        return "<a:scene3d>\(camera)\(light)</a:scene3d>"
    }
}

/// `a:sp3d`: a shape's bevels, depth, contour and surface. Dazzle draws an
/// approximation of it, and edits its top bevel and depth.
public struct Shape3D: Equatable, Hashable, Sendable {
    /// `a:bevelT`: the bevel on the face that looks at the camera.
    public var topBevel: Bevel?
    /// `a:bevelB`: the bevel on the back, seen only from behind.
    public var bottomBevel: Bevel?
    /// `extrusionH`: EMU the shape stands out from the slide.
    public var extrusionHeight: Int
    /// `a:extrusionClr`: the sides' colour, or the fill's when not given.
    public var extrusionColor: DrawingColor?
    /// `contourW`: EMU of the band round the shape's edge.
    public var contourWidth: Int
    /// `a:contourClr`.
    public var contourColor: DrawingColor?
    /// `prstMaterial`, such as `warmMatte`, `plastic` or `metal`.
    public var material: String

    /// `a:bevelT` and `a:bevelB`: a profile cut round the edge, `width` in
    /// from it and `height` deep.
    public struct Bevel: Equatable, Hashable, Sendable {
        /// EMU.
        public var width: Int
        /// EMU.
        public var height: Int
        /// `prst`, such as `circle`, `angle` or `artDeco`.
        public var preset: String

        public init(width: Int = 76_200, height: Int = 76_200, preset: String = "circle") {
            self.width = width
            self.height = height
            self.preset = preset
        }

        init?(element: XMLElement?) {
            guard let element else { return nil }
            self.init(
                width: element.attribute("w").flatMap(Int.init) ?? 76_200,
                height: element.attribute("h").flatMap(Int.init) ?? 76_200,
                preset: element.attribute("prst") ?? "circle"
            )
        }

        func xml(named name: String) -> String {
            "<a:\(name) w=\"\(width)\" h=\"\(height)\" prst=\"\(XMLLite.escape(preset))\"/>"
        }
    }

    public init(
        topBevel: Bevel? = nil, bottomBevel: Bevel? = nil, extrusionHeight: Int = 0, extrusionColor: DrawingColor? = nil,
        contourWidth: Int = 0, contourColor: DrawingColor? = nil, material: String = "warmMatte"
    ) {
        self.topBevel = topBevel
        self.bottomBevel = bottomBevel
        self.extrusionHeight = extrusionHeight
        self.extrusionColor = extrusionColor
        self.contourWidth = contourWidth
        self.contourColor = contourColor
        self.material = material
    }

    public init?(element: XMLElement?) {
        guard let element else { return nil }
        self.init(
            topBevel: Bevel(element: element.firstChild(named: "bevelT")),
            bottomBevel: Bevel(element: element.firstChild(named: "bevelB")),
            extrusionHeight: max(element.attribute("extrusionH").flatMap(Int.init) ?? 0, 0),
            extrusionColor: DrawingColor.first(in: element.firstChild(named: "extrusionClr")),
            contourWidth: max(element.attribute("contourW").flatMap(Int.init) ?? 0, 0),
            contourColor: DrawingColor.first(in: element.firstChild(named: "contourClr")),
            material: element.attribute("prstMaterial") ?? "warmMatte"
        )
    }

    /// Whether it gives the shape nothing to draw: no bevels, depth or contour.
    public var isEmpty: Bool { topBevel == nil && bottomBevel == nil && extrusionHeight == 0 && contourWidth == 0 }

    /// The shape's 3-D as `a:sp3d`.
    public var xml: String {
        var attributes = ""
        if extrusionHeight > 0 { attributes += " extrusionH=\"\(extrusionHeight)\"" }
        if contourWidth > 0 { attributes += " contourW=\"\(contourWidth)\"" }
        if material != "warmMatte" { attributes += " prstMaterial=\"\(XMLLite.escape(material))\"" }
        var children = (topBevel?.xml(named: "bevelT") ?? "") + (bottomBevel?.xml(named: "bevelB") ?? "")
        if let extrusionColor { children += "<a:extrusionClr>\(extrusionColor.xml)</a:extrusionClr>" }
        if let contourColor { children += "<a:contourClr>\(contourColor.xml)</a:contourClr>" }
        return children.isEmpty ? "<a:sp3d\(attributes)/>" : "<a:sp3d\(attributes)>\(children)</a:sp3d>"
    }

    /// The same, with `phClr` standing for `color`.
    public func replacingPlaceholder(with color: DrawingColor?) -> Shape3D {
        guard let color else { return self }
        var copy = self
        copy.extrusionColor = extrusionColor?.replacingPlaceholder(with: color)
        copy.contourColor = contourColor?.replacingPlaceholder(with: color)
        return copy
    }
}
