import XCTest

/// Stages and captures Dazzle for Mac's App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which writes the presentation
/// these open, and says where it is through `SCREENSHOT_DECK`, where to write
/// through `SCREENSHOT_DIR` and which language to use through
/// `SCREENSHOT_LANGUAGE`. Without them the test skips, so it stays out of the
/// way of an ordinary test run. `SCREENSHOT_ONLY`, a comma-separated list of
/// names, retakes just those.
final class MacAppStoreScreenshots: XCTestCase {
    /// A shape on the slide, as a fraction of the slide's width and height.
    private struct Point {
        let x: CGFloat
        let y: CGFloat
    }

    private struct Shot {
        let name: String
        /// Counted from 1, as the slide navigator numbers them.
        let slide: Int
        var shape: Point?
        /// Opens the chart's data once the chart is selected.
        var opensChartData = false
    }

    // Where the sample deck's shapes sit; see samples.py.
    private static let card = Point(x: 0.57, y: 0.44)
    private static let chart = Point(x: 0.49, y: 0.63)

    private static let shots = [
        Shot(name: "01-deck", slide: 1),
        Shot(name: "02-format", slide: 2, shape: card),
        Shot(name: "03-chart", slide: 3, shape: chart, opensChartData: true),
    ]

    /// The inspector button that opens a chart's data.
    private static let chartDataButton = ["en": "Edit Chart", "ja": "グラフを編集"]

    /// The window, in points: 16:10, so a capture at 2x is the store's 2880 × 1800.
    private static let windowFrame = "80 80 1440 900"

    private var directory: URL!
    private var deck: String!
    private var language = "en"
    private var only: Set<String> = []
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty, let deck = environment["SCREENSHOT_DECK"] else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        self.deck = deck
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        only = Set((environment["SCREENSHOT_ONLY"] ?? "").split(separator: ",").map(String.init))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    func testScreens() throws {
        for shot in Self.shots where only.isEmpty || only.contains(shot.name) {
            launch()
            open(deck)
            select(slide: shot.slide)
            if let shape = shot.shape { click(shape) }
            if shot.opensChartData {
                let button = app.buttons[Self.chartDataButton[language] ?? "Edit Chart"].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), "missing the chart data button")
                button.click()
            }
            // Let the selection, the inspector and any sheet settle.
            Thread.sleep(forTimeInterval: 2)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try window.screenshot().pngRepresentation.write(to: file)
            app.terminate()
        }
    }

    // MARK: - Steps

    @MainActor
    private func launch() {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            // A fresh start every time: no windows brought back, a window of the store's shape, in light.
            "-ApplePersistenceIgnoreState", "YES",
            "-NSWindow Frame PresentationWindow", Self.windowFrame,
            "-NSRequiresAquaSystemAppearance", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
    }

    @MainActor
    private var canvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "slideCanvas").firstMatch
    }

    @MainActor
    private var window: XCUIElement {
        let name = ((deck as NSString).lastPathComponent as NSString).deletingPathExtension
        return app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
    }

    /// Opens a presentation through File ▸ Open, going straight to its path.
    @MainActor
    private func open(_ path: String) {
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 10) || app.sheets.firstMatch.exists,
                      "the open panel never came up")
        app.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.return, modifierFlags: [])
        // The untitled presentation the app starts with is replaced by the one opened.
        XCTAssertTrue(window.waitForExistence(timeout: 20), "\(path) never opened")
        Thread.sleep(forTimeInterval: 1.5)
    }

    @MainActor
    private func select(slide: Int) {
        let row = app.tables["slideNavigator"].tableRows.element(boundBy: slide - 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "slide \(slide) is not in the navigator")
        row.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Clicks a point on the slide. The canvas is the slide with a margin of
    /// 6% of its longer side all round; the sample deck is 16:9.
    @MainActor
    private func click(_ point: Point) {
        let slide = CGSize(width: 16, height: 9)
        let margin = max(slide.width, slide.height) * 0.06
        let offset = CGVector(
            dx: (margin + point.x * slide.width) / (slide.width + 2 * margin),
            dy: (margin + point.y * slide.height) / (slide.height + 2 * margin)
        )
        canvas.coordinate(withNormalizedOffset: offset).click()
        Thread.sleep(forTimeInterval: 0.5)
    }
}
