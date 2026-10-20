import AppKit
import DazzleEngine

/// What the menu bar, the toolbar and the context menus ask of a
/// presentation window. Each acts on the slide and shapes selected, or
/// while text is being typed, on the selected text.
extension DocumentWindowController: NSMenuItemValidation {
    private var state: EditorState { deck.state }

    /// Rows by columns.
    static let tableSizes: [(rows: Int, columns: Int)] = [(2, 2), (3, 2), (3, 3), (4, 3), (4, 4), (5, 4), (6, 5)]

    private func edit(_ change: (inout Presentation) -> Void) {
        deck.edit(change)
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        state.copySelection(in: deck.presentation)
    }

    @objc func cut(_ sender: Any?) {
        edit { state.cutSelection(in: &$0) }
    }

    @objc func paste(_ sender: Any?) {
        edit { state.paste(in: &$0) }
    }

    @objc func delete(_ sender: Any?) {
        edit { state.deleteSelectedShape(in: &$0) }
    }

    @objc override func selectAll(_ sender: Any?) {
        state.selectAllShapes(in: deck.presentation)
    }

    @objc func deselectAll(_ sender: Any?) {
        state.selectedShapeID = nil
    }

    /// Duplicates the selected shapes, or with none, the slide.
    @objc func duplicateSelection(_ sender: Any?) {
        if state.selectedShapeIDs.isEmpty {
            duplicateSlide(sender)
        } else {
            edit { state.duplicateSelectedShape(in: &$0) }
        }
    }

    @objc func editText(_ sender: Any?) {
        guard let shape = deck.selectedShape, shape.canHoldText, shape.isEditable else { return }
        state.beginEditingText(shape.id)
    }

    // MARK: - Slides

    /// A new slide after the selected one, on the layout the menu item
    /// names, or failing that, the selected slide's.
    @objc func newSlide(_ sender: Any?) {
        let presentation = deck.presentation
        let layouts = presentation.resources.orderedLayouts
        let path = (sender as? NSMenuItem)?.representedObject as? String
        let current = deck.selectedSlide.flatMap { presentation.layout(for: $0) }
        guard let layout = layouts.first(where: { $0.path == path }) ?? current ?? layouts.first else { return }
        edit { state.addSlide(using: layout, in: &$0) }
    }

    @objc func duplicateSlide(_ sender: Any?) {
        guard let id = deck.selectedSlide?.id else { return }
        edit { state.duplicateSlide(id, in: &$0) }
    }

    @objc func deleteSlide(_ sender: Any?) {
        guard let id = deck.selectedSlide?.id else { return }
        edit { state.deleteSlide(id, in: &$0) }
    }

    @objc func toggleSlideHidden(_ sender: Any?) {
        guard let id = deck.selectedSlide?.id else { return }
        edit { state.toggleHidden(id, in: &$0) }
    }

    @objc func moveSlideEarlier(_ sender: Any?) {
        guard let id = deck.selectedSlide?.id else { return }
        let index = deck.selectedIndex
        edit { state.moveSlide(id, to: index - 1, in: &$0) }
    }

    @objc func moveSlideLater(_ sender: Any?) {
        guard let id = deck.selectedSlide?.id else { return }
        let index = deck.selectedIndex
        edit { state.moveSlide(id, to: index + 1, in: &$0) }
    }

    @objc func showHeaderFooter(_ sender: Any?) {
        guard let window else { return }
        let sheet = HeaderFooterSheet(deck: deck)
        headerFooter = sheet
        sheet.present(over: window)
    }

    @objc func previousSlide(_ sender: Any?) { step(by: -1) }

    @objc func nextSlide(_ sender: Any?) { step(by: 1) }

    private func step(by offset: Int) {
        let slides = deck.presentation.slides
        let index = deck.selectedIndex + offset
        guard slides.indices.contains(index) else { return }
        state.selectSlide(slides[index].id)
    }

    // MARK: - Inserting

    @objc func insertTextBox(_ sender: Any?) {
        edit { state.insertTextBox(in: &$0) }
        if let shape = deck.selectedShape { state.beginEditingText(shape.id) }
    }

    @objc func insertShape(_ sender: Any?) {
        guard let preset = (sender as? NSMenuItem)?.representedObject as? String else { return }
        edit { state.insertShape(preset, in: &$0) }
    }

    @objc func insertTable(_ sender: Any?) {
        guard let size = (sender as? NSMenuItem)?.representedObject as? [Int], size.count == 2 else { return }
        edit { state.insertTable(rows: size[0], columns: size[1], in: &$0) }
    }

    @objc func insertChart(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let kind = Chart.Kind(rawValue: raw) else { return }
        edit { state.insertChart(kind, in: &$0) }
    }

    @objc func insertMedia(_ sender: Any?) {
        MediaImporter.choose(into: deck, for: window)
    }

    // MARK: - Text

    @objc func formatBold(_ sender: Any?) { edit { state.toggleBold(in: &$0) } }
    @objc func formatItalic(_ sender: Any?) { edit { state.toggleItalic(in: &$0) } }
    @objc func formatUnderline(_ sender: Any?) { edit { state.toggleUnderline(in: &$0) } }
    @objc func formatStrikethrough(_ sender: Any?) { edit { state.toggleStrikethrough(in: &$0) } }
    @objc func formatSuperscript(_ sender: Any?) { edit { state.toggleBaseline(superscript: true, in: &$0) } }
    @objc func formatSubscript(_ sender: Any?) { edit { state.toggleBaseline(superscript: false, in: &$0) } }
    @objc func formatBigger(_ sender: Any?) { edit { state.stepFontSize(by: 2, in: &$0) } }
    @objc func formatSmaller(_ sender: Any?) { edit { state.stepFontSize(by: -2, in: &$0) } }
    @objc func increaseIndent(_ sender: Any?) { edit { state.changeIndent(by: 1, in: &$0) } }
    @objc func decreaseIndent(_ sender: Any?) { edit { state.changeIndent(by: -1, in: &$0) } }

    @objc func alignText(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let alignment = ParagraphAlignment(rawValue: raw) else { return }
        edit { state.setAlignment(alignment, in: &$0) }
    }

    @objc func formatBullets(_ sender: Any?) { toggleList(.bullets) }
    @objc func formatNumbers(_ sender: Any?) { toggleList(.numbers) }

    private func toggleList(_ choice: EditorState.ListStyleChoice) {
        let current = state.listStyle(in: deck.presentation)
        edit { state.setListStyle(current == choice ? .none : choice, in: &$0) }
    }

    private var canFormatText: Bool {
        if state.isEditingCell { return true }
        guard let shape = deck.selectedShape else { return false }
        return deck.canEditShapes && shape.isEditable && (shape.text != nil || shape.canHoldText || isTable(shape))
    }

    private func isTable(_ shape: SlideShape) -> Bool {
        if case .table = shape.kind { return true }
        return false
    }

    // MARK: - Pictures

    @objc func toggleCropping(_ sender: Any?) {
        guard let shape = deck.selectedShape else { return }
        state.croppingShapeID = state.croppingShapeID == shape.id ? nil : shape.id
    }

    @objc func resetCrop(_ sender: Any?) {
        edit { state.resetCrop(in: &$0) }
    }

    @objc func replacePicture(_ sender: Any?) {
        MediaImporter.chooseReplacement(into: deck, for: window)
    }

    private var canCrop: Bool {
        guard let shape = deck.selectedShape, !state.hasMultipleSelection else { return false }
        return shape.isPicture && shape.isEditable && shape.rotation == 0 && deck.canEditShapes
    }

    // MARK: - Arranging

    @objc func bringToFront(_ sender: Any?) { edit { state.arrangeSelectedShape(.front, in: &$0) } }
    @objc func bringForward(_ sender: Any?) { edit { state.arrangeSelectedShape(.forward, in: &$0) } }
    @objc func sendBackward(_ sender: Any?) { edit { state.arrangeSelectedShape(.backward, in: &$0) } }
    @objc func sendToBack(_ sender: Any?) { edit { state.arrangeSelectedShape(.back, in: &$0) } }

    /// The menu item's tag picks the alignment, in `EditorState.Alignment`'s order.
    @objc func alignObjects(_ sender: Any?) {
        let all: [EditorState.Alignment] = [.left, .center, .right, .top, .middle, .bottom]
        guard let tag = (sender as? NSMenuItem)?.tag, all.indices.contains(tag) else { return }
        edit { state.alignSelectedShapes(all[tag], in: &$0) }
    }

    @objc func distributeHorizontally(_ sender: Any?) { edit { state.distributeSelectedShapes(horizontally: true, in: &$0) } }
    @objc func distributeVertically(_ sender: Any?) { edit { state.distributeSelectedShapes(horizontally: false, in: &$0) } }
    @objc func rotateLeft(_ sender: Any?) { edit { state.rotateSelectedShape(clockwise: false, in: &$0) } }
    @objc func rotateRight(_ sender: Any?) { edit { state.rotateSelectedShape(clockwise: true, in: &$0) } }
    @objc func flipHorizontally(_ sender: Any?) { edit { state.flipSelectedShape(horizontally: true, in: &$0) } }
    @objc func flipVertically(_ sender: Any?) { edit { state.flipSelectedShape(horizontally: false, in: &$0) } }
    @objc func groupShapes(_ sender: Any?) { edit { state.groupSelectedShapes(in: &$0) } }
    @objc func ungroupShapes(_ sender: Any?) { edit { state.ungroupSelectedShape(in: &$0) } }

    private var canArrange: Bool {
        deck.canEditShapes && deck.selectedShapes.contains(where: \.isEditable)
    }

    // MARK: - View

    @objc func toggleNotes(_ sender: Any?) { split.editor.toggleNotes() }
    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomToActualSize(_ sender: Any?) { canvas.zoom(to: 1) }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    // MARK: - Playing

    @objc func playSlideshow(_ sender: Any?) { play(from: deck.selectedIndex) }
    @objc func playFromBeginning(_ sender: Any?) { play(from: 0) }

    func play(from index: Int) {
        state.endEditingText()
        state.stopPreviewingAnimations()
        SlideshowController.shared.start(deck: deck, title: name, from: index, editorWindow: window)
    }

    @objc func previewAnimations(_ sender: Any?) {
        if state.animationPreviewStartedAt != nil {
            state.stopPreviewingAnimations()
        } else {
            state.previewAnimations(in: deck.presentation)
        }
    }

    // MARK: - Finding

    @objc func showFind(_ sender: Any?) { finder.show(attachedTo: window) }
    @objc func findNext(_ sender: Any?) { finder.step(forward: true, attachedTo: window) }
    @objc func findPrevious(_ sender: Any?) { finder.step(forward: false, attachedTo: window) }

    // MARK: - Exporting

    @objc func exportPDF(_ sender: Any?) { exporter.export(.pdf) }
    @objc func exportImages(_ sender: Any?) { exporter.export(.images) }
    @objc func exportMovie(_ sender: Any?) { exporter.export(.video) }

    /// Saves a copy as PowerPoint, the way to share a Keynote document's slides.
    @objc func exportPowerPoint(_ sender: Any?) {
        exporter.exportPowerPoint()
    }

    private var exporter: ExportController {
        ExportController(deck: deck, name: name, window: window)
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let presentation = deck.presentation
        let hasShapes = !state.selectedShapeIDs.isEmpty
        let text = state.effectiveRunProperties(in: presentation)
        switch menuItem.action {
        case #selector(copy(_:)):
            menuItem.title = String(localized: hasShapes ? "Edit.Copy" : "Edit.CopySlide")
            return deck.selectedSlide != nil
        case #selector(cut(_:)):
            menuItem.title = String(localized: hasShapes ? "Edit.Cut" : "Edit.CutSlide")
            return hasShapes ? canArrange : presentation.slides.count > 1
        case #selector(paste(_:)):
            return deck.selectedSlide != nil
        case #selector(delete(_:)):
            return hasShapes && canArrange
        case #selector(selectAll(_:)):
            return !(deck.selectedSlide?.shapes.isEmpty ?? true)
        case #selector(deselectAll(_:)):
            return hasShapes
        case #selector(duplicateSelection(_:)):
            return hasShapes ? canArrange : deck.selectedSlide != nil
        case #selector(editText(_:)):
            return deck.selectedShape?.canHoldText == true && canArrange
        case #selector(deleteSlide(_:)):
            return presentation.slides.count > 1
        case #selector(duplicateSlide(_:)), #selector(showHeaderFooter(_:)):
            return deck.selectedSlide != nil
        case #selector(toggleSlideHidden(_:)):
            menuItem.title = String(localized: deck.selectedSlide?.isHidden == true ? "Slide.Menu.Show" : "Slide.Menu.Hide")
            return deck.selectedSlide != nil
        case #selector(moveSlideEarlier(_:)), #selector(previousSlide(_:)):
            return deck.selectedIndex > 0
        case #selector(moveSlideLater(_:)), #selector(nextSlide(_:)):
            return deck.selectedIndex < presentation.slides.count - 1
        case #selector(insertTextBox(_:)), #selector(insertShape(_:)), #selector(insertTable(_:)), #selector(insertChart(_:)),
             #selector(insertMedia(_:)):
            return deck.canEditShapes
        case #selector(formatBold(_:)):
            menuItem.state = text.isBold == true ? .on : .off
            return canFormatText
        case #selector(formatItalic(_:)):
            menuItem.state = text.isItalic == true ? .on : .off
            return canFormatText
        case #selector(formatUnderline(_:)):
            menuItem.state = text.isUnderlined == true ? .on : .off
            return canFormatText
        case #selector(formatStrikethrough(_:)):
            menuItem.state = text.isStruckThrough == true ? .on : .off
            return canFormatText
        case #selector(formatSuperscript(_:)):
            menuItem.state = (text.baseline ?? 0) > 0 ? .on : .off
            return canFormatText
        case #selector(formatSubscript(_:)):
            menuItem.state = (text.baseline ?? 0) < 0 ? .on : .off
            return canFormatText
        case #selector(alignText(_:)):
            let raw = menuItem.representedObject as? String
            menuItem.state = canFormatText && state.effectiveAlignment(in: presentation).rawValue == raw ? .on : .off
            return canFormatText
        case #selector(formatBullets(_:)):
            menuItem.state = canFormatText && state.listStyle(in: presentation) == .bullets ? .on : .off
            return canFormatText
        case #selector(formatNumbers(_:)):
            menuItem.state = canFormatText && state.listStyle(in: presentation) == .numbers ? .on : .off
            return canFormatText
        case #selector(formatBigger(_:)), #selector(formatSmaller(_:)), #selector(increaseIndent(_:)), #selector(decreaseIndent(_:)):
            return canFormatText
        case #selector(toggleCropping(_:)):
            menuItem.title = String(localized: state.croppingShapeID != nil ? "Picture.DoneCropping" : "Picture.Crop")
            return canCrop
        case #selector(resetCrop(_:)), #selector(replacePicture(_:)):
            return canCrop
        case #selector(bringToFront(_:)), #selector(bringForward(_:)), #selector(sendBackward(_:)), #selector(sendToBack(_:)):
            return canArrange && !state.hasMultipleSelection
        case #selector(alignObjects(_:)):
            return canArrange
        case #selector(distributeHorizontally(_:)), #selector(distributeVertically(_:)):
            return canArrange && state.selectedShapeIDs.count > 2
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(flipHorizontally(_:)), #selector(flipVertically(_:)):
            return canArrange && !state.hasMultipleSelection && deck.selectedShape?.canRotate == true
        case #selector(groupShapes(_:)):
            return canArrange && state.canGroupSelection
        case #selector(ungroupShapes(_:)):
            if case .group? = deck.selectedShape?.kind { return canArrange && !state.hasMultipleSelection }
            return false
        case #selector(toggleNotes(_:)):
            menuItem.title = String(localized: split.editor.areNotesShown ? "Mac.Menu.View.HideNotes" : "Menu.View.Notes")
            return true
        case #selector(playSlideshow(_:)), #selector(playFromBeginning(_:)):
            return !presentation.visibleSlideIndices.isEmpty && !SlideshowController.shared.isPresenting
        case #selector(previewAnimations(_:)):
            menuItem.title = String(localized: state.animationPreviewStartedAt != nil ? "Animation.Stop" : "Menu.Play.PreviewAnimations")
            return !(deck.selectedSlide?.animations.isEmpty ?? true)
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return finder.hasQuery
        default:
            return true
        }
    }
}
