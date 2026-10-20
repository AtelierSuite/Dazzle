import DazzleEngine
import Foundation

extension Hyperlink {
    /// An address typed without a scheme is taken to be on the web.
    static func normalizedAddress(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://"), !trimmed.hasPrefix("mailto:") else { return trimmed }
        return trimmed.contains("@") && !trimmed.contains("/") ? "mailto:" + trimmed : "https://" + trimmed
    }
}
