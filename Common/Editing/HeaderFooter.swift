import DazzleEngine
import Foundation

/// What PowerPoint's Header & Footer puts on slides: the date, the slide
/// number and a footer, each in the placeholder the layout keeps for it.
struct HeaderFooterSettings: Equatable {
    var showsDate = false
    /// Today's date, filled in each time the slide is shown, rather than
    /// fixed text.
    var updatesDate = true
    var dateFormat = DateField.datetime1
    var fixedDate = ""
    var showsSlideNumber = false
    var showsFooter = false
    var footer = ""
    var hidesOnTitleSlide = false

    init() {
        // Nothing shown.
    }

    /// The settings a slide shows now.
    init(slide: Slide) {
        func shape(_ type: String) -> SlideShape? { slide.shapes.first { $0.placeholder?.type == type } }
        if let date = shape("dt") {
            showsDate = true
            let run = date.text?.paragraphs.flatMap(\.runs).first
            if case .field(let type)? = run?.kind, let format = DateField(rawValue: type) {
                dateFormat = format
            } else {
                updatesDate = false
                fixedDate = date.text?.plainText ?? ""
            }
        }
        showsSlideNumber = shape("sldNum") != nil
        if let footerShape = shape("ftr") {
            showsFooter = true
            footer = footerShape.text?.plainText ?? ""
        }
        hidesOnTitleSlide = false
    }
}

extension EditorState {
    func headerFooter(in presentation: Presentation) -> HeaderFooterSettings {
        selectedSlide(in: presentation).map { HeaderFooterSettings(slide: $0) } ?? HeaderFooterSettings()
    }

    /// Puts the date, slide number and footer on the slide being edited, or
    /// on every slide, taking them off where they are turned off.
    func applyHeaderFooter(_ settings: HeaderFooterSettings, toAll: Bool, in presentation: inout Presentation) {
        let indices = toAll ? Array(presentation.slides.indices) : [selectedIndex(in: presentation)]
        for index in indices where presentation.slides.indices.contains(index) && presentation.slides[index].canEditShapes {
            let layout = presentation.layout(for: presentation.slides[index])
            let master = presentation.resources.master(for: layout)
            let isTitleSlide = layout?.shapes.contains { $0.placeholder?.type == "ctrTitle" } ?? false
            let hidden = settings.hidesOnTitleSlide && isTitleSlide
            var slide = presentation.slides[index]

            /// Puts `run` in the slide's placeholder of `type`, making it from
            /// the layout's or master's if need be; or with none, removes it.
            func set(_ type: String, run: TextRun?) {
                let existing = slide.shapes.firstIndex { $0.placeholder?.type == type }
                guard var run else {
                    if let existing {
                        slide.shapes.remove(at: existing)
                        slide.hasRemovedShapes = true
                        slide.isModified = true
                    }
                    return
                }
                if case .field = run.kind { run.fieldID = "{\(UUID().uuidString)}" }
                if let existing {
                    var body = slide.shapes[existing].text ?? TextBody(paragraphs: [])
                    let paragraph = body.paragraphs.first ?? Paragraph(runs: [])
                    var replaced = paragraph
                    run.properties = paragraph.runs.first?.properties ?? paragraph.endProperties ?? RunProperties()
                    run.sourceProperties = paragraph.runs.first?.sourceProperties
                    replaced.runs = [run]
                    body.paragraphs = [replaced]
                    guard body != slide.shapes[existing].text else { return }
                    slide.shapes[existing].text = body
                    slide.shapes[existing].edits.insert(.text)
                    slide.isModified = true
                    return
                }
                guard let template = layout?.shapes.first(where: { $0.placeholder?.type == type })
                    ?? master?.shapes.first(where: { $0.placeholder?.type == type }) else { return }
                var shape = SlideShape(
                    shapeID: slide.nextShapeID, name: template.name, kind: .shape, frame: template.frame, hasOwnFrame: false
                )
                shape.placeholder = template.placeholder
                shape.text = TextBody(paragraphs: [Paragraph(runs: [run])])
                slide.shapes.append(shape)
                slide.isModified = true
            }

            let date = settings.updatesDate
                ? TextRun(kind: .field(type: settings.dateFormat.rawValue), text: settings.dateFormat.string(for: Date()))
                : TextRun(text: settings.fixedDate)
            let number = TextRun(kind: .field(type: "slidenum"), text: "‹#›")
            set("dt", run: settings.showsDate && !hidden && !(date.text.isEmpty && !settings.updatesDate) ? date : nil)
            set("sldNum", run: settings.showsSlideNumber && !hidden ? number : nil)
            set("ftr", run: settings.showsFooter && !hidden && !settings.footer.isEmpty ? TextRun(text: settings.footer) : nil)
            presentation.slides[index] = slide
        }
    }
}
