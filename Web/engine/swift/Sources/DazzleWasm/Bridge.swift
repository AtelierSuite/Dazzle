import DazzleEngine
import Foundation

/// Turns JSON requests from the page into editor calls, and the session's
/// state back into JSON.
///
/// Every response carries the session's state: a `version` that counts
/// edits, whether the presentation is edited and can be undone or redone,
/// the slides with a revision each (so the page draws again only what
/// changed), and what is selected.
@MainActor
final class Bridge {
    static let shared = Bridge()

    private var session = WebSession(presentation: .blank, fileName: "Untitled.pptx", format: .pptx)

    /// What Copy last kept, for Paste, within this window.
    private enum Clipboard {
        case shapes([SlideShape], slide: Slide, presentation: Presentation)
        case slides([Slide], presentation: Presentation)
    }

    private var clipboard: Clipboard?

    struct Failure: Error {
        var message: String
    }

    func handle(_ data: Data, payload: Data?) -> (json: Data, payload: Data?) {
        var output: Data?
        var body: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = request["cmd"] as? String else { throw Failure(message: "Malformed request.") }
            let result = try perform(command, request, payload: payload, output: &output)
            body = ["ok": true, "state": state()]
            if let result { body["result"] = result }
        } catch let failure as Failure {
            body = ["ok": false, "error": failure.message, "state": state()]
        } catch {
            body = ["ok": false, "error": error.localizedDescription, "state": state()]
        }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"ok":false,"error":"Unencodable response."}"#.utf8)
        return (json, output)
    }

    private var presentation: Presentation { session.presentation }
    private var editor: EditorState { session.state }

    /// One change, made through the editor state as the Apple apps make it.
    private func edit(coalesce key: String? = nil, _ change: (EditorState, inout Presentation) -> Void) {
        session.edit(coalesce: key, change)
    }

    // MARK: - Commands

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ command: String, _ r: [String: Any], payload: Data?, output: inout Data?) throws -> Any? {
        switch command {
        // The session
        case "init":
            if let strings = r["strings"] as? [String: String] { PortableStrings.load(strings) }
            if let locale = r["locale"] as? String {
                PortableStrings.localeIdentifier = locale.replacingOccurrences(of: "-", with: "_")
            }
            return nil
        case "new":
            session = WebSession(presentation: .blank, fileName: r["name"] as? String ?? "Untitled.pptx", format: .pptx)
            return info()
        case "open":
            guard let payload else { throw Failure(message: "No file was given.") }
            session = try WebSession(data: payload, fileName: r["name"] as? String ?? "Untitled.pptx")
            return info()
        case "save":
            let format = (r["format"] as? String).flatMap(WebSession.Format.init(rawValue:)) ?? session.saveFormats[0]
            output = try session.data(as: format)
            let fileName = session.fileName(for: format)
            if r["keep"] as? Bool != true { session.markSaved(as: format) }
            return ["fileName": fileName, "format": format.rawValue, "mime": format.mimeType]
        case "rename":
            if let name = r["name"] as? String { session.fileName = name }
            return info()
        case "info":
            return info()
        case "undo":
            session.undo()
        case "redo":
            session.redo()
        case "scene":
            guard let slide = slide(r["slide"]) else { throw Failure(message: "No such slide.") }
            var renderer = WebRenderer(presentation: presentation, slide: slide)
            renderer.options.editing = r["editing"] as? Bool ?? false
            return renderer.scene()
        case "media":
            guard let path = r["path"] as? String, let data = presentation.data(at: path) else { throw Failure(message: "No such part.") }
            output = data
            return ["mime": Self.mimeType(of: data, path: path)]
        case "fonts":
            // The typefaces the presentation carries, as font files for the page to load.
            let files = presentation.resources.embeddedFonts.fontFiles()
            var bundle = Data()
            var entries: [[String: Any]] = []
            for file in files {
                entries.append(["family": file.family, "bold": file.face.isBold, "italic": file.face.isItalic,
                                "offset": bundle.count, "length": file.data.count])
                bundle.append(file.data)
            }
            output = bundle
            return entries
        case "inspect":
            return inspection()

        // Selecting
        case "select":
            let slideID = (r["slide"] as? String).flatMap(UUID.init(uuidString:))
            let shapeIDs = (r["shapes"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            session.select { state in
                if let slideID, slideID != state.selectedSlideID {
                    state.endEditingText()
                    state.selectSlide(slideID)
                }
                if r["shapes"] != nil {
                    if state.editingTextShapeID != nil, !shapeIDs.contains(state.editingTextShapeID!) { state.endEditingText() }
                    state.selectedShapeIDs = shapeIDs
                    state.isSelectingMultiple = shapeIDs.count > 1
                    if shapeIDs.count != 1 { state.selectCell(nil) }
                }
            }
        case "selectAll":
            session.select { $0.selectAllShapes(in: presentation) }
        case "beginText":
            guard let id = uuid(r["shape"]) else { throw Failure(message: "No shape.") }
            session.select { state in
                state.beginEditingText(id)
                state.selectCell(nil)
            }
        case "endText":
            session.select { $0.endEditingText() }
        case "textSelection":
            // Where formatting applies while typing, in the text's UTF-16 offsets.
            let location = r["loc"] as? Int ?? 0
            let length = r["len"] as? Int ?? 0
            editor.textSelection = NSRange(location: location, length: length)
            return look()
        case "selectCell":
            let position = (r["r"] as? Int).map { TableCellPosition(row: $0, column: r["c"] as? Int ?? 0) }
            session.select { $0.selectCell(position, editing: r["editing"] as? Bool ?? false) }
            if let location = r["loc"] as? Int { editor.textSelection = NSRange(location: location, length: r["len"] as? Int ?? 0) }

        // Slides
        case "addSlide":
            let layout = (r["layout"] as? String).flatMap { presentation.resources.layouts[$0] }
                ?? presentation.slides.first.flatMap(presentation.layout(for:)) ?? presentation.resources.orderedLayouts.first
            guard let layout else { throw Failure(message: "The presentation has no layouts.") }
            edit { state, presentation in state.addSlide(using: layout, in: &presentation) }
        case "duplicateSlides":
            for id in uuids(r["ids"]).reversed() { edit { state, presentation in state.duplicateSlide(id, in: &presentation) } }
        case "deleteSlides":
            let ids = uuids(r["ids"])
            edit { state, presentation in
                for id in ids where presentation.slides.count > 1 { state.deleteSlide(id, in: &presentation) }
            }
        case "moveSlides":
            let ids = uuids(r["ids"])
            let destination = r["to"] as? Int ?? 0
            edit { state, presentation in
                var target = destination
                for id in ids {
                    guard let from = presentation.index(of: id) else { continue }
                    state.moveSlide(id, to: target, in: &presentation)
                    if from >= target { target += 1 }
                }
            }
        case "toggleHidden":
            let ids = uuids(r["ids"])
            edit { state, presentation in for id in ids { state.toggleHidden(id, in: &presentation) } }
        case "setNotes":
            edit(coalesce: "notes:\(editor.selectedSlideID?.uuidString ?? "")") { state, presentation in
                state.setNotes(r["text"] as? String ?? "", in: &presentation)
            }
        case "setLayout":
            guard let path = r["layout"] as? String, presentation.resources.layouts[path] != nil else { throw Failure(message: "No such layout.") }
            edit { state, presentation in Self.changeLayout(to: path, state: state, in: &presentation) }
        case "setBackground":
            let fill = try fill(r["fill"])
            edit { state, presentation in state.setBackground(fill, in: &presentation) }
        case "setBackgroundPicture":
            guard let payload else { throw Failure(message: "No picture was given.") }
            let media = try prepared(payload, r)
            edit { state, presentation in state.setBackgroundPicture(media, tiled: r["tiled"] as? Bool ?? false, in: &presentation) }
        case "setSlideSize":
            guard let preset = (r["preset"] as? String).flatMap(SlideSizeConverter.Preset.init(rawValue:)) else { throw Failure(message: "No size.") }
            let scaling: SlideSizeConverter.Scaling = r["scaling"] as? String == "maximize" ? .maximize : .ensureFit
            edit { state, presentation in state.setSlideSize(preset, scaling: scaling, in: &presentation) }
            if let message = editor.errorMessage {
                editor.errorMessage = nil
                throw Failure(message: message)
            }
        case "advance":
            let toAll = r["toAll"] as? Bool ?? false
            edit { state, presentation in
                if r.keys.contains("after") { state.setAutoAdvance(r["after"] as? Double, toAll: toAll, in: &presentation) }
                if let onClick = r["onClick"] as? Bool { state.setAdvancesOnClick(onClick, toAll: toAll, in: &presentation) }
            }
        case "loop":
            edit { state, presentation in state.setLoopsSlideshow(r["on"] as? Bool ?? false, in: &presentation) }
        case "headerFooter":
            var settings = HeaderFooterSettings()
            settings.showsDate = r["date"] as? Bool ?? false
            settings.updatesDate = r["updates"] as? Bool ?? true
            settings.dateFormat = (r["dateFormat"] as? String).flatMap(DateField.init(rawValue:)) ?? .datetime1
            settings.fixedDate = r["fixedDate"] as? String ?? ""
            settings.showsSlideNumber = r["number"] as? Bool ?? false
            settings.showsFooter = r["footer"] as? Bool ?? false
            settings.footer = r["footerText"] as? String ?? ""
            settings.hidesOnTitleSlide = r["hideOnTitle"] as? Bool ?? false
            edit { state, presentation in state.applyHeaderFooter(settings, toAll: r["toAll"] as? Bool ?? false, in: &presentation) }

        // Inserting
        case "insertTextBox":
            edit { state, presentation in state.insertTextBox(in: &presentation) }
        case "insertShape":
            let preset = r["preset"] as? String ?? "rect"
            edit { state, presentation in state.insertShape(preset, in: &presentation) }
        case "insertPicture":
            guard let payload else { throw Failure(message: "No picture was given.") }
            let media = try prepared(payload, r)
            let frame = (r["frame"] as? [String: Any]).map(rect)
            edit { state, presentation in state.insertPicture(media, frame: frame, name: r["name"] as? String, in: &presentation) }
        case "insertVideo":
            guard let payload, let posterLength = r["posterLength"] as? Int, posterLength < payload.count else {
                throw Failure(message: "No video was given.")
            }
            // The poster's PNG first, then the movie.
            let poster = PreparedMedia(png: payload.prefix(posterLength), size: CGSize(width: r["w"] as? Double ?? 640, height: r["h"] as? Double ?? 360))
            let video = PreparedVideo(data: payload.dropFirst(posterLength), poster: poster, size: poster.size)
            edit { state, presentation in state.insertVideo(video, in: &presentation) }
            if let ext = r["ext"] as? String, ext != "mp4" { renameLastMedia(to: ext) }
        case "insertTable":
            let rows = min(max(r["rows"] as? Int ?? 3, 1), 50)
            let columns = min(max(r["columns"] as? Int ?? 3, 1), 30)
            edit { state, presentation in state.insertTable(rows: rows, columns: columns, in: &presentation) }
        case "insertChart":
            let kind = (r["kind"] as? String).flatMap(Chart.Kind.init(rawValue:)) ?? .column
            edit { state, presentation in state.insertChart(kind, in: &presentation) }

        // Shapes
        case "delete":
            edit { state, presentation in state.deleteSelectedShape(in: &presentation) }
        case "duplicate":
            edit { state, presentation in state.duplicateSelectedShape(in: &presentation) }
        case "arrange":
            let arrangement: EditorState.Arrangement = switch r["how"] as? String {
            case "front": .front
            case "forward": .forward
            case "backward": .backward
            default: .back
            }
            edit { state, presentation in state.arrangeSelectedShape(arrangement, in: &presentation) }
        case "align":
            let alignment: EditorState.Alignment = switch r["how"] as? String {
            case "center": .center
            case "right": .right
            case "top": .top
            case "middle": .middle
            case "bottom": .bottom
            default: .left
            }
            edit { state, presentation in state.alignSelectedShapes(alignment, in: &presentation) }
        case "distribute":
            edit { state, presentation in state.distributeSelectedShapes(horizontally: r["horizontally"] as? Bool ?? true, in: &presentation) }
        case "group":
            edit { state, presentation in state.groupSelectedShapes(in: &presentation) }
        case "ungroup":
            edit { state, presentation in state.ungroupSelectedShape(in: &presentation) }
        case "setFrames":
            // Moving, resizing and turning, as one change: { id: { x, y, w, h, rot? } }.
            let frames = r["frames"] as? [String: [String: Any]] ?? [:]
            edit { state, presentation in
                var plain: [SlideShape.ID: CGRect] = [:]
                for (key, value) in frames {
                    guard let id = UUID(uuidString: key) else { continue }
                    if let rotation = value["rot"] as? Double {
                        state.setTransform(frame: rect(value), rotation: rotation, of: id, in: &presentation)
                    } else {
                        plain[id] = rect(value)
                    }
                }
                if !plain.isEmpty { state.setFrames(plain, in: &presentation) }
            }
        case "rotate":
            edit { state, presentation in state.rotateSelectedShape(clockwise: r["clockwise"] as? Bool ?? true, in: &presentation) }
        case "flip":
            edit { state, presentation in state.flipSelectedShape(horizontally: r["horizontally"] as? Bool ?? true, in: &presentation) }
        case "setFill":
            let fill = try fill(r["fill"]) ?? Fill.none
            edit { state, presentation in state.setFill(fill, in: &presentation) }
        case "setFillPicture":
            guard let payload else { throw Failure(message: "No picture was given.") }
            let media = try prepared(payload, r)
            edit { state, presentation in state.setFillPicture(media, tiled: r["tiled"] as? Bool ?? false, in: &presentation) }
        case "setTiled":
            // The same picture, laid as a tile or stretched.
            let tiled = r["tiled"] as? Bool ?? false
            func retiled(_ fill: Fill?) -> Fill? {
                switch fill {
                case .tiledPicture(let path, let effects, let tile)?:
                    // Already tiled, it keeps how its tiles are laid.
                    tiled ? .tiledPicture(path: path, effects: effects, tile: tile) : .picture(path: path, effects: effects)
                case .picture(let path, let effects)?:
                    tiled ? .tiledPicture(path: path, effects: effects) : .picture(path: path, effects: effects)
                default: nil
                }
            }
            if r["background"] as? Bool == true {
                guard let slide = editor.selectedSlide(in: presentation), case .fill(let fill)? = slide.background,
                      let changed = retiled(fill) else { break }
                edit { state, presentation in state.setBackground(changed, in: &presentation) }
            } else {
                guard let changed = retiled(editor.selectedShape(in: presentation)?.fill) else { break }
                edit { state, presentation in state.setFill(changed, in: &presentation) }
            }
        case "setLine":
            let set = r["set"] as? [String: Any] ?? [:]
            edit { state, presentation in
                state.setLine({ line in
                    if set.keys.contains("color") {
                        line.fill = (set["color"] as? String).flatMap(Self.color).map(Fill.solid) ?? Fill.none
                    }
                    if let width = set["width"] as? Double { line.width = EMU.from(points: width) }
                    if let dash = set["dash"] as? String { line.dash = dash == "solid" ? nil : dash }
                    if let head = set["head"] as? String { line.head = head == "none" ? nil : head }
                    if let tail = set["tail"] as? String { line.tail = tail == "none" ? nil : tail }
                }, in: &presentation)
            }
        case "setShadow":
            let choice = FormatChoices.shadows.first { $0.id == r["id"] as? String }
            edit { state, presentation in state.setShadow(choice?.shadow, in: &presentation) }
        case "setReflection":
            let choice = FormatChoices.reflections.first { $0.id == r["id"] as? String }
            edit { state, presentation in state.setReflection(choice?.reflection, in: &presentation) }
        case "setLink":
            let link = hyperlink(r["link"])
            edit { state, presentation in
                if r["text"] as? Bool == true { state.setTextLink(link, in: &presentation) } else { state.setShapeLink(link, in: &presentation) }
            }
        case "setAltText":
            edit(coalesce: "alt:\(editor.selectedShapeID?.uuidString ?? "")") { state, presentation in
                state.setAltText(r["text"] as? String ?? "", in: &presentation)
            }
        case "setName":
            guard let name = r["name"] as? String, !name.isEmpty else { break }
            edit { state, presentation in state.updateShape(state.selectedShapeID, edits: [.identity], in: &presentation) { $0.name = name } }
        case "setCrop":
            guard let id = uuid(r["shape"]), let crop = r["crop"] as? [Double], crop.count == 4,
                  let frame = r["frame"] as? [String: Any] else { throw Failure(message: "No crop.") }
            edit { state, presentation in
                state.setCrop(frame: rect(frame), left: crop[0], top: crop[1], right: crop[2], bottom: crop[3], of: id, in: &presentation)
            }
        case "resetCrop":
            edit { state, presentation in state.resetCrop(in: &presentation) }
        case "replacePicture":
            guard let payload else { throw Failure(message: "No picture was given.") }
            let media = try prepared(payload, r)
            edit { state, presentation in state.replacePicture(with: media, in: &presentation) }

        // Text
        case "setText":
            // The text the page's editor holds, as paragraphs of runs naming the runs they came from.
            // How far it reaches across its lines: its height, or its width when it runs vertically.
            editor.measuredTextExtent = (r["height"] ?? r["width"]) as? Double
            let key = "text:\(editor.selectedShapeID?.uuidString ?? ""):\(editor.selectedCell.map { "\($0.row),\($0.column)" } ?? "")"
            let paragraphs = r["paras"] as? [[String: Any]] ?? []
            edit(coalesce: key) { state, presentation in
                if state.isEditingCell {
                    guard let table = state.selectedTable(in: presentation), let position = state.selectedCell,
                          let cell = table.cell(at: position) else { return }
                    let body = Self.body(from: paragraphs, replacing: cell.text ?? TextBody(paragraphs: [Paragraph(runs: [])]))
                    state.setCellText(body, in: &presentation)
                } else {
                    guard let shape = state.selectedShape(in: presentation) else { return }
                    let body = Self.body(from: paragraphs, replacing: shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])]))
                    state.setTextBody(body, in: &presentation)
                }
            }
            editor.measuredTextExtent = nil
        case "format":
            let set = r["set"] as? [String: Any] ?? [:]
            session.endCoalescing()
            edit { state, presentation in self.format(set, state: state, in: &presentation) }
            return look()
        case "look":
            return look()

        // Tables
        case "table":
            let change: EditorState.TableChange? = switch r["op"] as? String {
            case "rowAbove": .rowAbove
            case "rowBelow": .rowBelow
            case "columnLeft": .columnLeft
            case "columnRight": .columnRight
            case "deleteRow": .deleteRow
            case "deleteColumn": .deleteColumn
            default: nil
            }
            if let change { edit { state, presentation in state.changeTable(change, in: &presentation) } }
            if let header = r["header"] as? Bool { edit { state, presentation in state.setTableHeaderRow(header, in: &presentation) } }
            if let banded = r["banded"] as? Bool { edit { state, presentation in state.setTableBandedRows(banded, in: &presentation) } }
        case "setCellFill":
            let fill = try fill(r["fill"])
            edit { state, presentation in state.setCellFill(fill, in: &presentation) }

        // Charts
        case "chart":
            let set = r["set"] as? [String: Any] ?? [:]
            edit { state, presentation in
                if let kind = (set["kind"] as? String).flatMap(Chart.Kind.init(rawValue:)) {
                    state.setChartKind(kind, in: &presentation)
                }
                state.updateChart(in: &presentation) { chart in Self.change(&chart, set) }
            }

        // Animations
        case "addAnimation":
            guard let effect = effect(r["effect"]) else { throw Failure(message: "No effect.") }
            let category = ShapeAnimation.Category(presetClass: r["category"] as? String)
            var added: ShapeAnimation.ID?
            edit { state, presentation in added = state.addAnimation(effect, category: category, in: &presentation) }
            return added?.uuidString
        case "updateAnimation":
            guard let id = uuid(r["id"]) else { throw Failure(message: "No animation.") }
            let set = r["set"] as? [String: Any] ?? [:]
            edit { state, presentation in
                if let effect = effect(set["effect"]) { state.setEffect(effect, of: id, in: &presentation) }
                state.updateAnimation(id, in: &presentation) { animation in
                    if let trigger = set["trigger"] as? String {
                        animation.trigger = switch trigger {
                        case "withPrevious": .withPrevious
                        case "afterPrevious": .afterPrevious
                        default: .onClick
                        }
                    }
                    if let duration = set["duration"] as? Double { animation.duration = max(duration, 0) }
                    if let delay = set["delay"] as? Double { animation.delay = max(delay, 0) }
                    if let direction = (set["direction"] as? Int).flatMap(ShapeAnimation.Direction.init(rawValue:)) {
                        animation.effect = animation.effect.with(direction)
                    }
                }
            }
        case "deleteAnimations":
            let ids = Set(uuids(r["ids"]))
            edit { state, presentation in state.deleteAnimations(ids, in: &presentation) }
        case "moveAnimation":
            guard let id = uuid(r["id"]) else { break }
            let step = r["step"] as? Int ?? 1
            edit { state, presentation in
                guard let slide = state.selectedSlide(in: presentation), let index = slide.animations.firstIndex(where: { $0.id == id }) else { return }
                let destination = step > 0 ? index + 2 : index - 1
                guard destination >= 0, destination <= slide.animations.count else { return }
                state.moveAnimations(from: IndexSet(integer: index), to: destination, in: &presentation)
            }
        case "timeline":
            guard let slide = slide(r["slide"]) else { throw Failure(message: "No such slide.") }
            let timeline = slide.animationTimeline
            return [
                "steps": timeline.steps.count, "initial": timeline.initiallyBegun,
                "durations": timeline.steps.indices.map { timeline.duration(ofStep: $0) }.map { $0.isFinite ? $0 : -1 },
                "media": timeline.steps.map { step in
                    step.filter(\.animation.playsMedia).compactMap { entry in slide.shapes.first { $0.shapeID == entry.animation.shapeID }?.id.uuidString }
                },
                "through": timeline.playingThroughDuration.isFinite ? timeline.playingThroughDuration : -1,
                "after": slide.autoAdvanceAfter as Any, "onClick": slide.advancesOnClick, "notes": slide.notes,
                "loop": presentation.loopsSlideshow,
                "transition": slide.transition.map { $0.isAnimated ? $0.duration : 0 } ?? 0,
            ]
        case "transition":
            // The slide's transition as keyframes for each layer, for the
            // browser to animate: Reduce Motion asks for a cross-fade.
            guard let slide = slide(r["slide"]) else { throw Failure(message: "No such slide.") }
            guard let transition = slide.transition?.played(
                reduceMotion: r["reduceMotion"] as? Bool ?? false, seed: r["seed"] as? Int ?? 0
            ), transition.isAnimated else { return nil }
            var json = transitionJSON(transition, size: presentation.slideSize.points)
            // A Morph also needs the slide being left (`from`, with how many of
            // its animation steps had begun), to find the shapes the two share.
            if transition.effect == .morph, let outgoing = self.slide(r["from"]) {
                let size = presentation.slideSize.points
                let left = outgoing.animations.isEmpty ? nil : outgoing.animationTimeline.frame(
                    begun: r["fromBegun"] as? Int ?? 0, elapsed: 1e6, shapes: outgoing.shapes, slideSize: size
                )
                let timeline = slide.animationTimeline
                let arriving = slide.animations.isEmpty ? nil : timeline.frame(
                    begun: timeline.initiallyBegun, elapsed: 0, shapes: slide.shapes, slideSize: size
                )
                json["morph"] = morphJSON(
                    SlideMorph(from: outgoing, to: slide, outgoingFrame: left, incomingFrame: arriving), duration: transition.duration
                )
            }
            return json
        case "frame":
            // How the slide's animated shapes look `elapsed` seconds into step `begun`.
            guard let slide = slide(r["slide"]) else { throw Failure(message: "No such slide.") }
            let elapsed = r["elapsed"] as? Double ?? 0
            let timeline = slide.animationTimeline
            let frame = r["through"] as? Bool == true
                ? timeline.playingThrough(at: elapsed, shapes: slide.shapes, slideSize: presentation.slideSize.points)
                : timeline.frame(begun: r["begun"] as? Int ?? 0, elapsed: elapsed, shapes: slide.shapes, slideSize: presentation.slideSize.points)
            return frameJSON(frame, slide: slide)

        // Comments
        case "addComment":
            edit { state, presentation in
                state.addComment(r["text"] as? String ?? "", author: r["author"] as? String ?? "", in: &presentation)
            }
        case "replyComment":
            edit { state, presentation in
                state.reply(to: r["thread"] as? String ?? "", with: r["text"] as? String ?? "", author: r["author"] as? String ?? "", in: &presentation)
            }
        case "deleteComment":
            edit { state, presentation in state.deleteComment(r["thread"] as? String ?? "", replyID: r["reply"] as? String, in: &presentation) }
        case "resolveComment":
            edit { state, presentation in state.setCommentResolved(r["thread"] as? String ?? "", r["resolved"] as? Bool ?? true, in: &presentation) }

        // Find and replace
        case "find":
            let query = findQuery(r)
            guard !query.text.isEmpty else { return [] }
            return presentation.matches(for: query).map { match -> [String: Any] in
                var json: [String: Any] = [
                    "slide": match.slideID.uuidString, "loc": match.range.location, "len": match.range.length,
                    "excerpt": match.excerpt, "excerptLoc": match.excerptRange.location, "excerptLen": match.excerptRange.length,
                ]
                switch match.place {
                case .shape(let id): json["shape"] = id.uuidString
                case .cell(let id, let position):
                    json["shape"] = id.uuidString
                    json["cell"] = ["r": position.row, "c": position.column]
                case .notes: json["notes"] = true
                }
                return json
            }
        case "replace":
            let query = findQuery(r)
            let replacement = r["with"] as? String ?? ""
            var matches = presentation.matches(for: query)
            if let only = r["only"] as? [String: Any] {
                matches = matches.filter { match in
                    match.slideID.uuidString == only["slide"] as? String && match.range.location == only["loc"] as? Int
                }
            }
            guard !matches.isEmpty else { return 0 }
            edit { _, presentation in presentation.replace(matches, with: replacement) }
            return matches.count

        // Copy and paste, within this window
        case "copy":
            guard let slide = editor.selectedSlide(in: presentation) else { return nil }
            let shapes = editor.selectedShapes(in: presentation)
            if shapes.isEmpty || r["slides"] != nil {
                let ids = Set(uuids(r["slides"]).isEmpty ? [slide.id] : uuids(r["slides"]))
                clipboard = .slides(presentation.slides.filter { ids.contains($0.id) }, presentation: presentation)
                return ["kind": "slides", "text": presentation.slides.filter { ids.contains($0.id) }.compactMap(\.title).joined(separator: "\n")]
            }
            clipboard = .shapes(shapes, slide: slide, presentation: presentation)
            return ["kind": "shapes", "text": shapes.compactMap { $0.text?.plainText.nilIfEmpty }.joined(separator: "\n")]
        case "paste":
            switch clipboard {
            case .shapes(let shapes, let slide, let source)?:
                edit { state, presentation in state.pasteShapes(shapes, from: slide, of: source, into: &presentation) }
            case .slides(let slides, let source)?:
                edit { state, presentation in state.pasteSlides(slides, from: source, into: &presentation) }
            case nil:
                return false
            }
            return true
        case "pasteText":
            let text = r["text"] as? String ?? ""
            guard !text.isEmpty else { break }
            edit { state, presentation in
                state.insertTextBox(in: &presentation)
                state.setText(text, in: &presentation)
                state.endEditingText()
            }
        case "hasClipboard":
            return clipboard != nil

        default:
            throw Failure(message: "Unknown command \(command).")
        }
        return nil
    }

    // MARK: - Reading requests

    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    private func uuids(_ value: Any?) -> [UUID] { (value as? [String] ?? []).compactMap(UUID.init(uuidString:)) }

    private func slide(_ value: Any?) -> Slide? {
        guard let id = uuid(value) else { return editor.selectedSlide(in: presentation) }
        return presentation.slides.first { $0.id == id }
    }

    private func rect(_ json: [String: Any]) -> CGRect {
        CGRect(x: json["x"] as? Double ?? 0, y: json["y"] as? Double ?? 0, width: json["w"] as? Double ?? 0, height: json["h"] as? Double ?? 0)
    }

    /// A picture the page has checked is PNG or JPEG and measured, in pixels.
    private func prepared(_ data: Data, _ r: [String: Any]) throws -> PreparedMedia {
        let ext = (r["ext"] as? String)?.lowercased() ?? "png"
        guard ["png", "jpeg", "jpg", "gif"].contains(ext) else { throw Failure(message: String(localized: "Error.UnreadablePicture")) }
        return PreparedMedia(data: data, fileExtension: ext == "jpg" ? "jpeg" : ext, size: CGSize(width: r["w"] as? Double ?? 100, height: r["h"] as? Double ?? 100))
    }

    /// A movie that isn't MP4 keeps its own extension, so it plays where it is opened.
    private func renameLastMedia(to ext: String) {
        // The editor names new movies .mp4; a WebM or QuickTime movie keeps what it is.
        edit { _, presentation in
            guard let slideIndex = presentation.slides.firstIndex(where: { $0.id == self.editor.selectedSlideID }),
                  let shapeIndex = presentation.slides[slideIndex].shapes.lastIndex(where: { $0.id == self.editor.selectedShapeID }),
                  case .picture(var picture) = presentation.slides[slideIndex].shapes[shapeIndex].kind,
                  let old = picture.media?.path, let data = presentation.addedParts[old] else { return }
            let renamed = PackagePath.unused(prefix: "ppt/media/media", suffix: "." + ext, taken: presentation.partNames)
            presentation.addedParts[old] = nil
            presentation.addedParts[renamed] = data
            picture.media?.path = renamed
            presentation.slides[slideIndex].shapes[shapeIndex].kind = .picture(picture)
        }
    }

    static func color(_ hex: String) -> DrawingColor? {
        if hex.hasPrefix("scheme:") { return .scheme(String(hex.dropFirst(7))) }
        let digits = hex.replacingOccurrences(of: "#", with: "")
        guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else { return nil }
        var color = DrawingColor.rgb(value)
        if digits.count == 8, let alpha = UInt32(digits.suffix(2), radix: 16), alpha < 255 {
            color.transforms = [.init(name: "alpha", value: Int(Double(alpha) / 255 * 100_000))]
        }
        return color
    }

    /// A fill the inspector describes: `{ kind, color, start, end, angle, path, focus, tile, scaled }`,
    /// or for a pattern `{ kind, preset, color, background }`.
    private func fill(_ value: Any?) throws -> Fill? {
        guard let json = value as? [String: Any] else { return nil }
        switch json["kind"] as? String {
        case "none":
            return Fill.none
        case "solid":
            guard let color = (json["color"] as? String).flatMap(Self.color) else { throw Failure(message: "No colour.") }
            return .solid(color)
        case "gradient":
            let start = (json["start"] as? String).flatMap(Self.color) ?? .scheme("accent1")
            let end = (json["end"] as? String).flatMap(Self.color) ?? .scheme("bg1")
            // `path` is "circle", "rect" or "shape", or "linear"; `focus` and
            // `tile` are the fillToRect and tileRect insets, `[l, t, r, b]`.
            func insets(_ value: Any?) -> Fill.Gradient.Insets? {
                guard let values = value as? [Any], values.count == 4 else { return nil }
                let fractions = values.compactMap { ($0 as? NSNumber)?.doubleValue }
                guard fractions.count == 4 else { return nil }
                return .init(left: fractions[0], top: fractions[1], right: fractions[2], bottom: fractions[3])
            }
            let path = (json["path"] as? String).flatMap(Fill.Gradient.Path.init(rawValue:))
                ?? (json["path"] == nil && json["radial"] as? Bool == true ? .circle : nil)
            return .gradient(Fill.Gradient(
                stops: [.init(position: 0, color: start), .init(position: 1, color: end)],
                angle: json["angle"] as? Double ?? 90, path: path, isScaled: json["scaled"] as? Bool ?? false,
                fillToRect: insets(json["focus"]) ?? .center, tileRect: insets(json["tile"]) ?? .zero
            ))
        case "pattern":
            return .pattern(Fill.Pattern(
                preset: json["preset"] as? String ?? "pct50",
                foreground: (json["color"] as? String).flatMap(Self.color) ?? .rgb(0x000000),
                background: (json["background"] as? String).flatMap(Self.color) ?? .rgb(0xFFFFFF)
            ))
        default:
            return nil
        }
    }

    private func hyperlink(_ value: Any?) -> Hyperlink? {
        guard let json = value as? [String: Any] else { return nil }
        if let url = json["url"] as? String, !url.isEmpty { return .url(Hyperlink.normalizedAddress(url)) }
        if let slide = uuid(json["slide"]) { return .slide(slide) }
        switch json["action"] as? String {
        case "next": return .nextSlide
        case "previous": return .previousSlide
        case "first": return .firstSlide
        case "last": return .lastSlide
        case "end": return .endShow
        default: return nil
        }
    }

    private func effect(_ value: Any?) -> ShapeAnimation.Effect? {
        guard let json = value as? [String: Any], let name = json["name"] as? String else { return nil }
        let direction = (json["direction"] as? Int).flatMap(ShapeAnimation.Direction.init(rawValue:)) ?? .bottom
        return switch name {
        case "appear": .appear
        case "fade": .fade
        case "fly": .fly(direction)
        case "wipe": .wipe(direction)
        case "zoom": .zoom
        case "float": .float
        case "pulse": .pulse
        case "spin": .spin
        case "growShrink": .growShrink
        case "teeter": .teeter
        default: nil
        }
    }

    private func findQuery(_ r: [String: Any]) -> FindQuery {
        var query = FindQuery(text: r["text"] as? String ?? "")
        query.matchesCase = r["matchCase"] as? Bool ?? false
        query.matchesWholeWords = r["wholeWords"] as? Bool ?? false
        return query
    }

    // MARK: - Editing helpers

    /// Moves the selected slide onto another layout, keeping its own shapes:
    /// placeholders the new layout has stay placeholders and take its places.
    private static func changeLayout(to path: String, state: EditorState, in presentation: inout Presentation) {
        let index = state.selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index), let layout = presentation.resources.layouts[path] else { return }
        var slide = presentation.slides[index]
        guard slide.layoutPath != path, slide.canEditShapes else { return }
        let part = slide.partName ?? PartImporter.newSlidePart
        slide.layoutPath = path
        for relationship in slide.relationships.indices where slide.relationships[relationship].type == OOXML.RelationshipType.slideLayout {
            slide.relationships[relationship].target = PackagePath.relativeTarget(to: path, from: part)
        }
        for shape in slide.shapes.indices {
            guard let placeholder = slide.shapes[shape].placeholder else { continue }
            if let template = layout.shapes.inheritedPlaceholder(for: placeholder) {
                if !slide.shapes[shape].hasOwnFrame { slide.shapes[shape].frame = template.frame }
            } else {
                // Its place is gone; it keeps where it was as an ordinary shape.
                slide.shapes[shape].hasOwnFrame = true
                slide.shapes[shape].edits.formUnion([.transform])
            }
        }
        // Empty placeholders the new layout has and the slide doesn't come along, as a new slide's do.
        var nextID = slide.nextShapeID
        for template in layout.shapes {
            guard let placeholder = template.placeholder, !placeholder.isFurniture,
                  !slide.shapes.contains(where: { $0.placeholder.map { placeholder.matches($0, byIndex: false) } ?? false }) else { continue }
            var shape = SlideShape(shapeID: nextID, name: template.name, kind: .shape, frame: template.frame, hasOwnFrame: false)
            shape.placeholder = placeholder
            slide.shapes.append(shape)
            nextID += 1
        }
        slide.isModified = true
        presentation.slides[index] = slide
    }

    /// The text the page sent back, rebuilt from the body it replaces: each
    /// paragraph and run keeps the formatting of the one it came from, and
    /// new text takes the formatting of the text before it.
    static func body(from paragraphs: [[String: Any]], replacing old: TextBody) -> TextBody {
        var body = old
        var rebuilt: [Paragraph] = []
        for json in paragraphs {
            let sourceIndex = json["src"] as? Int
            let source = sourceIndex.flatMap { old.paragraphs.indices.contains($0) ? old.paragraphs[$0] : nil }
                ?? rebuilt.last.map { previous in
                    var paragraph = Paragraph(properties: previous.properties, runs: [])
                    paragraph.endProperties = previous.runs.last?.properties ?? previous.endProperties
                    return paragraph
                }
                ?? old.paragraphs.first
                ?? Paragraph(runs: [])
            var paragraph = source
            paragraph.runs = []
            var previous: RunProperties? = nil
            for runJSON in json["runs"] as? [[String: Any]] ?? [] {
                let text = runJSON["t"] as? String ?? ""
                let origin = runJSON["src"] as? [Int]
                let original: TextRun? = origin.flatMap { pair in
                    guard pair.count == 2, old.paragraphs.indices.contains(pair[0]), old.paragraphs[pair[0]].runs.indices.contains(pair[1]) else { return nil }
                    return old.paragraphs[pair[0]].runs[pair[1]]
                }
                if runJSON["br"] as? Bool == true {
                    var run = TextRun(text: "\u{2028}", properties: original?.properties ?? previous ?? source.endProperties ?? RunProperties())
                    run.kind = .lineBreak
                    paragraph.runs.append(run)
                    continue
                }
                if let original, case .field = original.kind, runJSON["field"] as? Bool == true {
                    // A field the page showed whole, unchanged.
                    paragraph.runs.append(original)
                    previous = original.properties
                    continue
                }
                guard !text.isEmpty else { continue }
                var run = original ?? TextRun(text: text, properties: previous ?? source.runs.last?.properties ?? source.endProperties ?? RunProperties())
                if run.kind != .text || run.text != text {
                    run.kind = .text
                    run.fieldID = nil
                    run.text = text
                }
                // Runs side by side with the same look are one run.
                if let last = paragraph.runs.last, last.kind == .text, run.kind == .text, last.properties == run.properties,
                   last.sourceProperties == run.sourceProperties, original == nil || last.text.isEmpty {
                    paragraph.runs[paragraph.runs.count - 1].text += text
                } else {
                    paragraph.runs.append(run)
                }
                previous = run.properties
            }
            if paragraph.runs.isEmpty, paragraph.endProperties == nil {
                paragraph.endProperties = source.runs.first?.properties ?? source.endProperties
            }
            rebuilt.append(paragraph)
        }
        body.paragraphs = rebuilt.isEmpty ? [Paragraph(runs: [])] : rebuilt
        return body
    }

    /// Character and paragraph formatting, on the selection while typing or the whole of the selected text.
    private func format(_ set: [String: Any], state: EditorState, in presentation: inout Presentation) {
        for (key, value) in set {
            switch key {
            case "bold":
                state.toggleBold(in: &presentation)
            case "italic":
                state.toggleItalic(in: &presentation)
            case "underline":
                state.toggleUnderline(in: &presentation)
            case "strike":
                state.toggleStrikethrough(in: &presentation)
            case "superscript":
                state.toggleBaseline(superscript: true, in: &presentation)
            case "subscript":
                state.toggleBaseline(superscript: false, in: &presentation)
            case "sizeStep":
                state.stepFontSize(by: value as? Int ?? 1, in: &presentation)
            case "size":
                guard let points = value as? Double, points > 0 else { continue }
                state.updateRuns(in: &presentation) { $0.size = Int((min(max(points, 1), 4_000) * 100).rounded()) }
            case "font":
                if let family = value as? String { state.setFontFamily(family, in: &presentation) }
            case "color":
                if let color = (value as? String).flatMap(Self.color) { state.setTextColor(color, in: &presentation) }
            case "align":
                if let alignment = (value as? String).flatMap(ParagraphAlignment.init(rawValue:)) { state.setAlignment(alignment, in: &presentation) }
            case "list":
                let choice: EditorState.ListStyleChoice = switch value as? String {
                case "bullets": .bullets
                case "numbers": .numbers
                default: .none
                }
                state.setListStyle(choice, in: &presentation)
            case "indent":
                state.changeIndent(by: value as? Int ?? 1, in: &presentation)
            case "lineSpacing":
                if let multiple = value as? Double { state.setLineSpacing(multiple, in: &presentation) }
            case "anchor":
                guard let anchor = (value as? String).flatMap(BodyProperties.Anchor.init(rawValue:)) else { continue }
                state.updateSelectedShapes(edits: [.text], in: &presentation) { shape in
                    guard shape.text != nil || shape.canHoldText else { return }
                    var body = shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
                    body.properties.anchor = anchor
                    shape.text = body
                }
            default:
                continue
            }
        }
    }

    private static func change(_ chart: inout Chart, _ set: [String: Any]) {
        if set.keys.contains("title") {
            let title = set["title"] as? String
            chart.title = title?.isEmpty == false ? title : nil
        }
        if let legend = set["legend"] as? String {
            chart.hasLegend = legend != "none"
            if legend != "none" { chart.legendPosition = legend }
        }
        if let gridlines = set["gridlines"] as? Bool { chart.showsGridlines = gridlines }
        if let labels = set["labels"] as? Bool { chart.showsValueLabels = labels }
        if let grouping = (set["grouping"] as? String).flatMap(Chart.Grouping.init(rawValue:)) {
            for plot in chart.plots.indices where chart.plots[plot].kind.hasAxes { chart.plots[plot].grouping = grouping }
        }
        if let categories = set["categories"] as? [String] { chart.categories = categories }
        if let series = set["series"] as? [[String: Any]] {
            var all = chart.allSeries
            for (index, json) in series.enumerated() {
                if index >= all.count { chart.addSeries(); all = chart.allSeries }
                chart.updateSeries(at: index) { entry in
                    if let name = json["name"] as? String { entry.name = name }
                    if let values = json["values"] as? [Any] {
                        entry.values = values.map { ($0 as? Double) ?? ($0 as? String).flatMap(ChartValues.parse) }
                    }
                }
            }
            while chart.allSeries.count > series.count, chart.allSeries.count > 1 { chart.removeSeries(at: chart.allSeries.count - 1) }
        }
        // Every series has a value for every category.
        for plot in chart.plots.indices {
            for series in chart.plots[plot].series.indices {
                let count = chart.categories.count
                var values = chart.plots[plot].series[series].values
                if values.count < count { values += Array(repeating: nil, count: count - values.count) }
                if values.count > count { values = Array(values.prefix(count)) }
                chart.plots[plot].series[series].values = values
                // A bubble added is as big as the series' others are on average.
                if chart.plots[plot].kind == .bubble {
                    let sizes = chart.plots[plot].series[series].sizes
                    let known = sizes.compactMap(\.self)
                    let average = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
                    chart.plots[plot].series[series].sizes = (0..<count).map { sizes.indices.contains($0) ? sizes[$0] ?? average : average }
                }
            }
        }
    }

    // MARK: - Responses

    private func state() -> [String: Any] {
        var selection: [String: Any] = [
            "slide": editor.selectedSlideID?.uuidString as Any,
            "shapes": editor.selectedShapeIDs.map(\.uuidString),
        ]
        if let editing = editor.editingTextShapeID { selection["editing"] = editing.uuidString }
        if let cell = editor.selectedCell { selection["cell"] = ["r": cell.row, "c": cell.column, "editing": editor.isEditingCell] }
        return [
            "version": session.contentVersion,
            "edited": session.isEdited,
            "canUndo": session.canUndo,
            "canRedo": session.canRedo,
            "slides": presentation.slides.map { slide -> [String: Any] in
                var json: [String: Any] = ["id": slide.id.uuidString, "rev": session.revisions[slide.id] ?? 0]
                if slide.isHidden { json["hidden"] = true }
                return json
            },
            "sel": selection,
        ]
    }

    private func info() -> [String: Any] {
        let size = presentation.slideSize.points
        var fonts = Set<String>()
        for theme in Set(presentation.resources.masters.values.map(\.theme.minorFont) + presentation.resources.masters.values.map(\.theme.majorFont)) {
            fonts.insert(theme)
        }
        func collect(_ shapes: [SlideShape]) {
            for shape in shapes {
                for paragraph in shape.text?.paragraphs ?? [] {
                    for run in paragraph.runs { if let font = run.properties.latinFont, !font.hasPrefix("+") { fonts.insert(font) } }
                }
                switch shape.kind {
                case .group(let group): collect(group.children)
                case .diagram(let members): collect(members)
                default: break
                }
            }
        }
        for slide in presentation.slides { collect(slide.shapes) }
        let report = presentation.unsupportedFeatures
        return [
            "fileName": session.fileName,
            "format": session.format.rawValue,
            "saveFormats": session.saveFormats.map { format -> [String: Any] in
                ["key": format.rawValue, "extension": format.rawValue, "mime": format.mimeType, "fileName": session.fileName(for: format)]
            },
            "size": ["w": Double(size.width), "h": Double(size.height)],
            "sizePreset": SlideSizeConverter.Preset.matching(presentation.slideSize)?.rawValue as Any,
            "layouts": presentation.resources.orderedLayouts.map { ["path": $0.path, "name": $0.name] },
            "loop": presentation.loopsSlideshow,
            "fonts": fonts.sorted(),
            "hasEmbeddedFonts": !presentation.resources.embeddedFonts.isEmpty,
            // The typefaces the slides ask for that the presentation doesn't carry,
            // for the page to say which this device draws in others.
            "typefaces": {
                let carried = Set(presentation.resources.embeddedFonts.typefaces.map { $0.lowercased() })
                return presentation.typefaces.filter { !carried.contains($0.lowercased()) }.sorted()
            }(),
            "unsupported": UnsupportedFeatureReport.Feature.allCases.filter(report.features.contains).map(\.message),
            "omissions": UnsupportedFeatureReport.Omission.allCases.filter(report.omissions.contains).map(\.message),
            "keynote": presentation.keynoteSource != nil,
            "outline": presentation.slides.enumerated().map { index, slide -> [String: Any] in
                [
                    "id": slide.id.uuidString, "title": slide.title ?? "", "notes": slide.notes, "number": index + 1,
                    "layout": slide.layoutPath, "comments": slide.comments.count,
                ]
            },
            "choices": choices(),
        ]
    }

    /// The menus' and inspector's choices, labelled as the Apple apps label them.
    private func choices() -> [String: Any] {
        func effects(_ category: ShapeAnimation.Category) -> [[String: Any]] {
            ShapeAnimation.Effect.choices(for: category).map { effect in
                ["name": Self.effectName(effect), "label": effect.label(in: category), "directional": effect.direction != nil]
            }
        }
        return [
            "shapes": ShapeChoice.all.map { ["preset": $0.preset, "label": $0.label] },
            "shadows": FormatChoices.shadows.map { ["id": $0.id, "label": $0.label] },
            "reflections": FormatChoices.reflections.map { ["id": $0.id, "label": $0.label] },
            "dashes": FormatChoices.dashes.map { ["id": $0.0, "label": $0.1] },
            "lineEnds": FormatChoices.lineEnds.map { ["id": $0.0, "label": $0.1] },
            "charts": Chart.Kind.insertable.map { ["kind": $0.rawValue, "label": $0.label] },
            "sizes": SlideSizeConverter.Preset.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "dateFormats": DateField.allCases.map { ["id": $0.rawValue, "label": $0.string(for: Date(), locale: Locale(identifier: PortableStrings.localeIdentifier))] },
            "animations": [
                ["category": "entr", "label": ShapeAnimation.Category.entrance.label, "effects": effects(.entrance)],
                ["category": "emph", "label": ShapeAnimation.Category.emphasis.label, "effects": effects(.emphasis)],
                ["category": "exit", "label": ShapeAnimation.Category.exit.label, "effects": effects(.exit)],
            ],
            "triggers": ShapeAnimation.Trigger.allCases.map { trigger -> [String: Any] in
                let id = switch trigger {
                case .onClick: "onClick"
                case .withPrevious: "withPrevious"
                case .afterPrevious: "afterPrevious"
                }
                return ["id": id, "label": trigger.label]
            },
            "directions": ShapeAnimation.Direction.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "groupings": Chart.Grouping.allCases.map { ["id": $0.rawValue, "label": Self.groupingLabel($0)] },
        ]
    }

    private static func groupingLabel(_ grouping: Chart.Grouping) -> String {
        switch grouping {
        case .standard: String(localized: "Chart.Grouping.Standard")
        case .stacked: String(localized: "Chart.Grouping.Stacked")
        case .percentStacked: String(localized: "Chart.Grouping.Percent")
        }
    }

    private static func effectName(_ effect: ShapeAnimation.Effect) -> String {
        switch effect {
        case .appear: "appear"
        case .fade: "fade"
        case .fly: "fly"
        case .wipe: "wipe"
        case .zoom: "zoom"
        case .float: "float"
        case .pulse: "pulse"
        case .spin: "spin"
        case .growShrink: "growShrink"
        case .teeter: "teeter"
        case .path: "path"
        case .filter: "filter"
        case .preset: "preset"
        }
    }

    /// The look where formatting applies, for the toolbar and inspector.
    private func look() -> [String: Any] {
        guard editor.selectedShape(in: presentation) != nil else { return [:] }
        let run = editor.effectiveRunProperties(in: presentation)
        let paragraph = editor.effectiveParagraphProperties(in: presentation)
        var json: [String: Any] = [
            "size": Double(run.size ?? 1_800) / 100,
            "bold": run.isBold ?? false, "italic": run.isItalic ?? false,
            "underline": run.isUnderlined ?? false, "strike": run.isStruckThrough ?? false,
            "baseline": run.baseline ?? 0,
            "align": (paragraph.alignment ?? .left).rawValue,
        ]
        json["list"] = switch editor.listStyle(in: presentation) {
        case .bullets: "bullets"
        case .numbers: "numbers"
        case .none: "none"
        }
        if let slide = editor.selectedSlide(in: presentation) {
            let style = SlideStyleContext(presentation: presentation, slide: slide)
            json["font"] = style.typeface(run.latinFont) ?? style.theme.minorFont
            json["color"] = css(run.color.map { style.color($0) } ?? style.color(.scheme("tx1")))
            if case .scheme(let name)? = run.color?.base, run.color?.transforms.isEmpty == true { json["scheme"] = name }
        }
        if case .percent(let value)? = paragraph.lineSpacing { json["lineSpacing"] = value }
        if let shape = editor.selectedShape(in: presentation), let slide = editor.selectedSlide(in: presentation) {
            let style = SlideStyleContext(presentation: presentation, slide: slide)
            json["anchor"] = (style.bodyProperties(for: shape, sources: style.sources(for: shape)).anchor ?? .top).rawValue
        }
        return json
    }

    /// Everything the inspector shows about the selection and the slide.
    private func inspection() -> [String: Any] {
        guard let slide = editor.selectedSlide(in: presentation) else { return [:] }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        var json: [String: Any] = [:]

        // The slide
        let background = style.background(of: slide)
        json["slide"] = [
            "id": slide.id.uuidString, "layout": slide.layoutPath, "hidden": slide.isHidden,
            "background": fillJSON(slide.background.flatMap { if case .fill(let fill) = $0 { fill } else { nil } }, resolved: background.fill, style: style, placeholder: background.placeholderColor),
            "advanceAfter": slide.autoAdvanceAfter as Any, "onClick": slide.advancesOnClick, "canEdit": slide.canEditShapes,
            "notes": slide.notes,
        ]
        let headerFooter = editor.headerFooter(in: presentation)
        json["headerFooter"] = [
            "date": headerFooter.showsDate, "updates": headerFooter.updatesDate, "dateFormat": headerFooter.dateFormat.rawValue,
            "fixedDate": headerFooter.fixedDate, "number": headerFooter.showsSlideNumber, "footer": headerFooter.showsFooter,
            "footerText": headerFooter.footer,
        ]
        // The theme's colours, offered first and written as theme references, as the Apple apps do.
        json["theme"] = [
            ("tx1", "Color.Theme.Text"), ("bg1", "Color.Theme.Background"), ("tx2", "Color.Theme.Text2"), ("bg2", "Color.Theme.Background2"),
            ("accent1", "Color.Theme.Accent1"), ("accent2", "Color.Theme.Accent2"), ("accent3", "Color.Theme.Accent3"),
            ("accent4", "Color.Theme.Accent4"), ("accent5", "Color.Theme.Accent5"), ("accent6", "Color.Theme.Accent6"),
        ].map { slot, key in ["slot": slot, "label": String(localized: String.LocalizationValue(key)), "color": css(style.color(.scheme(slot)))] }
        json["comments"] = slide.comments.map(commentJSON)
        json["animations"] = slide.animations.map { animation -> [String: Any] in
            let shape = slide.shapes.flatMap(\.flattened).first { $0.shapeID == animation.shapeID }
            let trigger = switch animation.trigger {
            case .onClick: "onClick"
            case .withPrevious: "withPrevious"
            case .afterPrevious: "afterPrevious"
            }
            return [
                "id": animation.id.uuidString, "shape": shape?.id.uuidString as Any, "target": animation.targetLabel(shape: shape),
                "category": animation.category.presetClass, "categoryLabel": animation.category.label,
                "effect": Self.effectName(animation.effect), "effectLabel": animation.effect.label(in: animation.category),
                "direction": animation.effect.direction?.rawValue as Any, "trigger": trigger,
                "duration": animation.duration, "delay": animation.delay, "editable": animation.effect.isMadeByDazzle,
                "tap": slide.animationTimeline.tapNumber(of: animation.id) as Any,
            ]
        }

        // The selected shapes
        let shapes = editor.selectedShapes(in: presentation)
        guard let shape = shapes.last else { return json }
        let sources = style.sources(for: shape)
        let frame = shape.frame.points
        var shapeJSON: [String: Any] = [
            "id": shape.id.uuidString, "name": shape.name, "count": shapes.count,
            "x": Double(frame.minX), "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height),
            "rot": shape.rotation, "canRotate": shape.canRotate, "editable": shape.isEditable,
            "altText": shape.altText ?? "", "canGroup": editor.canGroupSelection,
            "placeholder": shape.placeholder?.type as Any,
        ]
        shapeJSON["kind"] = switch shape.kind {
        case .shape: "shape"
        case .connector: "connector"
        case .picture(let picture): picture.media == nil ? "picture" : "media"
        case .group: "group"
        case .table: "table"
        case .chart(let chart): chart == nil ? "other" : "chart"
        case .diagram: "diagram"
        case .unsupported: "other"
        }
        if case .shape = shape.kind {
            let resolved = style.fill(for: shape, sources: sources)
            shapeJSON["fill"] = fillJSON(shape.fill, resolved: resolved?.fill, style: style, placeholder: resolved?.placeholderColor)
            shapeJSON["hasText"] = true
        }
        if [.shape, .connector].contains(shape.kind) || shape.isPicture {
            let resolved = style.line(for: shape, sources: sources)
            var line: [String: Any] = ["width": EMU.points(resolved?.line.width ?? 9_525)]
            if case .solid(let color)? = resolved?.line.fill {
                line["kind"] = "solid"
                line["color"] = css(style.color(color, placeholder: resolved?.placeholderColor))
            } else {
                line["kind"] = "none"
            }
            line["dash"] = resolved?.line.dash ?? "solid"
            line["head"] = resolved?.line.head ?? "none"
            line["tail"] = resolved?.line.tail ?? "none"
            shapeJSON["line"] = line
            shapeJSON["shadow"] = FormatChoices.shadows.first { $0.shadow == shape.shadow }?.id ?? (shape.shadow == nil ? "none" : "custom")
            shapeJSON["reflection"] = FormatChoices.reflections.first { $0.reflection == shape.reflection }?.id ?? (shape.reflection == nil ? "none" : "custom")
        }
        if let link = shape.link { shapeJSON["link"] = WebRenderer.link(link) as Any }
        if case .picture(let picture) = shape.kind {
            shapeJSON["crop"] = [picture.cropLeft, picture.cropTop, picture.cropRight, picture.cropBottom]
            let image = SlideShape.Picture.imageRect(frame: frame, picture: picture)
            shapeJSON["image"] = ["x": Double(image.minX), "y": Double(image.minY), "w": Double(image.width), "h": Double(image.height)]
            if let media = picture.media { shapeJSON["media"] = ["kind": media.kind == .video ? "video" : "audio", "path": media.path as Any] }
        }
        if case .table(let table) = shape.kind {
            var tableJSON: [String: Any] = [
                "rows": table.rows.count, "columns": table.columnCount, "header": table.hasHeaderRow, "banded": table.hasBandedRows,
            ]
            if let position = editor.selectedCell, let cell = table.cell(at: position) {
                tableJSON["cell"] = ["r": position.row, "c": position.column, "fill": fillJSON(cell.fill, resolved: cell.fill, style: style, placeholder: nil)]
            }
            shapeJSON["table"] = tableJSON
        }
        if case .chart(let chart?) = shape.kind {
            shapeJSON["chart"] = [
                "kind": chart.kind.rawValue, "title": chart.title ?? "", "legend": chart.hasLegend ? chart.legendPosition : "none",
                "gridlines": chart.showsGridlines, "labels": chart.showsValueLabels,
                "grouping": chart.plots.first?.grouping.rawValue ?? "standard", "hasAxes": chart.kind.hasAxes,
                "hasGrouping": chart.kind.hasGrouping, "kinds": chart.kind.choices.map { ["kind": $0.rawValue, "label": $0.label] },
                "categories": chart.categories,
                "series": chart.allSeries.map { ["name": $0.name, "values": $0.values.map { $0.map(ChartValues.format) ?? "" }] },
            ]
        }
        json["shape"] = shapeJSON
        json["text"] = look()
        return json
    }

    private func fillJSON(_ own: Fill?, resolved: Fill?, style: SlideStyleContext, placeholder: RGBAColor?) -> [String: Any] {
        var json: [String: Any] = ["own": own != nil]
        switch resolved ?? .none {
        case .none, .group:
            json["kind"] = "none"
        case .solid(let color):
            json["kind"] = "solid"
            json["color"] = css(style.color(color, placeholder: placeholder))
        case .gradient(let gradient):
            json["kind"] = "gradient"
            json["start"] = gradient.stops.first.map { css(style.color($0.color, placeholder: placeholder)) } ?? "#ffffff"
            json["end"] = gradient.stops.last.map { css(style.color($0.color, placeholder: placeholder)) } ?? "#000000"
            json["angle"] = gradient.angle
            json["path"] = gradient.path?.rawValue ?? "linear"
            json["focus"] = [gradient.fillToRect.left, gradient.fillToRect.top, gradient.fillToRect.right, gradient.fillToRect.bottom]
            json["tile"] = [gradient.tileRect.left, gradient.tileRect.top, gradient.tileRect.right, gradient.tileRect.bottom]
            json["scaled"] = gradient.isScaled
        case .pattern(let pattern):
            // Its foreground is its colour, carried over to a solid fill.
            json["kind"] = "pattern"
            json["preset"] = pattern.preset
            json["color"] = css(style.color(pattern.foreground, placeholder: placeholder))
            json["background"] = css(style.color(pattern.background, placeholder: placeholder))
        case .picture:
            json["kind"] = "picture"
        case .tiledPicture:
            json["kind"] = "picture"
            json["tiled"] = true
        }
        return json
    }

    private func commentJSON(_ comment: SlideComment) -> [String: Any] {
        [
            "id": comment.id, "author": comment.author, "initials": comment.initials, "text": comment.text,
            "date": comment.date.map { $0.timeIntervalSince1970 * 1000 } as Any, "resolved": comment.isResolved,
            "x": comment.position.map { Double($0.x) } as Any, "y": comment.position.map { Double($0.y) } as Any,
            "replies": comment.replies.map(commentJSON),
        ]
    }

    /// A transition as keyframes for each of its layers, back to front: a
    /// moment every thirtieth of a second, in slide points.
    private func transitionJSON(_ transition: SlideTransition, size: CGSize) -> [String: Any] {
        let count = min(max(Int((transition.duration * 30).rounded(.up)), 2), 120)
        let frames = (0...count).map { transition.frame(progress: Double($0) / Double(count), size: size) }
        func n(_ value: CGFloat) -> String {
            let rounded = (Double(value) * 1_000).rounded() / 1_000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        let layers = (frames.first?.layers.indices ?? 0..<0).map { index -> [String: Any] in
            [
                "content": frames[0].layers[index].content.rawValue,
                "keyframes": frames.enumerated().map { offset, frame -> [String: Any] in
                    let layer = frame.layers[index]
                    let t = layer.transform
                    return [
                        "offset": Double(offset) / Double(count),
                        "opacity": layer.opacity,
                        "transform": "matrix(\(n(t.a)), \(n(t.b)), \(n(t.c)), \(n(t.d)), \(n(t.tx)), \(n(t.ty)))",
                        "clipPath": layer.clip.map { $0.isEmpty ? "polygon(0 0, 0 0, 0 0)" : "path(evenodd, \"\($0.svgData)\")" } ?? "none",
                    ]
                },
            ]
        }
        return ["duration": transition.duration, "layers": layers]
    }

    /// A Morph's shared shapes, back to front: each pair's two shapes, and
    /// keyframes placing both (a transform of the slide, in slide points)
    /// with how far the first has dissolved into the second.
    private func morphJSON(_ morph: SlideMorph, duration: Double) -> [[String: Any]] {
        let count = min(max(Int((duration * 30).rounded(.up)), 2), 120)
        func n(_ value: CGFloat) -> String {
            let rounded = (Double(value) * 10_000).rounded() / 10_000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        func css(_ t: CGAffineTransform) -> String {
            "matrix(\(n(t.a)), \(n(t.b)), \(n(t.c)), \(n(t.d)), \(n(t.tx)), \(n(t.ty)))"
        }
        return morph.pairs.map { pair in
            [
                "from": pair.outgoing.id.uuidString,
                "to": pair.incoming.id.uuidString,
                "keyframes": (0...count).map { index -> [String: Any] in
                    let offset = Double(index) / Double(count)
                    let placement = morph.placement(of: pair, progress: offset)
                    return ["offset": offset, "from": css(placement.outgoing), "to": css(placement.incoming), "mix": placement.mix]
                },
            ]
        }
    }

    private func frameJSON(_ frame: AnimationFrame, slide: Slide) -> [String: Any] {
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let ids = Dictionary(slide.shapes.map { ($0.shapeID, $0) }) { first, _ in first }
        func appearance(_ appearance: AnimatedAppearance, shape: SlideShape?) -> [String: Any] {
            var json: [String: Any] = [:]
            if appearance.opacity != 1 { json["o"] = appearance.opacity }
            if appearance.offset != .zero { json["dx"] = Double(appearance.offset.width); json["dy"] = Double(appearance.offset.height) }
            if appearance.scale != 1 { json["s"] = appearance.scale }
            if appearance.axisScale != CGSize(width: 1, height: 1) {
                json["sx"] = Double(appearance.axisScale.width)
                json["sy"] = Double(appearance.axisScale.height)
            }
            if appearance.rotation != 0 { json["r"] = appearance.rotation }
            if let reveal = appearance.reveal {
                let edge = switch reveal.edge {
                case .top: "t"
                case .bottom: "b"
                case .left: "l"
                case .right: "r"
                }
                json["reveal"] = ["edge": edge, "f": reveal.fraction]
            }
            if let mask = appearance.mask, let shape {
                let frame = shape.frame.points
                json["mask"] = mask.filter.path(progress: mask.progress, frame: CGRect(origin: .zero, size: frame.size)).svgData
            }
            // Colour changes, worked out from what the shape is drawn in.
            for (target, changes) in appearance.colors where !changes.isEmpty {
                let base: RGBAColor
                switch target {
                case .fill:
                    let fill = shape.flatMap { style.fill(for: $0, sources: style.sources(for: $0)) }
                    if case .solid(let color)? = fill?.fill { base = style.color(color, placeholder: fill?.placeholderColor) } else { base = .black }
                case .stroke:
                    let line = shape.flatMap { style.line(for: $0, sources: style.sources(for: $0)) }
                    if case .solid(let color)? = line?.line.fill { base = style.color(color, placeholder: line?.placeholderColor) } else { base = .black }
                case .text:
                    let run = shape?.text?.paragraphs.first?.runs.first?.properties.color
                    base = run.map { style.color($0) } ?? style.color(.scheme("tx1"))
                }
                let color = changes.reduce(base) { base, change in change.color(base: base) { style.color($0) } }
                json[target.rawValue] = css(color)
            }
            return json
        }
        var shapes: [String: Any] = [:]
        for (shapeID, value) in frame.shapes {
            guard let shape = ids[shapeID] else { continue }
            shapes[shape.id.uuidString] = appearance(value, shape: shape)
        }
        var paragraphs: [String: Any] = [:]
        for (shapeID, values) in frame.paragraphs {
            guard let shape = ids[shapeID] else { continue }
            paragraphs[shape.id.uuidString] = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), appearance($0.value, shape: shape)) })
        }
        return ["shapes": shapes, "paras": paragraphs]
    }

    private static func mimeType(of data: Data, path: String) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        let ext = (path as NSString).pathExtension
        return MediaTypes.mimeType(forExtension: ext)
    }
}
