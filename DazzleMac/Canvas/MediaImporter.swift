import AppKit
import DazzleEngine
import UniformTypeIdentifiers

/// Pictures and videos brought in from files: chosen in an open panel,
/// dropped on the slide, or pasted.
@MainActor
enum MediaImporter {
    static let contentTypes: [UTType] = [.image, .movie]

    /// Asks for pictures or videos, and puts them on the slide being edited.
    static func choose(into deck: Deck, for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Mac.Insert.Choose.Message")
        let insert = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            Self.insert(panel.urls, into: deck)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: insert)
        } else {
            insert(panel.runModal())
        }
    }

    /// Asks for a picture to put in place of the selected one.
    static func chooseReplacement(into deck: Deck, for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        let replace = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            Task {
                guard let media = await prepare(url) else {
                    deck.state.errorMessage = String(localized: "Error.UnreadablePicture")
                    return
                }
                deck.edit { deck.state.replacePicture(with: media, in: &$0) }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: replace)
        } else {
            replace(panel.runModal())
        }
    }

    /// Puts each file on the slide: pictures where `point` is, in slide
    /// points, or in the middle without one; videos in the middle.
    static func insert(_ urls: [URL], into deck: Deck, at point: CGPoint? = nil) {
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
                Task {
                    do {
                        let video = try await PreparedVideo.prepare(from: url)
                        deck.edit { deck.state.insertVideo(video, in: &$0) }
                    } catch {
                        deck.state.errorMessage = String(localized: "Error.UnreadableVideo")
                    }
                }
            } else {
                Task {
                    guard let media = await prepare(url) else {
                        deck.state.errorMessage = String(localized: "Error.UnreadablePicture")
                        return
                    }
                    insert(media, into: deck, at: point)
                }
            }
        }
    }

    /// Puts a picture on the slide, centred on `point` if there is one.
    static func insert(_ media: PreparedMedia, into deck: Deck, at point: CGPoint?) {
        guard let point else {
            deck.edit { deck.state.insertPicture(media, in: &$0) }
            return
        }
        let bounds = deck.presentation.slideSize.points
        let scale = min(bounds.width * 0.6 / max(media.size.width, 1), bounds.height * 0.6 / max(media.size.height, 1), 1)
        let size = CGSize(width: media.size.width * scale, height: media.size.height * scale)
        let x = min(max(point.x - size.width / 2, 0), max(bounds.width - size.width, 0))
        let y = min(max(point.y - size.height / 2, 0), max(bounds.height - size.height, 0))
        deck.edit { deck.state.insertPicture(media, frame: CGRect(origin: CGPoint(x: x, y: y), size: size), in: &$0) }
    }

    /// Reads and re-encodes a picture away from the main thread.
    private static func prepare(_ url: URL) async -> PreparedMedia? {
        await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return PreparedMedia(data: data)
        }.value
    }
}
