import DazzleEngine
import SwiftUI
import UIKit

/// What the canvas's edit menu offers for the selection, or with nothing
/// selected, for the slide: the same actions as the toolbar and the action
/// bar, so each is undone the same way. VoiceOver reaches them as custom
/// actions on each shape and on the slide.
struct CanvasMenu: Equatable {
    enum Action: Hashable {
        case cut
        case copy
        case paste
        case duplicate
        case delete
        case editText
        case bringForward
        case sendBackward
        case group
        case ungroup
        case editChart
        case table(EditorState.TableChange)
        case tableOption(SlideTable.StyleOption)
        case selectAll
        case skipSlide
        case duplicateSlide

        /// Whether it changes the document, and so is a step to undo, rather
        /// than only the selection, the clipboard or what is open.
        var changesDocument: Bool {
            switch self {
            case .copy, .editText, .editChart, .selectAll: false
            default: true
            }
        }
    }

    struct Item: Equatable {
        var action: Action
        var title: String
        var symbol: String
        var isDestructive = false
        /// For a switch, whether it is on.
        var isOn: Bool?
    }

    /// The items shown in the menu itself.
    var items: [Item] = []
    /// A selected table's rows, columns and styling, in a submenu of their own.
    var tableItems: [Item] = []

    /// Every item, the table's after the rest.
    var allItems: [Item] { items + tableItems }

    var isEmpty: Bool { allItems.isEmpty }

    /// The menu for `selection` on `slide`, or with no selection, for the slide.
    /// Only what can apply is offered: nothing that changes a shape for a
    /// locked one, or for any on a slide whose shapes can't be edited.
    init(selection: [SlideShape], on slide: Slide, canPaste: Bool) {
        if selection.isEmpty {
            if canPaste { add(.paste, "Edit.Paste", "doc.on.clipboard") }
            if slide.shapes.contains(where: { !$0.isHidden }) {
                add(.selectAll, "Menu.Edit.SelectAll", "checkmark.circle")
            }
            if slide.isHidden {
                add(.skipSlide, "Slide.Menu.Show", "eye")
            } else {
                add(.skipSlide, "Slide.Menu.Hide", "eye.slash")
            }
            add(.duplicateSlide, "Slide.Menu.Duplicate", "plus.square.on.square")
            return
        }
        let canChange = slide.canEditShapes && selection.allSatisfy(\.isEditable)
        let single = selection.count == 1 ? selection.first : nil
        if canChange { add(.cut, "Edit.Cut", "scissors") }
        add(.copy, "Edit.Copy", "doc.on.doc")
        if canPaste { add(.paste, "Edit.Paste", "doc.on.clipboard") }
        guard canChange else { return }
        add(.duplicate, "ActionBar.Duplicate", "plus.square.on.square")
        add(.delete, "ActionBar.Delete", "trash", destructive: true)
        if let single, single.canHoldText {
            add(.editText, "ActionBar.EditText", "character.cursor.ibeam")
        }
        add(.bringForward, "Arrange.Forward", "square.2.layers.3d.top.filled")
        add(.sendBackward, "Arrange.Backward", "square.2.layers.3d.bottom.filled")
        if selection.filter({ $0.placeholder == nil }).count > 1 {
            add(.group, "Arrange.Group", "square.on.square.squareshape.controlhandles")
        } else if let single, case .group = single.kind {
            add(.ungroup, "Arrange.Ungroup", "square.on.square.dashed")
        }
        if let single, case .chart(_?) = single.kind {
            add(.editChart, "ActionBar.ChartData", "chart.bar.doc.horizontal")
        }
        if let single, case .table(let table) = single.kind {
            func row(_ action: Action, _ key: String.LocalizationValue, _ symbol: String, destructive: Bool = false, isOn: Bool? = nil) {
                tableItems.append(Item(
                    action: action, title: String(localized: key), symbol: symbol, isDestructive: destructive, isOn: isOn
                ))
            }
            row(.table(.rowAbove), "Table.RowAbove", "arrow.up.to.line")
            row(.table(.rowBelow), "Table.RowBelow", "arrow.down.to.line")
            row(.table(.columnLeft), "Table.ColumnLeft", "arrow.left.to.line")
            row(.table(.columnRight), "Table.ColumnRight", "arrow.right.to.line")
            if table.rows.count > 1 {
                row(.table(.deleteRow), "Table.DeleteRow", "minus.rectangle", destructive: true)
            }
            if table.columnCount > 1 {
                row(.table(.deleteColumn), "Table.DeleteColumn", "minus.rectangle.portrait", destructive: true)
            }
            for option in SlideTable.StyleOption.allCases {
                tableItems.append(Item(action: .tableOption(option), title: option.label, symbol: option.symbol, isOn: table[option]))
            }
        }
    }

    private mutating func add(_ action: Action, _ key: String.LocalizationValue, _ symbol: String, destructive: Bool = false) {
        items.append(Item(action: action, title: String(localized: key), symbol: symbol, isDestructive: destructive))
    }
}

extension EditorState {
    /// The canvas menu for what is selected now.
    func canvasMenu(in presentation: Presentation, canPaste: Bool) -> CanvasMenu? {
        guard let slide = selectedSlide(in: presentation) else { return nil }
        return CanvasMenu(selection: selectedShapes(in: presentation), on: slide, canPaste: canPaste)
    }

    /// Carries out one of the canvas menu's actions on the selection, or the
    /// slide, writing to `presentation` only for one that changes it, so the
    /// others leave nothing to undo.
    func perform(_ action: CanvasMenu.Action, in presentation: Binding<Presentation>) {
        if action.changesDocument {
            perform(action, in: &presentation.wrappedValue)
        } else {
            var unchanged = presentation.wrappedValue
            perform(action, in: &unchanged)
        }
    }

    /// Carries out one of the canvas menu's actions on the selection, or the slide.
    func perform(_ action: CanvasMenu.Action, in presentation: inout Presentation) {
        switch action {
        case .cut: cutSelection(in: &presentation)
        case .copy: copySelection(in: presentation)
        case .paste: paste(in: &presentation)
        case .duplicate: duplicateSelectedShape(in: &presentation)
        case .delete: deleteSelectedShape(in: &presentation)
        case .editText:
            if let id = selectedShapeID { beginEditingText(id) }
        case .bringForward: arrangeSelectedShape(.forward, in: &presentation)
        case .sendBackward: arrangeSelectedShape(.backward, in: &presentation)
        case .group: groupSelectedShapes(in: &presentation)
        case .ungroup: ungroupSelectedShape(in: &presentation)
        case .editChart: presentedPanel = .chart
        case .table(let change): changeTable(change, in: &presentation)
        case .tableOption(let option):
            setTableOption(option, !(selectedTable(in: presentation)?[option] ?? false), in: &presentation)
        case .selectAll: selectAllShapes(in: presentation)
        case .skipSlide:
            if let id = selectedSlide(in: presentation)?.id { toggleHidden(id, in: &presentation) }
        case .duplicateSlide:
            if let id = selectedSlide(in: presentation)?.id { duplicateSlide(id, in: &presentation) }
        }
    }
}

// MARK: - Showing the menu

/// Where the canvas's edit menu was asked for: the touch, and the part of
/// the canvas it should keep clear of, in the canvas's own coordinates.
struct CanvasMenuRequest: Equatable {
    var id = UUID()
    var point: CGPoint
    var avoiding: CGRect?
}

/// Shows the system edit menu over the canvas when asked, next to the touch
/// and above or below what it is for rather than over it.
struct CanvasEditMenu: UIViewRepresentable {
    var request: CanvasMenuRequest?
    var menu: () -> CanvasMenu?
    var perform: (CanvasMenu.Action) -> Void
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard request?.id != coordinator.presented?.id else { return }
        coordinator.presented = request
        if let request {
            coordinator.interaction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: request.point))
        } else {
            coordinator.interaction?.dismissMenu()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
        var parent: CanvasEditMenu
        var presented: CanvasMenuRequest?
        weak var interaction: UIEditMenuInteraction?
        weak var view: UIView?

        init(parent: CanvasEditMenu) {
            self.parent = parent
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let menu = parent.menu(), !menu.isEmpty else { return nil }
            let perform = parent.perform
            func action(_ item: CanvasMenu.Item) -> UIAction {
                let action = UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { _ in perform(item.action) }
                if item.isDestructive { action.attributes = .destructive }
                if let isOn = item.isOn { action.state = isOn ? .on : .off }
                return action
            }
            var children: [UIMenuElement] = menu.items.map(action)
            if !menu.tableItems.isEmpty {
                children.append(UIMenu(
                    title: String(localized: "ActionBar.Table"), image: UIImage(systemName: "tablecells"),
                    children: menu.tableItems.map(action)
                ))
            }
            return UIMenu(children: children)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            let point = presented?.point ?? configuration.sourcePoint
            guard let avoiding = presented?.avoiding, let view else {
                return CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            }
            // A thin column through the touch, as tall as what the menu is
            // for, so the menu sits by the finger but clear of the shape;
            // kept to what is on screen, for a shape bigger than that.
            var target = CGRect(x: point.x - 1, y: avoiding.minY, width: 2, height: avoiding.height)
            if let window = view.window {
                let visible = view.convert(window.bounds, from: window)
                target = target.intersection(visible.insetBy(dx: 0, dy: 60))
            }
            return target.isNull || target.isEmpty ? CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2) : target
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) {
            parent.onDismiss()
        }
    }
}

/// A long press, or a secondary click with a pointer, on the canvas.
struct CanvasPressRecognizer: UIGestureRecognizerRepresentable {
    /// Whether this is the pointer's secondary click rather than a long press.
    var isSecondaryClick = false
    var onBegan: (CGPoint) -> Void
    var onEnded: () -> Void = { /* Nothing to settle. */ }

    func makeUIGestureRecognizer(context: Context) -> UIGestureRecognizer {
        let recognizer: UIGestureRecognizer
        if isSecondaryClick {
            let tap = UITapGestureRecognizer()
            tap.buttonMaskRequired = .secondary
            // Only a pointer has a secondary button; a touch would otherwise count.
            tap.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
            recognizer = tap
        } else {
            let press = UILongPressGestureRecognizer()
            // As far as a finger can wander before it is a drag instead.
            press.allowableMovement = 6
            recognizer = press
        }
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began where !isSecondaryClick, .ended where isSecondaryClick:
            onBegan(context.converter.localLocation)
            if isSecondaryClick { onEnded() }
        case .ended, .cancelled, .failed:
            if !isSecondaryClick { onEnded() }
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
