import DazzleEngine
import SwiftUI

/// The document's root view: the slides down the side or along the bottom,
/// the slide being edited, the floating action bar, and the toolbar.
struct DeckView: View {
    @Binding var document: DazzleDocument
    /// The file's name, which exports are named after.
    var fileName: String?

    @State private var state = EditorState()
    @State private var bottomToolbarInset: CGFloat = 0
    @State private var history = DeckHistory()
    /// The presentation an edit Keynote can't keep was just taken back to.
    @State private var undoneTo: Presentation?
    /// Tells this window's slideshow apart from another window's.
    @State private var editorID = UUID()
    /// Flipped to put the quick Paste button back in the bar; see `quickPasteToolbar`.
    @State private var quickPasteGeneration = 0
    /// The pending `restoreQuickPaste()` flip, so a burst of events flips once.
    @State private var quickPasteRestore: Task<Void, Never>?
    /// The deck's fonts this device draws in others, kept up to date as it changes.
    @State private var fontSubstitutions: [FontSubstitution] = []
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var panelTransition

    private var session: PresentationSession { .shared }
    private var pasteboard: PasteboardMonitor { .shared }
    private var presentation: Binding<Presentation> { $document.presentation }

    private var name: String {
        fileName.map { ($0 as NSString).deletingPathExtension } ?? String(localized: "Document.DefaultName")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if horizontalSizeClass != .compact {
                    sidebar
                        .frame(width: 216)
                    Divider()
                        .ignoresSafeArea(edges: .bottom)
                }
                SlideCanvas(
                    presentation: presentation, state: state, onSwipe: step,
                    isRaised: state.presentedPanel != nil
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if document.presentation.isInMasterView, !state.isDrawing { masterViewBanner }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !state.isDrawing {
                            FloatingActionBar(presentation: presentation, state: state, namespace: panelTransition)
                                .padding(.bottom, 8 + (horizontalSizeClass == .compact ? 0 : bottomToolbarInset))
                        }
                    }
            }
            if horizontalSizeClass == .compact {
                Divider()
                SlideStrip(presentation: presentation, state: state, play: play) {
                    Group {
                        if document.presentation.isInMasterView {
                            Button {
                                state.leaveMasterView(in: &document.presentation)
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityIdentifier("closeMasterView")
                            .accessibilityLabel("MasterView.Close")
                        } else {
                            PlayMenu(play: play, current: { state.selectedIndex(in: document.presentation) }, customShows: document.presentation.customShows, playCustomShow: playCustomShow) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17))
                                    .frame(width: 44, height: 44)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                }
                .background(.bar)
            }
        }
        .background {
            ToolbarBottomSafeAreaReader { bottomToolbarInset = $0 }
        }
        .background(Color(.secondarySystemBackground))
        // Keyboard navigation belongs to the canvas, and only while no panel
        // or drawing is up — otherwise it holds focus away from them.
        .focusable(state.presentedPanel == nil && !state.isDrawing && state.editingTextShapeID == nil)
        .focusEffectDisabled()
        .onKeyPress(action: handleKeyPress)
        .toolbar { editorToolbar }
        .sheet(item: $state.presentedPanel) { panel in
            NavigationStack {
                panelContent(panel)
                    .navigationTitle(panel.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) { state.presentedPanel = nil }
                        }
                    }
            }
            .environment(\.playCustomShow) { playCustomShow($0) }
            .navigationTransition(.zoom(sourceID: panel, in: panelTransition))
            // Formatting panels stay at half height, so the slide they change
            // is always in view; export needs the room for its slide picker.
            .presentationDetents(panel == .export ? [.large] : ([.find, .chart, .comments, .headerFooter, .animations, .properties].contains(panel) ? [.medium, .large] : [.medium]))
            .presentationDragIndicator(.visible)
            // Swiping inside a panel scrolls its content rather than growing it.
            .presentationContentInteraction(.scrolls)
            .presentationBackground(.regularMaterial)
            // The slide stays live above a half-height panel, so changes can be
            // watched as they are made and another shape picked.
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: Binding(
            get: { horizontalSizeClass == .compact && state.isShowingUnsupportedFeatureNotice },
            set: { state.isShowingUnsupportedFeatureNotice = $0 }
        )) {
            UnsupportedFeatureNotice(report: document.presentation.unsupportedFeatures, fontSubstitutions: fontSubstitutions)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .fullScreenCover(isPresented: slideshowBinding, onDismiss: {
            restoreQuickPaste()
            if let id = session.lastShownSlideID, document.presentation.index(of: id) != nil { state.selectSlide(id) }
        }) {
            SlideshowView(session: session)
        }
        .alert(
            "Alert.Error.Title",
            isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("Common.OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .onAppear {
            state.reconcile(with: document.presentation)
            fontSubstitutions = document.presentation.fontSubstitutions
            attachHistory()
            offerToRemote()
        }
        .onDisappear { session.withdraw(editorID) }
        .onChange(of: undoManager) { _, _ in attachHistory() }
        .onChange(of: document.presentation) { old, new in
            if let undoneTo, undoneTo == new {
                self.undoneTo = nil
            } else if new.keynoteSource != nil, !KeynoteEditor.canSave(new) {
                // A Keynote document is saved into itself, so an edit Keynote
                // can't keep is taken back at once rather than left to fail
                // every save after it.
                undoneTo = old
                document.presentation = old
                state.errorMessage = String(localized: "Error.KeynoteChangeUndone")
                return
            } else {
                history.record(from: old, to: new)
            }
            state.reconcile(with: new)
            restoreQuickPaste()
            fontSubstitutions = new.fontSubstitutions
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                offerToRemote()
                restoreQuickPaste()
            }
        }
        .onChange(of: state.editingTextShapeID) { _, _ in restoreQuickPaste() }
        .onChange(of: state.isDrawing) { _, isDrawing in
            if isDrawing { state.presentedPanel = nil }
        }
    }

    // MARK: - Layout

    private var sidebar: some View {
        VStack(spacing: 0) {
            NewSlideMenu(presentation: presentation, state: state) {
                Label(document.presentation.isInMasterView ? "MasterView.NewLayout" : "Slide.New", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.vertical, 10)

            SlideNavigator(presentation: presentation, state: state, axis: .vertical, play: play)
        }
        .background(.bar)
    }

    /// Says the masters and layouts are what is being edited, at the top of
    /// the canvas, where the slide being edited would otherwise pass for one.
    private var masterViewBanner: some View {
        Label("MasterView.Title", systemImage: "rectangle.3.group")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 8)
            .accessibilityIdentifier("masterViewBanner")
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .text: TextPanel(presentation: presentation, state: state)
        case .format: FormatPanel(presentation: presentation, state: state)
        case .notes: NotesPanel(presentation: presentation, state: state)
        case .export: ExportPanel(presentation: document.presentation.outOfMasterView, state: state, name: name)
        case .find: FindPanel(presentation: presentation, state: state)
        case .chart: ChartPanel(presentation: presentation, state: state)
        case .animations: AnimationPanel(presentation: presentation, state: state)
        case .comments: CommentsPanel(presentation: presentation, state: state)
        case .headerFooter: HeaderFooterPanel(presentation: presentation, state: state)
        case .properties: PropertiesPanel(presentation: presentation, state: state)
        }
    }

    // MARK: - Slideshow

    private var slideshowBinding: Binding<Bool> {
        Binding(
            get: { session.isPresenting && session.ownerID == editorID },
            set: { if !$0 { session.end() } }
        )
    }

    private func play(from index: Int) {
        // The slideshow shows the slides, which master view has set aside.
        guard !session.isPresenting, !document.presentation.isInMasterView else { return }
        state.presentedPanel = nil
        state.isDrawing = false
        session.start(document.presentation, title: name, fromSlide: index, owner: editorID)
    }

    private func playCustomShow(_ id: CustomShow.ID) {
        guard !session.isPresenting else { return }
        state.presentedPanel = nil
        state.isDrawing = false
        session.start(document.presentation, title: name, fromSlide: 0, customShow: id, owner: editorID)
    }

    /// Lets the watch start this presentation, as the one most recently in front.
    private func offerToRemote() {
        session.offer(PresentationSession.Candidate(id: editorID, title: name) { [state] in
            play(from: state.selectedIndex(in: document.presentation))
        })
    }

    private func step(forward: Bool) {
        let slides = document.presentation.slides
        let index = state.selectedIndex(in: document.presentation) + (forward ? 1 : -1)
        guard slides.indices.contains(index) else { return }
        state.selectSlide(slides[index].id)
    }

    // MARK: - History

    private func attachHistory() {
        let document = $document
        let state = state
        history.attach(
            to: undoManager,
            read: { document.wrappedValue.presentation },
            write: { document.wrappedValue.presentation = $0 },
            restored: { state.reconcile(with: $0) }
        )
    }

    // MARK: - Toolbars

    /// Clipboard, history, Play, Find, then Share and "…", each its own group.
    /// An iPhone's bar holds three buttons, so there only history, Share and
    /// "…" are shown.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        quickPasteToolbar
        if horizontalSizeClass != .compact {
            clipboardToolbar
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        undoToolbar
        // On iPhone the bar has no room for it; it leads the slide strip instead.
        if horizontalSizeClass != .compact {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                if document.presentation.isInMasterView {
                    Button("MasterView.Close", systemImage: "checkmark") {
                        state.leaveMasterView(in: &document.presentation)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("closeMasterView")
                } else {
                    PlayMenu(play: play, current: { state.selectedIndex(in: document.presentation) }, customShows: document.presentation.customShows, playCustomShow: playCustomShow) {
                        Label("Toolbar.Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        presentationToolbar
    }

    /// Cut, copy and paste: the selected shapes, or with none, the slide.
    @ToolbarContentBuilder
    private var clipboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let hasSelection = !state.selectedShapeIDs.isEmpty
            Button(hasSelection ? "Edit.Cut" : "Edit.CutSlide", systemImage: "scissors") {
                state.cutSelection(in: &document.presentation)
            }
            .disabled(!hasSelection && document.presentation.slides.count < 2)
            .accessibilityIdentifier("cut")
            Button(hasSelection ? "Edit.Copy" : "Edit.CopySlide", systemImage: "doc.on.doc") {
                state.copySelection(in: document.presentation)
            }
            .accessibilityIdentifier("copy")
            Button("Edit.Paste", systemImage: "doc.on.clipboard") {
                state.paste(in: &document.presentation)
            }
            .accessibilityIdentifier("paste")
        }
    }

    /// A Paste button in the top-left corner, there only while something is
    /// waiting to be pasted, such as what was copied in another app. The
    /// slideshow covers it, so it needs no hiding there.
    ///
    /// The document's bar resets its leading items when the document is
    /// edited, text editing starts or ends, or the slideshow closes, and takes
    /// the button with it. SwiftUI only puts it back when the item changes, so
    /// `restoreQuickPaste()` flips it between two identical branches.
    @ToolbarContentBuilder
    private var quickPasteToolbar: some ToolbarContent {
        if let kind = pasteboard.kind {
            if quickPasteGeneration.isMultiple(of: 2) {
                ToolbarItem(placement: .topBarLeading) {
                    QuickPasteButton(kind: kind) { state.paste(in: &document.presentation) }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    QuickPasteButton(kind: kind) { state.paste(in: &document.presentation) }
                }
            }
        }
    }

    /// Puts the quick Paste button back once the bar has settled.
    private func restoreQuickPaste() {
        guard pasteboard.kind != nil else { return }
        // Several events often come together (a paste edits the document and
        // starts and ends text editing). Flipping once per event could land
        // back on the same branch, which SwiftUI wouldn't see as a change.
        quickPasteRestore?.cancel()
        quickPasteRestore = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            quickPasteGeneration &+= 1
        }
    }

    @ToolbarContentBuilder
    private var undoToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo")
            if horizontalSizeClass != .compact {
                redoButton
            }
        }
    }

    private var redoButton: some View {
        Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
            .disabled(!history.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("redo")
    }

    @ToolbarContentBuilder
    private var presentationToolbar: some ToolbarContent {
        // An iPhone's bar has no room for it; there it stays in "…".
        if horizontalSizeClass != .compact {
            ToolbarItem(placement: .primaryAction) {
                findButton
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // An iPhone's bar has no room for it either, so there it moves to the "…" menu.
            if hasNotice, horizontalSizeClass != .compact {
                Button {
                    state.isShowingUnsupportedFeatureNotice = true
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("unsupportedFeatures")
                .accessibilityLabel("Toolbar.UnsupportedFeatures")
                .popover(isPresented: $state.isShowingUnsupportedFeatureNotice) {
                    UnsupportedFeatureNotice(report: document.presentation.unsupportedFeatures, fontSubstitutions: fontSubstitutions)
                }
            }
            if !sharesInMoreMenu {
                shareMenu
            }
            moreMenu
        }
    }

    /// Whether there is anything for the warning button to tell.
    private var hasNotice: Bool {
        !document.presentation.unsupportedFeatures.isEmpty || !fontSubstitutions.isEmpty
    }

    private var findButton: some View {
        Button("Toolbar.Find", systemImage: "magnifyingglass") {
            state.endEditingText()
            state.presentedPanel = .find
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityIdentifier("find")
    }

    /// An iPhone's bar has no room for Share beside the quick Paste button,
    /// so while that shows, Share moves into "…".
    private var sharesInMoreMenu: Bool {
        horizontalSizeClass == .compact && pasteboard.kind != nil
    }

    private var shareMenu: some View {
        Menu {
            shareItems
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share")
        .accessibilityLabel("Toolbar.Share")
    }

    @ViewBuilder
    private var shareItems: some View {
        ShareLink(
            item: PresentationShare(presentation: document.presentation, name: name),
            preview: SharePreview(name, image: Image(systemName: "play.rectangle"))
        ) {
            Label("Share.Presentation", systemImage: "doc")
        }
        Button("Share.PDF", systemImage: "doc.richtext") {
            state.exportFormat = .pdf
            state.presentedPanel = .export
        }
        .accessibilityIdentifier("exportPDF")
        Button("Share.Images", systemImage: "photo.on.rectangle") {
            state.exportFormat = .images
            state.presentedPanel = .export
        }
        .accessibilityIdentifier("exportImages")
        Button("Share.Video", systemImage: "film") {
            state.exportFormat = .video
            state.presentedPanel = .export
        }
        .accessibilityIdentifier("exportVideo")
        Button("Share.Print", systemImage: "printer") {
            state.exportFormat = .pdf
            state.presentedPanel = .export
        }
        .keyboardShortcut("p", modifiers: .command)
        .accessibilityIdentifier("exportPrint")
    }

    /// The "…" menu. A menu of its own rather than `.secondaryAction`, which
    /// an iPad's document bar lays out inline instead of collapsing.
    private var moreMenu: some View {
        Menu {
            if sharesInMoreMenu {
                Menu {
                    shareItems
                } label: {
                    Label("Toolbar.Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share")
            }
            if horizontalSizeClass == .compact {
                redoButton
                if hasNotice {
                    Button("Toolbar.UnsupportedFeatures", systemImage: "exclamationmark.triangle") {
                        state.isShowingUnsupportedFeatureNotice = true
                    }
                    .accessibilityIdentifier("unsupportedFeatures")
                }
                findButton
            }
            if document.presentation.isInMasterView {
                Button("MasterView.Close", systemImage: "checkmark") {
                    state.leaveMasterView(in: &document.presentation)
                }
                .accessibilityIdentifier("closeMasterViewMenu")
            } else {
                Button("Toolbar.HeaderFooter", systemImage: "rectangle.bottomthird.inset.filled") {
                    state.endEditingText()
                    state.presentedPanel = .headerFooter
                }
                .accessibilityIdentifier("headerFooter")
                if document.presentation.canEditMasters {
                    Button("Toolbar.EditMasters", systemImage: "rectangle.3.group") {
                        state.endEditingText()
                        state.enterMasterView(in: &document.presentation)
                    }
                    .accessibilityIdentifier("editMasters")
                }
            }
            Button("Toolbar.Properties", systemImage: "info.circle") {
                state.endEditingText()
                state.presentedPanel = .properties
            }
            .accessibilityIdentifier("properties")
            Section {
                Link(destination: URL(string: "https://github.com/AtelierSuite/Dazzle")!) {
                    Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityIdentifier("more")
        .accessibilityLabel("Toolbar.More")
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "c":
                state.copySelection(in: document.presentation)
                return .handled
            case "x":
                state.cutSelection(in: &document.presentation)
                return .handled
            case "v":
                state.paste(in: &document.presentation)
                return .handled
            default:
                break
            }
        }
        let nudge = press.modifiers.contains(.shift) ? 10.0 : 1.0
        if let shape = state.selectedShape(in: document.presentation) {
            var offset = CGSize.zero
            switch press.key {
            case .delete, .deleteForward:
                state.deleteSelectedShape(in: &document.presentation)
                return .handled
            case .escape:
                state.selectedShapeID = nil
                return .handled
            case .return where shape.canHoldText && shape.isEditable:
                state.beginEditingText(shape.id)
                return .handled
            case .upArrow: offset.height = -nudge
            case .downArrow: offset.height = nudge
            case .leftArrow: offset.width = -nudge
            case .rightArrow: offset.width = nudge
            default:
                if press.modifiers.contains(.command), press.characters.lowercased() == "d" {
                    state.duplicateSelectedShape(in: &document.presentation)
                    return .handled
                }
                if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
                    state.selectAllShapes(in: document.presentation)
                    return .handled
                }
                if press.modifiers.contains(.command), press.characters.lowercased() == "g" {
                    if press.modifiers.contains(.shift) {
                        state.ungroupSelectedShape(in: &document.presentation)
                    } else {
                        state.groupSelectedShapes(in: &document.presentation)
                    }
                    return .handled
                }
                return .ignored
            }
            guard shape.isEditable else { return .handled }
            let frames = Dictionary(uniqueKeysWithValues: state.selectedShapes(in: document.presentation).map {
                ($0.id, $0.frame.points.offsetBy(dx: offset.width, dy: offset.height))
            })
            state.setFrames(frames, in: &document.presentation)
            return .handled
        }
        if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
            state.selectAllShapes(in: document.presentation)
            return .handled
        }
        switch press.key {
        case .upArrow, .leftArrow, .pageUp:
            step(forward: false)
        case .downArrow, .rightArrow, .pageDown:
            step(forward: true)
        default:
            return .ignored
        }
        return .handled
    }
}

/// Play, from the slide being edited; held, from the beginning or a custom show instead.
private struct PlayMenu<Label: View>: View {
    let play: (Int) -> Void
    let current: () -> Int
    var customShows: [CustomShow] = []
    var playCustomShow: (CustomShow.ID) -> Void = { _ in }
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button("Toolbar.PlayFromStart", systemImage: "backward.end") { play(0) }
            Button("Toolbar.PlayFromCurrent", systemImage: "play") { play(current()) }
            if !customShows.isEmpty {
                Menu("Toolbar.PlayCustomShow", systemImage: "list.bullet.rectangle") {
                    ForEach(customShows) { show in
                        Button(show.name) { playCustomShow(show.id) }
                    }
                }
            }
        } label: {
            label()
        } primaryAction: {
            play(current())
        }
        .keyboardShortcut(.return, modifiers: [.command, .option])
        .accessibilityIdentifier("play")
        .accessibilityLabel("Toolbar.Play")
    }
}

/// What the toolbar's warning button says: which parts of the file Dazzle
/// keeps but cannot show or use, and which fonts it draws in others.
///
/// A popover rather than an alert: nothing here needs deciding, so it has no
/// business stopping the user before they have seen their slides.
private struct UnsupportedFeatureNotice: View {
    var report: UnsupportedFeatureReport
    var fontSubstitutions: [FontSubstitution]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.isEmpty ? "Notice.Fonts.Title" : "Notice.UnsupportedFeatures.Title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            if !report.omissions.isEmpty {
                message("Notice.Omitted.Intro", report.omissionMessage)
            }
            if !report.features.isEmpty {
                message("Notice.UnsupportedFeatures.Intro", report.noticeMessage)
            }
            if !fontSubstitutions.isEmpty {
                message("Notice.Fonts.Intro", fontSubstitutions.noticeMessage)
                    .accessibilityIdentifier("fontSubstitutions")
            }
        }
        .multilineTextAlignment(.leading)
        .padding(20)
        .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
        // iPhone turns a popover into a sheet unless it is told not to.
        .presentationCompactAdaptation(.popover)
    }

    private func message(_ intro: LocalizedStringKey, _ list: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(intro)
            Text(list)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        // A popover sizes itself to its content, and without this the
        // message is laid out on one unbroken line.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToolbarBottomSafeAreaReader: UIViewRepresentable {
    let insetChanged: (CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.insetChanged = insetChanged
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.insetChanged = insetChanged
        view.setNeedsLayout()
    }

    final class ObserverView: UIView {
        var insetChanged: ((CGFloat) -> Void)?
        private var lastInset: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let frameInWindow = convert(bounds, to: window)
            let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
            let inset = max(0, frameInWindow.maxY - safeBottom)
            guard lastInset != inset else { return }
            lastInset = inset
            let insetChanged = insetChanged
            DispatchQueue.main.async { insetChanged?(inset) }
        }
    }
}
