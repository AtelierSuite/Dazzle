import AVFoundation
import DazzleEngine
import SwiftUI
import UIKit

/// A player's picture, filling its frame as the shape's does.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast
    }
}

/// The current slide's videos, laid over the slide where their pictures are.
/// `showsControls` adds a play button over each paused one, for the screen
/// the presenter touches.
struct MediaOverlay: View {
    let slide: Slide
    let slideSize: CGSize
    let playback: MediaPlayback
    var showsControls = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(slideSize.width, 1), proxy.size.height / max(slideSize.height, 1))
            let origin = CGPoint(
                x: (proxy.size.width - slideSize.width * scale) / 2, y: (proxy.size.height - slideSize.height * scale) / 2
            )
            ForEach(MediaPlayback.media(on: slide), id: \.shape.id) { shape, media in
                let frame = shape.frame.points
                let rect = CGRect(
                    x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale,
                    width: frame.width * scale, height: frame.height * scale
                )
                ZStack {
                    if media.kind == .video, let player = playback.players[shape.id] {
                        PlayerLayerView(player: player)
                            .opacity(playback.started.contains(shape.id) ? 1 : 0)
                    }
                    if showsControls, !playback.isPlaying(shape.id) {
                        Image(systemName: media.kind == .video ? "play.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.system(size: min(max(min(rect.width, rect.height) * 0.3, 24), 64)))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            }
        }
    }
}
