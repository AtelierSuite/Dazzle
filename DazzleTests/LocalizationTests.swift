import Foundation
import Testing

private let catalogueURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Common/Localizable.xcstrings")

// The catalogue is read from the source tree, which isn't there on a device or a test-without-building runner.
@Suite("Localization catalogue", .enabled(if: FileManager.default.isReadableFile(atPath: catalogueURL.path)))
struct LocalizationTests {
    private static let languages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    nonisolated(unsafe) private static let strings: [String: [String: Any]] = {
        guard let data = try? Data(contentsOf: catalogueURL),
              let catalogue = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return catalogue["strings"] as? [String: [String: Any]] ?? [:]
    }()

    @Test("The catalogue parses")
    func catalogueParses() {
        #expect(!Self.strings.isEmpty)
    }

    private static func isTranslated(_ localization: Any?) -> Bool {
        guard let localization = localization as? [String: Any] else { return false }
        if let unit = localization["stringUnit"] as? [String: Any] {
            return unit["state"] as? String == "translated" && !((unit["value"] as? String) ?? "").isEmpty
        }
        return localization["variations"] != nil
    }

    @Test("Every key has a translation for each supported language")
    func allKeysHaveAllLanguages() {
        var missing: [String] = []
        for (key, entry) in Self.strings where !key.isEmpty {
            let localizations = (entry["localizations"] as? [String: Any]) ?? [:]
            for language in Self.languages where !Self.isTranslated(localizations[language]) {
                missing.append("\(key)/\(language)")
            }
        }
        #expect(missing.isEmpty, "keys missing a translation: \(missing.prefix(20).joined(separator: ", "))")
    }

    @Test("The sixteen animation effect names are translated into Korean and Chinese")
    func animationEffectsTranslated() {
        let effects = [
            "Blinds", "Box", "Checkerboard", "Circle", "Diamond", "Dissolve", "Plus", "Split",
            "RandomBars", "Strips", "Wedge", "Wheel", "FillColor", "LineColor", "FontColor", "Transparency",
        ]
        for effect in effects {
            let key = "Animation.Effect.\(effect)"
            let localizations = (Self.strings[key]?["localizations"] as? [String: Any]) ?? [:]
            for language in ["ko", "zh-Hans", "zh-Hant"] {
                let value = ((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(value != nil && !value!.isEmpty, "\(key) is missing \(language)")
            }
        }
    }
}
