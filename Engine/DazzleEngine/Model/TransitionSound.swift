import Foundation

/// The sound a slide's transition plays, or the sound it stops: PowerPoint's
/// `p:sndAc`, with `p:stSnd` or `p:endSnd`.
public struct TransitionSound: Equatable, Hashable, Sendable {
    /// The slide relationship of the audio part; `nil` stops whatever is playing.
    public var relationshipID: String?
    public var name: String?
    /// Plays until the next sound starts or one stops it.
    public var loops: Bool
    public var isBuiltIn: Bool

    public init(relationshipID: String?, name: String? = nil, loops: Bool = false, isBuiltIn: Bool = false) {
        self.relationshipID = relationshipID
        self.name = name
        self.loops = loops
        self.isBuiltIn = isBuiltIn
    }

    public static let stop = TransitionSound(relationshipID: nil)

    public var stopsSound: Bool { relationshipID == nil }

    /// The sound in the first of a transition's versions that has one.
    public init?(versions: [XMLElement]) {
        guard let action = versions.lazy.compactMap({ $0.firstChild(named: "sndAc") }).first else { return nil }
        if action.firstChild(named: "endSnd") != nil {
            self = .stop
            return
        }
        guard let start = action.firstChild(named: "stSnd"), let sound = start.firstChild(named: "snd"),
              let id = sound.attribute("embed") else { return nil }
        self.init(
            relationshipID: id, name: sound.attribute("name"),
            loops: ["1", "true"].contains(start.attribute("loop") ?? ""),
            isBuiltIn: ["1", "true"].contains(sound.attribute("builtIn") ?? "")
        )
    }

    /// `p:sndAc`, using the `p` and `r` prefixes.
    public var xml: String {
        guard let relationshipID else { return "<p:sndAc><p:endSnd/></p:sndAc>" }
        var attributes = " r:embed=\"\(XMLLite.escape(relationshipID))\""
        if let name { attributes += " name=\"\(XMLLite.escape(name))\"" }
        if isBuiltIn { attributes += " builtIn=\"1\"" }
        return "<p:sndAc><p:stSnd\(loops ? " loop=\"1\"" : "")><p:snd\(attributes)/></p:stSnd></p:sndAc>"
    }
}

extension Slide {
    /// The package part of the transition's sound, if it starts one.
    public var transitionSoundPath: String? {
        guard let id = transitionSound?.relationshipID,
              let relationship = relationships.first(where: { $0.id == id }), !relationship.isExternal else { return nil }
        return PackagePath.resolve(relationship.target, from: partName ?? sourcePart ?? "ppt/slides/slide.xml")
    }
}
