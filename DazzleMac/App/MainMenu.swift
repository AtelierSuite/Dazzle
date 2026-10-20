import AppKit
import DazzleEngine

/// The menu bar. Commands that act on a presentation go to the first
/// responder, which for a presentation window ends at its window controller.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        for submenu in [app, file, edit, insert, slide, format, arrange, view, play, window, help] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private typealias Commands = DocumentWindowController

    // MARK: - Menus

    private static var app: NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item(String(format: String(localized: "Menu.App.About"), name),
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Menu.App.Services"))
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Menu.App.Hide"), name), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Menu.App.HideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                          [.command, .option]))
        menu.addItem(item(String(localized: "Menu.App.ShowAll"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Menu.App.Quit"), name), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static var file: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.File"))
        menu.addItem(item(String(localized: "Menu.File.New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Menu.File.Open"), #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: String(localized: "Menu.File.OpenRecent"))
        recent.addItem(item(String(localized: "Menu.File.ClearRecent"), #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.File.Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Menu.File.Save"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(String(localized: "Menu.File.Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Menu.File.Rename"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Menu.File.MoveTo"), #selector(NSDocument.move(_:))))
        menu.addItem(item(String(localized: "Menu.File.RevertToSaved"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        let export = NSMenu(title: String(localized: "Menu.File.ExportTo"))
        export.addItem(item(String(localized: "Menu.File.Export.PDF"), #selector(Commands.exportPDF(_:))))
        export.addItem(item(String(localized: "Menu.File.Export.Images"), #selector(Commands.exportImages(_:))))
        export.addItem(item(String(localized: "Menu.File.Export.Movie"), #selector(Commands.exportMovie(_:))))
        export.addItem(item(String(localized: "Menu.File.Export.PowerPoint"), #selector(Commands.exportPowerPoint(_:))))
        menu.addItem(submenu(export))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.File.PageSetup"), #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        menu.addItem(item(String(localized: "Menu.File.Print"), #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static var edit: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Edit"))
        menu.addItem(item(String(localized: "Toolbar.Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Toolbar.Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Edit.Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Edit.Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Edit.Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Menu.Edit.Delete"), #selector(NSText.delete(_:))))
        menu.addItem(item(String(localized: "Menu.Edit.SelectAll"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(item(String(localized: "Menu.Edit.DeselectAll"), #selector(Commands.deselectAll(_:)), "a", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "ActionBar.Duplicate"), #selector(Commands.duplicateSelection(_:)), "d"))
        menu.addItem(.separator())
        let find = NSMenu(title: String(localized: "Menu.Edit.Find"))
        find.addItem(item(String(localized: "Menu.Edit.Find.Find"), #selector(Commands.showFind(_:)), "f"))
        find.addItem(item(String(localized: "Menu.Edit.Find.Next"), #selector(Commands.findNext(_:)), "g"))
        find.addItem(item(String(localized: "Menu.Edit.Find.Previous"), #selector(Commands.findPrevious(_:)), "g", [.command, .shift]))
        menu.addItem(submenu(find))
        return menu
    }

    private static var insert: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Insert"))
        menu.addItem(item(String(localized: "Menu.Insert.Choose"), #selector(Commands.insertMedia(_:)), "v", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Insert.TextBox"), #selector(Commands.insertTextBox(_:))))
        let shapes = NSMenu(title: String(localized: "Menu.Insert.Shape"))
        for choice in ShapeChoice.all {
            let entry = item(choice.label, #selector(Commands.insertShape(_:)))
            entry.representedObject = choice.preset
            entry.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            shapes.addItem(entry)
        }
        menu.addItem(submenu(shapes))
        let tables = NSMenu(title: String(localized: "Menu.Insert.Table"))
        for size in Commands.tableSizes {
            let entry = item(String(format: String(localized: "Table.Size"), size.columns, size.rows), #selector(Commands.insertTable(_:)))
            entry.representedObject = [size.rows, size.columns]
            tables.addItem(entry)
        }
        menu.addItem(submenu(tables))
        let charts = NSMenu(title: String(localized: "Menu.Insert.Chart"))
        for kind in Chart.Kind.allCases {
            let entry = item(kind.label, #selector(Commands.insertChart(_:)))
            entry.representedObject = kind.rawValue
            entry.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            charts.addItem(entry)
        }
        menu.addItem(submenu(charts))
        return menu
    }

    private static var slide: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Slide"))
        menu.addItem(item(String(localized: "Slide.New"), #selector(Commands.newSlide(_:)), "n", [.command, .shift]))
        let layouts = NSMenu(title: String(localized: "Menu.Slide.NewWithLayout"))
        layouts.delegate = LayoutMenuFiller.shared
        menu.addItem(submenu(layouts))
        menu.addItem(item(String(localized: "Slide.Menu.Duplicate"), #selector(Commands.duplicateSlide(_:))))
        menu.addItem(item(String(localized: "Slide.Menu.Delete"), #selector(Commands.deleteSlide(_:))))
        menu.addItem(item(String(localized: "Slide.Menu.Hide"), #selector(Commands.toggleSlideHidden(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Slide.HeaderFooter"), #selector(Commands.showHeaderFooter(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Slide.Menu.MoveUp"), #selector(Commands.moveSlideEarlier(_:))))
        menu.addItem(item(String(localized: "Slide.Menu.MoveDown"), #selector(Commands.moveSlideLater(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Slide.Previous"), #selector(Commands.previousSlide(_:)),
                          String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .option]))
        menu.addItem(item(String(localized: "Menu.Slide.Next"), #selector(Commands.nextSlide(_:)),
                          String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command, .option]))
        return menu
    }

    private static var format: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Format"))
        let font = NSMenu(title: String(localized: "Format.Font"))
        font.addItem(item(String(localized: "Format.Bold"), #selector(Commands.formatBold(_:)), "b"))
        font.addItem(item(String(localized: "Format.Italic"), #selector(Commands.formatItalic(_:)), "i"))
        font.addItem(item(String(localized: "Format.Underline"), #selector(Commands.formatUnderline(_:)), "u"))
        font.addItem(item(String(localized: "Format.Strikethrough"), #selector(Commands.formatStrikethrough(_:))))
        font.addItem(.separator())
        font.addItem(item(String(localized: "Menu.Format.Bigger"), #selector(Commands.formatBigger(_:)), "+"))
        font.addItem(item(String(localized: "Menu.Format.Smaller"), #selector(Commands.formatSmaller(_:)), "-"))
        font.addItem(.separator())
        font.addItem(item(String(localized: "Format.Superscript"), #selector(Commands.formatSuperscript(_:)), "=", [.command, .control]))
        font.addItem(item(String(localized: "Format.Subscript"), #selector(Commands.formatSubscript(_:)), "-", [.command, .control]))
        menu.addItem(submenu(font))
        let text = NSMenu(title: String(localized: "Format.Section.Text"))
        let alignments: [(String, ParagraphAlignment, String)] = [
            ("Menu.Format.AlignLeft", .left, "{"), ("Menu.Format.Centre", .center, "|"),
            ("Menu.Format.AlignRight", .right, "}"), ("Menu.Format.Justify", .justified, ""),
        ]
        for (key, alignment, keyEquivalent) in alignments {
            let entry = item(String(localized: String.LocalizationValue(key)), #selector(Commands.alignText(_:)), keyEquivalent)
            entry.representedObject = alignment.rawValue
            text.addItem(entry)
        }
        text.addItem(.separator())
        text.addItem(item(String(localized: "Format.List.Bullets"), #selector(Commands.formatBullets(_:))))
        text.addItem(item(String(localized: "Format.List.Numbers"), #selector(Commands.formatNumbers(_:))))
        text.addItem(.separator())
        text.addItem(item(String(localized: "Format.Indent"), #selector(Commands.increaseIndent(_:)), "]"))
        text.addItem(item(String(localized: "Format.Outdent"), #selector(Commands.decreaseIndent(_:)), "["))
        menu.addItem(submenu(text))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Picture.Crop"), #selector(Commands.toggleCropping(_:))))
        menu.addItem(item(String(localized: "Picture.ResetCrop"), #selector(Commands.resetCrop(_:))))
        menu.addItem(item(String(localized: "Picture.Replace"), #selector(Commands.replacePicture(_:))))
        return menu
    }

    private static var arrange: NSMenu {
        let menu = NSMenu(title: String(localized: "ActionBar.Arrange"))
        menu.addItem(item(String(localized: "Arrange.Front"), #selector(Commands.bringToFront(_:)), "f", [.command, .shift]))
        menu.addItem(item(String(localized: "Arrange.Forward"), #selector(Commands.bringForward(_:)), "f", [.command, .shift, .option]))
        menu.addItem(item(String(localized: "Arrange.Backward"), #selector(Commands.sendBackward(_:)), "b", [.command, .shift, .option]))
        menu.addItem(item(String(localized: "Arrange.Back"), #selector(Commands.sendToBack(_:)), "b", [.command, .shift]))
        menu.addItem(.separator())
        let align = NSMenu(title: String(localized: "Menu.Arrange.AlignObjects"))
        let choices: [(String, EditorState.Alignment)] = [
            ("Align.Left", .left), ("Align.Center", .center), ("Align.Right", .right),
            ("Align.Top", .top), ("Align.Middle", .middle), ("Align.Bottom", .bottom),
        ]
        for (index, (key, _)) in choices.enumerated() {
            if index == 3 { align.addItem(.separator()) }
            let entry = item(String(localized: String.LocalizationValue(key)), #selector(Commands.alignObjects(_:)))
            entry.tag = index
            align.addItem(entry)
        }
        menu.addItem(submenu(align))
        let distribute = NSMenu(title: String(localized: "Menu.Arrange.Distribute"))
        distribute.addItem(item(String(localized: "Align.DistributeHorizontally"), #selector(Commands.distributeHorizontally(_:))))
        distribute.addItem(item(String(localized: "Align.DistributeVertically"), #selector(Commands.distributeVertically(_:))))
        menu.addItem(submenu(distribute))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Arrange.RotateLeft"), #selector(Commands.rotateLeft(_:))))
        menu.addItem(item(String(localized: "Arrange.RotateRight"), #selector(Commands.rotateRight(_:))))
        menu.addItem(item(String(localized: "Arrange.FlipHorizontal"), #selector(Commands.flipHorizontally(_:))))
        menu.addItem(item(String(localized: "Arrange.FlipVertical"), #selector(Commands.flipVertically(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Arrange.Group"), #selector(Commands.groupShapes(_:)), "g", [.command, .option]))
        menu.addItem(item(String(localized: "Arrange.Ungroup"), #selector(Commands.ungroupShapes(_:)), "g", [.command, .option, .shift]))
        return menu
    }

    private static var view: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.View"))
        menu.addItem(item(String(localized: "Menu.View.Navigator"), #selector(NSSplitViewController.toggleSidebar(_:)), "s",
                          [.command, .control]))
        menu.addItem(item(String(localized: "Menu.View.Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), "i",
                          [.command, .option]))
        menu.addItem(item(String(localized: "Menu.View.Notes"), #selector(Commands.toggleNotes(_:)), "n", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.View.ZoomIn"), #selector(Commands.zoomIn(_:)), ">"))
        menu.addItem(item(String(localized: "Menu.View.ZoomOut"), #selector(Commands.zoomOut(_:)), "<"))
        menu.addItem(item(String(localized: "Menu.View.ActualSize"), #selector(Commands.zoomToActualSize(_:)), "0"))
        menu.addItem(item(String(localized: "Menu.View.ZoomToFit"), #selector(Commands.zoomToFit(_:)), "0", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.View.ShowToolbar"), #selector(NSWindow.toggleToolbarShown(_:)), "t",
                          [.command, .option]))
        menu.addItem(item(String(localized: "Menu.View.CustomiseToolbar"), #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        return menu
    }

    private static var play: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Play"))
        menu.addItem(item(String(localized: "Toolbar.PlayFromCurrent"), #selector(Commands.playSlideshow(_:)), "p", [.command, .option]))
        menu.addItem(item(String(localized: "Toolbar.PlayFromStart"), #selector(Commands.playFromBeginning(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Play.PreviewAnimations"), #selector(Commands.previewAnimations(_:))))
        return menu
    }

    private static var window: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Window"))
        menu.addItem(item(String(localized: "Menu.Window.Minimise"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Menu.Window.Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Window.BringAllToFront"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    private static var help: NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Help"))
        menu.addItem(item(String(localized: "Toolbar.SourceCode"), #selector(AppDelegate.showSourceCode(_:))))
        NSApp.helpMenu = menu
        return menu
    }

    // MARK: - Building

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Fills Slide ▸ New Slide with Layout with the front presentation's layouts
/// each time it opens.
@MainActor
final class LayoutMenuFiller: NSObject, NSMenuDelegate {
    static let shared = LayoutMenuFiller()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let deck = (NSApp.mainWindow?.windowController as? DocumentWindowController)?.deck
        for layout in deck?.presentation.resources.orderedLayouts ?? [] {
            let item = NSMenuItem(title: layout.name, action: #selector(DocumentWindowController.newSlide(_:)), keyEquivalent: "")
            item.representedObject = layout.path
            menu.addItem(item)
        }
    }
}
