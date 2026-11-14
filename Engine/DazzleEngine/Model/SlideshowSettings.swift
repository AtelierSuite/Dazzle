import Foundation

/// How every slideshow of a presentation plays: `p:showPr`, PowerPoint's
/// Set Up Slide Show.
public struct SlideshowSettings: Equatable, Sendable {
    /// Which slides a slideshow plays.
    public enum Range: Equatable, Hashable, Sendable {
        case all
        /// Slides by number, counted from 1, both ends included.
        case slides(from: Int, to: Int)
        case customShow(CustomShow.ID)
    }

    public var range: Range = .all
    /// Whether the show starts over after its last slide, until stopped.
    public var loops = false
    /// Whether slides move on by themselves after their time.
    public var usesTimings = true
    public var showsAnimations = true
    /// Whether narrations recorded onto the slides play.
    public var playsNarration = true
    /// A self-running show, browsed at a kiosk: it loops, moves on only by
    /// its timings and links, and starts over when left alone.
    public var isKiosk = false
    /// Seconds without anyone touching a kiosk show before it starts over.
    public var kioskRestartAfter: Double = 300

    public init() {}

    /// Whether the show loops: kiosk shows always do.
    public var playsInLoop: Bool { loops || isKiosk }
    /// Whether slides move on after their time: kiosk shows always do.
    public var followsTimings: Bool { usesTimings || isKiosk }
}
