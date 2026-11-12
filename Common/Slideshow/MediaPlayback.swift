import AVFoundation
import DazzleEngine
import Observation

/// The videos and sounds on the slide being shown, and which are playing.
///
/// One player per media shape, shared by every view of the slide: the
/// device, an external display, the presenter's preview. Each shows the
/// same player, so a video plays in step everywhere and is heard once.
@MainActor
@Observable
final class MediaPlayback {
    private(set) var players: [SlideShape.ID: AVPlayer] = [:]
    private(set) var playing: Set<SlideShape.ID> = []
    /// Media that has played, whose picture now stays in place of its poster.
    private(set) var started: Set<SlideShape.ID> = []
    /// How far each fading video is through its fade, from 0 to 1.
    private(set) var fadeLevels: [SlideShape.ID: Double] = [:]
    /// How each one is set to play.
    private(set) var settings: [SlideShape.ID: SlideShape.Media] = [:]
    @ObservationIgnored private var slideID: Slide.ID?
    @ObservationIgnored private var observers: [SlideShape.ID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var timeObservers: [SlideShape.ID: Any] = [:]
    /// Each file's length in seconds, once known.
    @ObservationIgnored private var durations: [SlideShape.ID: Double] = [:]

    /// The media on a slide: each media shape, and where it plays from.
    static func media(on slide: Slide) -> [(shape: SlideShape, media: SlideShape.Media)] {
        slide.shapes.compactMap { shape in
            guard case .picture(let picture) = shape.kind, let media = picture.media else { return nil }
            return (shape, media)
        }
    }

    /// Makes players for the slide now showing, leaving the last slide's
    /// behind, and starts those that start on their own. A sound set to play
    /// across slides keeps playing.
    func show(_ slide: Slide?, in presentation: Presentation?) {
        guard slide?.id != slideID else { return }
        let carried = slide == nil ? [] : Set(playing.filter { settings[$0]?.playsAcrossSlides == true && settings[$0]?.kind == .audio })
        stop(except: carried)
        slideID = slide?.id
        guard let slide, let presentation else { return }
        for (shape, media) in Self.media(on: slide) where players[shape.id] == nil {
            guard let url = Self.url(for: media, in: presentation) else { continue }
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            player.volume = Float(media.effectiveVolume)
            players[shape.id] = player
            settings[shape.id] = media
            prepare(player, id: shape.id, media: media)
            if media.playsAutomatically { play(shape.id) }
        }
    }

    /// Starts the player at its trimmed start, ends it at its trimmed end,
    /// and follows its fades.
    private func prepare(_ player: AVPlayer, id: SlideShape.ID, media: SlideShape.Media) {
        if media.trimStart > 0 {
            player.seek(to: CMTime(seconds: media.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        observers[id, default: []].append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished(id) }
        })
        if let item = player.currentItem {
            Task { [weak self] in
                guard let duration = try? await item.asset.load(.duration), duration.isNumeric else { return }
                self?.loaded(duration: duration.seconds, for: id)
            }
        }
        if media.fadeIn > 0 || media.fadeOut > 0 {
            fadeLevels[id] = media.fadeIn > 0 ? 0 : 1
            timeObservers[id] = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.fade(id, at: time.seconds) }
            }
        }
    }

    private func loaded(duration: Double, for id: SlideShape.ID) {
        guard let media = settings[id], let item = players[id]?.currentItem else { return }
        durations[id] = duration
        if media.trimEnd > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: media.playedRange(duration: duration).upperBound, preferredTimescale: 600)
        }
    }

    private func fade(_ id: SlideShape.ID, at time: Double) {
        guard let media = settings[id], let player = players[id] else { return }
        // Until its length is known, it can only be fading in.
        let duration = durations[id] ?? .infinity
        let level = media.fadeLevel(at: time, duration: duration.isFinite ? duration : time + media.fadeOut + 1)
        player.volume = Float(media.effectiveVolume * level)
        if fadeLevels[id] != level { fadeLevels[id] = level }
    }

    /// Played to its end, or its trimmed end: plays again if it loops, goes
    /// back to its start if it rewinds, and otherwise stays on its last frame.
    private func finished(_ id: SlideShape.ID) {
        guard let player = players[id], let media = settings[id] else { return }
        let start = CMTime(seconds: media.trimStart, preferredTimescale: 600)
        if media.loops {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                MainActor.assumeIsolated { [weak self] in
                    if self?.playing.contains(id) == true { self?.players[id]?.play() }
                }
            }
            return
        }
        playing.remove(id)
        if media.rewinds {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            started.remove(id)
        } else if media.hidesWhenNotPlaying {
            started.remove(id)
        }
    }

    func isPlaying(_ id: SlideShape.ID) -> Bool { playing.contains(id) }

    /// Whether a video is playing full screen, over the whole slide.
    var fullScreenVideo: SlideShape.ID? {
        playing.first { settings[$0]?.playsFullScreen == true && settings[$0]?.kind == .video }
    }

    /// How opaque a video's picture is, as it fades in and out.
    func opacity(of id: SlideShape.ID) -> Double {
        started.contains(id) ? fadeLevels[id] ?? 1 : 0
    }

    func toggle(_ id: SlideShape.ID) {
        if playing.contains(id) { pause(id) } else { play(id) }
    }

    func play(_ id: SlideShape.ID) {
        guard let player = players[id] else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        // Played through once already: from the start again.
        if let media = settings[id], let item = player.currentItem, let duration = durations[id],
           player.currentTime().seconds >= media.playedRange(duration: duration).upperBound - 0.05 {
            item.seek(to: CMTime(seconds: media.trimStart, preferredTimescale: 600), toleranceBefore: .zero,
                      toleranceAfter: .zero, completionHandler: nil)
        }
        player.play()
        playing.insert(id)
        started.insert(id)
    }

    func pause(_ id: SlideShape.ID) {
        players[id]?.pause()
        playing.remove(id)
    }

    func stopAll() {
        stop(except: [])
    }

    private func stop(except kept: Set<SlideShape.ID>) {
        for (id, player) in players where !kept.contains(id) {
            player.pause()
            if let observer = timeObservers[id] { player.removeTimeObserver(observer) }
            observers[id]?.forEach(NotificationCenter.default.removeObserver)
        }
        players = players.filter { kept.contains($0.key) }
        settings = settings.filter { kept.contains($0.key) }
        durations = durations.filter { kept.contains($0.key) }
        fadeLevels = fadeLevels.filter { kept.contains($0.key) }
        timeObservers = timeObservers.filter { kept.contains($0.key) }
        observers = observers.filter { kept.contains($0.key) }
        playing = playing.intersection(kept)
        started = started.intersection(kept)
        slideID = nil
    }

    // MARK: - Files

    /// Media in the package is played from a copy in the caches folder, as
    /// AVFoundation plays files rather than data.
    private static func url(for media: SlideShape.Media, in presentation: Presentation) -> URL? {
        if let path = media.path, let data = presentation.data(at: path) {
            let directory = FileManager.default.temporaryDirectory.appending(path: "Media", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Named for its contents, so the same media is written once.
            let name = "\(data.count)-\(ZipArchive.crc32(data)).\((path as NSString).pathExtension)"
            let url = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
            return url
        }
        return media.url.flatMap(URL.init(string:))
    }
}
