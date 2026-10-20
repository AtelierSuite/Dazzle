import AppKit
import DazzleEngine

/// The Animate tab: the slide's animations in the order a slideshow plays
/// them, what adds more to the selected objects, and the picked one's
/// effect and timing.
extension InspectorViewController: NSTableViewDataSource, NSTableViewDelegate {
    private var slide: Slide? { deck.selectedSlide }
    private var animations: [ShapeAnimation] { slide?.animations ?? [] }
    private var selectedAnimation: ShapeAnimation? { animations.first { $0.id == selectedAnimationID } }

    func buildAnimate() {
        guard let slide else { return }
        let canEdit = slide.canEditShapes
        let hasSelection = deck.selectedShapes.contains(where: \.isEditable)

        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.addItem(withTitle: String(localized: "Animation.Add"))
        for category in [ShapeAnimation.Category.entrance, .emphasis, .exit] {
            let header = NSMenuItem(title: category.label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            add.menu?.addItem(header)
            for effect in ShapeAnimation.Effect.choices(for: category) {
                let target = ActionTarget { [unowned self] in
                    var added: ShapeAnimation.ID?
                    edit { added = state.addAnimation(effect, category: category, in: &$0) }
                    if let added { selectedAnimationID = added }
                    refresh()
                }
                let item = NSMenuItem(title: effect.label(in: category), action: #selector(ActionTarget.run(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.image = NSImage(systemSymbolName: effect.symbol, accessibilityDescription: nil)
                item.indentationLevel = 1
                add.menu?.addItem(item)
            }
        }
        add.isEnabled = canEdit && hasSelection
        add.setAccessibilityIdentifier("addAnimation")
        let preview = form.button(String(localized: "Animation.Preview"), symbol: "play.fill") { [unowned self] in
            if state.animationPreviewStartedAt != nil {
                state.stopPreviewingAnimations()
            } else {
                state.previewAnimations(in: deck.presentation)
            }
        }
        preview.isEnabled = !slide.animations.isEmpty
        let buttons = NSStackView(views: [add, preview])
        buttons.spacing = 8
        form.add(buttons)
        if !hasSelection, canEdit { form.note(String(localized: "Animation.SelectHint")) }

        guard !slide.animations.isEmpty else { return }
        form.section(String(localized: "Animation.Section.Order"))
        buildList()
        form.note(String(localized: "Mac.Animation.Footer"))
        if let animation = selectedAnimation { buildDetail(animation, canEdit: canEdit) }
    }

    private func buildList() {
        if animationList.tableColumns.isEmpty {
            animationList.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("animation")))
            animationList.headerView = nil
            animationList.style = .inset
            animationList.rowHeight = 38
            animationList.dataSource = self
            animationList.delegate = self
        }
        let scroll = NSScrollView()
        scroll.documentView = animationList
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        form.add(scroll, fill: true)
        scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(max(animations.count, 2)) * 40 + 8, 240)).isActive = true
        animationList.reloadData()
        if let index = animations.firstIndex(where: { $0.id == selectedAnimationID }) {
            animationList.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    private func buildDetail(_ animation: ShapeAnimation, canEdit: Bool) {
        let id = animation.id
        form.section(animation.label)
        let choices = ShapeAnimation.Effect.choices(for: animation.category)
        let isChoosable = animation.effect.isMadeByDazzle && choices.contains { $0.isKind(of: animation.effect) }
        if isChoosable {
            let effect = form.popup(choices.map { $0.label(in: animation.category) }, get: { [unowned self] in
                guard let effect = selectedAnimation?.effect else { return nil }
                return choices.firstIndex { $0.isKind(of: effect) }
            }, set: { [unowned self] index in
                let direction = selectedAnimation?.effect.direction ?? .bottom
                edit { state.setEffect(choices[index].with(direction), of: id, in: &$0) }
            })
            effect.isEnabled = canEdit
            form.row(String(localized: "Animation.Effect"), effect)
            if animation.effect.direction != nil {
                let directions = ShapeAnimation.Direction.allCases
                let direction = form.popup(directions.map(\.label), get: { [unowned self] in
                    selectedAnimation?.effect.direction.flatMap(directions.firstIndex(of:))
                }, set: { [unowned self] index in
                    guard let effect = selectedAnimation?.effect else { return }
                    edit { state.setEffect(effect.with(directions[index]), of: id, in: &$0) }
                })
                direction.isEnabled = canEdit
                form.row(String(localized: "Animation.Direction"), direction)
            }
        } else {
            form.row(String(localized: "Animation.Effect"), NSTextField(labelWithString: animation.label))
            if !animation.effect.isMadeByDazzle { form.note(String(localized: "Animation.Custom.Footer")) }
        }

        let triggers = ShapeAnimation.Trigger.allCases
        let start = form.popup(triggers.map(\.label), get: { [unowned self] in
            selectedAnimation.flatMap { triggers.firstIndex(of: $0.trigger) }
        }, set: { [unowned self] index in
            edit { state.updateAnimation(id, in: &$0) { $0.trigger = triggers[index] } }
        })
        start.isEnabled = canEdit
        form.row(String(localized: "Animation.Start"), start)
        if animation.effect != .appear {
            let duration = form.number(get: { [unowned self] in selectedAnimation?.duration ?? 0.5 }, set: { [unowned self] seconds in
                edit { state.updateAnimation(id, in: &$0) { $0.duration = (seconds * 100).rounded() / 100 } }
            }, range: 0.1...60, step: 0.25, unit: String(localized: "Advance.Seconds"))
            form.row(String(localized: "Animation.Duration"), duration)
        }
        form.row(String(localized: "Animation.Delay"), form.number(get: { [unowned self] in selectedAnimation?.delay ?? 0 },
                                                                   set: { [unowned self] seconds in
            edit { state.updateAnimation(id, in: &$0) { $0.delay = (seconds * 100).rounded() / 100 } }
        }, range: 0...60, step: 0.25, unit: String(localized: "Advance.Seconds")))

        let order = form.actions([
            ("arrow.up", String(localized: "Animation.MoveEarlier")), ("arrow.down", String(localized: "Animation.MoveLater")),
        ]) { [unowned self] index in
            guard let position = animations.firstIndex(where: { $0.id == id }) else { return }
            if index == 0, position > 0 {
                edit { state.moveAnimations(from: [position], to: position - 1, in: &$0) }
            } else if index == 1, position < animations.count - 1 {
                edit { state.moveAnimations(from: [position], to: position + 2, in: &$0) }
            }
        }
        let delete = form.button(String(localized: "Animation.Delete"), symbol: "trash") { [unowned self] in
            selectedAnimationID = nil
            edit { state.deleteAnimations([id], in: &$0) }
            refresh()
        }
        order.isEnabled = canEdit
        delete.isEnabled = canEdit
        let row = NSStackView(views: [order, delete])
        row.spacing = 8
        form.row(nil, row)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { animations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let slide, animations.indices.contains(row) else { return nil }
        let animation = animations[row]
        let shape = slide.shapes.first { $0.shapeID == animation.shapeID }
        let badge: NSView
        if animation.trigger == .onClick, let number = slide.animationTimeline.tapNumber(of: animation.id) {
            let label = NSTextField(labelWithString: String(number))
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
            badge = label
        } else {
            let symbol = animation.trigger == .afterPrevious ? "clock" : "link"
            badge = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: animation.trigger.label) ?? NSImage())
            (badge as? NSImageView)?.contentTintColor = .secondaryLabelColor
        }
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let star = NSImageView(image: NSImage(systemSymbolName: animation.category.symbol, accessibilityDescription: nil) ?? NSImage())
        star.contentTintColor = switch animation.category {
        case .entrance: .systemGreen
        case .emphasis: .systemYellow
        case .exit: .systemRed
        case .motionPath: .systemBlue
        case .other: .secondaryLabelColor
        }
        let title = NSTextField(labelWithString: animation.label)
        let target = NSTextField(labelWithString: animation.targetLabel(shape: shape))
        target.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target.textColor = .secondaryLabelColor
        target.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, target])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [badge, star, text])
        row.spacing = 8
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = animationList.selectedRow
        let picked = animations.indices.contains(row) ? animations[row] : nil
        guard picked?.id != selectedAnimationID else { return }
        selectedAnimationID = picked?.id
        // The shape it animates is picked out on the slide.
        if let picked, let shape = slide?.shapes.first(where: { $0.shapeID == picked.shapeID }) {
            state.selectedShapeID = shape.id
        }
        refresh()
    }
}
