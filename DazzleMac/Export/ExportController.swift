import AppKit
import DazzleEngine
import UniformTypeIdentifiers

/// Exporting slides as a PDF, as pictures or as a movie, and saving a
/// copy as PowerPoint. Each asks where with a save panel whose options
/// sit beneath it.
@MainActor
struct ExportController {
    let deck: Deck
    let name: String
    let window: NSWindow?

    /// The choices made last time, offered again.
    private static var options = ExportOptions()

    private var presentation: Presentation { deck.presentation }

    func export(_ format: ExportOptions.Format) {
        var options = Self.options
        options.format = format
        let accessory = ExportAccessory(options: options)
        switch format {
        case .pdf:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = ExportFile.sanitized(name) + ".pdf"
            run(panel, accessory: accessory) { url, options in
                let slides = slides(for: options)
                let presentation = presentation
                let title = name
                Task {
                    let data = await Task.detached {
                        SlideExporter.pdf(of: slides, in: presentation, title: title, layout: options.pageLayout)
                    }.value
                    write(data, to: url)
                }
            }
        case .images:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export.Share")
            panel.message = String(localized: "Mac.Export.Images.Message")
            run(panel, accessory: accessory) { folder, options in
                exportImages(to: folder, options: options)
            }
        case .video:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = ExportFile.sanitized(name) + ".mp4"
            run(panel, accessory: accessory) { url, options in
                exportMovie(to: url, options: options)
            }
        }
    }

    func exportPowerPoint() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.openXMLPresentation]
        panel.nameFieldStringValue = ExportFile.sanitized(name) + ".pptx"
        let presentation = presentation
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                write(try PPTXWriter.data(from: presentation), to: url)
            } catch {
                deck.state.errorMessage = error.localizedDescription
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: - Running

    private func run(_ panel: NSSavePanel, accessory: ExportAccessory, export: @escaping (URL, ExportOptions) -> Void) {
        panel.accessoryView = accessory.view
        if let openPanel = panel as? NSOpenPanel { openPanel.isAccessoryViewDisclosed = true }
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let options = accessory.options
            Self.options = options
            export(url, options)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private func slides(for options: ExportOptions) -> [Slide] {
        switch options.scope {
        case .current:
            return deck.selectedSlide.map { [$0] } ?? []
        case .all, .chosen:
            return presentation.slides.filter { options.includesHiddenSlides || !$0.isHidden }
        }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            deck.state.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pictures

    /// One picture per slide, numbered after the presentation.
    private func exportImages(to folder: URL, options: ExportOptions) {
        let slides = slides(for: options)
        let presentation = presentation
        let base = ExportFile.sanitized(name)
        Task {
            let failed = await Task.detached { () -> Bool in
                var failed = false
                for slide in slides {
                    let number = (presentation.index(of: slide.id) ?? 0) + 1
                    let file = folder.appending(path: String(format: "%@ %03d.%@", base, number, options.imageFormat.fileExtension))
                    guard let data = SlideExporter.image(of: slide, in: presentation, width: options.resolution.rawValue,
                                                         format: options.imageFormat) else {
                        failed = true
                        continue
                    }
                    do { try data.write(to: file, options: .atomic) } catch { failed = true }
                }
                return failed
            }.value
            if failed { deck.state.errorMessage = String(localized: "Mac.Export.Images.Failed") }
        }
    }

    // MARK: - Movie

    /// Renders the movie in the background behind a sheet showing how far
    /// it has got, which can stop it.
    private func exportMovie(to url: URL, options: ExportOptions) {
        let slides = slides(for: options)
        let presentation = presentation
        // Slides that move on by themselves keep their own time.
        let durations = slides.map { $0.autoAdvanceAfter ?? options.secondsPerSlide }
        let width = options.resolution.rawValue
        let progress = MovieProgressSheet()
        let task = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await VideoExporter.export(slides, of: presentation, width: width, durations: durations, to: url) { fraction in
                        Task { @MainActor in progress.fraction = fraction }
                    }
                }.value
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                deck.state.errorMessage = error.localizedDescription
            }
            progress.dismiss()
        }
        progress.onCancel = { task.cancel() }
        progress.present(over: window)
    }
}

/// The options under an export's save panel.
@MainActor
private final class ExportAccessory: NSObject {
    private(set) var options: ExportOptions
    let view: NSView

    private let scope = NSPopUpButton()
    private let includeHidden = NSButton(checkboxWithTitle: String(localized: "Export.IncludeHidden"), target: nil, action: nil)
    private let layout = NSPopUpButton()
    private let imageFormat = NSPopUpButton()
    private let resolution = NSPopUpButton()
    private let seconds = NSStepper()
    private let secondsLabel = NSTextField(labelWithString: "")

    private static let layouts: [(String.LocalizationValue, SlideExporter.PageLayout)] = [
        ("Export.Layout.Slides", .slides), ("Export.Layout.Notes", .notes),
        ("Mac.Export.Layout.Handouts2", .handouts(perPage: 2)), ("Mac.Export.Layout.Handouts3", .handouts(perPage: 3)),
        ("Mac.Export.Layout.Handouts4", .handouts(perPage: 4)), ("Mac.Export.Layout.Handouts6", .handouts(perPage: 6)),
    ]

    init(options: ExportOptions) {
        self.options = options
        var rows: [[NSView]] = []
        func label(_ key: String.LocalizationValue) -> NSTextField {
            let field = NSTextField(labelWithString: String(localized: key))
            field.alignment = .right
            return field
        }
        scope.addItems(withTitles: [String(localized: "Export.Scope.All"), String(localized: "Export.Scope.Current")])
        scope.selectItem(at: options.scope == .current ? 1 : 0)
        rows.append([label("Export.Scope"), scope])
        includeHidden.state = options.includesHiddenSlides ? .on : .off
        rows.append([NSView(), includeHidden])
        switch options.format {
        case .pdf:
            layout.addItems(withTitles: Self.layouts.map { String(localized: $0.0) })
            layout.selectItem(at: Self.layouts.firstIndex { $0.1 == options.pageLayout } ?? 0)
            rows.append([label("Export.Layout"), layout])
        case .images:
            imageFormat.addItems(withTitles: ["PNG", "JPEG"])
            imageFormat.selectItem(at: options.imageFormat == .jpeg ? 1 : 0)
            rows.append([label("Export.ImageFormat"), imageFormat])
            fallthrough
        case .video:
            resolution.addItems(withTitles: ExportOptions.Resolution.allCases.map { Self.title(of: $0) })
            resolution.selectItem(at: ExportOptions.Resolution.allCases.firstIndex(of: options.resolution) ?? 1)
            rows.append([label("Export.Resolution"), resolution])
        }
        if options.format == .video {
            seconds.minValue = 1
            seconds.maxValue = 60
            seconds.increment = 1
            seconds.doubleValue = options.secondsPerSlide
            let stack = NSStackView(views: [secondsLabel, seconds])
            rows.append([label("Export.SecondsPerSlide"), stack])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        view = container
        super.init()
        for control in [scope, layout, imageFormat, resolution, seconds, includeHidden] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        updateSecondsLabel()
    }

    private static func title(of resolution: ExportOptions.Resolution) -> String {
        switch resolution {
        case .standard: "1280 × 720"
        case .high: "1920 × 1080"
        case .ultra: "3840 × 2160"
        }
    }

    @objc private func changed(_ sender: Any?) {
        options.scope = scope.indexOfSelectedItem == 1 ? .current : .all
        options.includesHiddenSlides = includeHidden.state == .on
        if Self.layouts.indices.contains(layout.indexOfSelectedItem) {
            options.pageLayout = Self.layouts[layout.indexOfSelectedItem].1
        }
        options.imageFormat = imageFormat.indexOfSelectedItem == 1 ? .jpeg : .png
        let resolutions = ExportOptions.Resolution.allCases
        if resolutions.indices.contains(resolution.indexOfSelectedItem) {
            options.resolution = resolutions[resolution.indexOfSelectedItem]
        }
        options.secondsPerSlide = seconds.doubleValue
        includeHidden.isEnabled = options.scope == .all
        updateSecondsLabel()
    }

    private func updateSecondsLabel() {
        secondsLabel.stringValue = String(format: String(localized: "Export.Seconds"), Int(options.secondsPerSlide))
    }
}

/// A sheet showing how far a movie has got, with a button to stop it.
@MainActor
private final class MovieProgressSheet: NSObject {
    var onCancel: () -> Void = { /* Set once the movie starts. */ }
    var fraction: Double = 0 {
        didSet { indicator.doubleValue = fraction }
    }

    private let indicator = NSProgressIndicator()
    private var sheet: NSWindow?
    private weak var parent: NSWindow?

    func present(over window: NSWindow?) {
        guard let window else { return }
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.style = .bar
        let title = NSTextField(labelWithString: String(localized: "Mac.Export.Movie.Progress"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let cancel = NSButton(title: String(localized: "Common.Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [title, indicator, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        indicator.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.titled], backing: .buffered,
                             defer: true)
        sheet.contentView = stack
        self.sheet = sheet
        parent = window
        window.beginSheet(sheet)
    }

    func dismiss() {
        guard let sheet else { return }
        parent?.endSheet(sheet)
        self.sheet = nil
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
        dismiss()
    }
}
