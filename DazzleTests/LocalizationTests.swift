import Foundation
import Testing

@Suite("Localization catalogue")
struct LocalizationTests {
    /// Every key in `Common/Localizable.xcstrings` must carry a non-empty
    /// translation for each supported language.
    private static let languages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    private static var catalogue: [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DazzleTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Common/Localizable.xcstrings")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static var strings: [String: [String: Any]] {
        catalogue["strings"] as! [String: [String: Any]]
    }

    @Test("The empty key is gone")
    func noEmptyKey() {
        #expect(!Self.strings.keys.contains(""))
    }

    @Test("Every key has an entry for each supported language")
    func allKeysHaveAllLanguages() {
        var missing: [String] = []
        for (key, entry) in Self.strings {
            let localizations = (entry["localizations"] as? [String: Any]) ?? [:]
            for language in Self.languages {
                if localizations[language] == nil {
                    missing.append("\(key)/\(language)")
                }
            }
        }
        #expect(missing.isEmpty, "keys missing a language entry: \(missing.prefix(20).joined(separator: ", "))")
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
