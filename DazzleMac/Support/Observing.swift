import Foundation
import Observation

/// Runs `update` now, and again whenever anything it read from an
/// observable object changes, until cancelled or let go.
///
/// AppKit views don't track observable objects on their own, so each
/// controller keeps one of these per piece of the screen it keeps current.
/// Changes made together are taken up together, on the next turn of the
/// main run loop.
@MainActor
final class Observing {
    private let update: @MainActor () -> Void
    private var isCancelled = false

    init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
        track()
    }

    func cancel() {
        isCancelled = true
    }

    private func track() {
        guard !isCancelled else { return }
        withObservationTracking(update) { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}
