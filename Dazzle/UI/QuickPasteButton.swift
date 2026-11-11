import SwiftUI
import UIKit

/// Keeps track of what would paste, so the editor can offer a quick Paste
/// button only while there is something to paste.
///
/// Checked when the pasteboard changes in Dazzle, when Dazzle copies, and when
/// the app becomes active. While active it also watches the pasteboard's change
/// count, which catches another app copying beside it in Split View or Slide
/// Over. None of this reads the pasteboard's contents, so none of it asks for
/// permission to paste.
@MainActor
@Observable
final class PasteboardMonitor {
    static let shared = PasteboardMonitor()

    private(set) var kind: PasteKind?

    @ObservationIgnored private var changeCount = -1
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let onChange: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { PasteboardMonitor.shared.refresh() }
        }
        observers = [
            center.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main, using: onChange),
            center.addObserver(forName: UIPasteboard.removedNotification, object: nil, queue: .main, using: onChange),
            center.addObserver(forName: DeckClipboard.didCopy, object: nil, queue: .main, using: onChange),
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    PasteboardMonitor.shared.refresh()
                    PasteboardMonitor.shared.startWatching()
                }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PasteboardMonitor.shared.stopWatching() }
            },
        ]
        refresh()
        if UIApplication.shared.applicationState == .active { startWatching() }
    }

    func refresh() {
        changeCount = UIPasteboard.general.changeCount
        let kind = DeckClipboard.shared.pasteKind
        if kind != self.kind { self.kind = kind }
    }

    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let monitor = PasteboardMonitor.shared
                if UIPasteboard.general.changeCount != monitor.changeCount { monitor.refresh() }
            }
        }
        timer?.tolerance = 0.5
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}

/// The editor's top-left Paste button, whose icon and label say what will paste.
struct QuickPasteButton: View {
    let kind: PasteKind
    let paste: () -> Void

    var body: some View {
        Button(action: paste) {
            Label(kind.title, systemImage: kind.systemImage)
        }
        .accessibilityIdentifier("quickPaste")
    }
}

extension PasteKind {
    var title: LocalizedStringKey {
        switch self {
        case .shapes(let count): count == 1 ? "Edit.PasteShape" : "Edit.PasteShapes"
        case .slides(let count): count == 1 ? "Edit.PasteSlide" : "Edit.PasteSlides"
        case .image: "Edit.PasteImage"
        case .text: "Edit.PasteText"
        case .link: "Edit.PasteLink"
        }
    }

    var systemImage: String {
        switch self {
        case .shapes: "square.on.circle"
        case .slides: "rectangle.on.rectangle"
        case .image: "photo"
        case .text: "doc.on.clipboard"
        case .link: "link"
        }
    }
}
