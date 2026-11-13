import DazzleEngine
import SwiftUI

/// The slides in order: a sidebar of thumbnails where there is room, a
/// strip along the bottom where there is not. Tap to go to a slide, drag
/// to reorder, press and hold for what else can be done to it. Slides in
/// sections are grouped under each section's name, which folds them away.
struct SlideNavigator: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    var axis: Axis
    var play: (Int) -> Void

    @State private var dropTargetID: Slide.ID?
    /// The layout being renamed, and the name typed for it so far.
    @State private var renamingID: Slide.ID?
    @State private var newName = ""
    @State private var dropTargetSectionID: SlideSection.ID?
    /// Sections whose slides are folded away.
    @State private var collapsedSectionIDs: Set<SlideSection.ID> = []
    @State private var renamingSectionID: SlideSection.ID?
    @State private var sectionName = ""

    /// What the navigator lists: section headers, and the slides of each
    /// section that is open.
    private enum Row: Identifiable {
        case section(SlideSection)
        case slide(Slide, index: Int)

        var id: String {
            switch self {
            case .section(let section): "section." + section.id
            case .slide(let slide, _): slide.id.uuidString
            }
        }
    }

    private var rows: [Row] {
        let slides = Array(presentation.slides.enumerated())
        guard !presentation.sections.isEmpty, !presentation.isInMasterView else { return slides.map { .slide($1, index: $0) } }
        let indices = Dictionary(slides.map { ($1.id, $0) }) { first, _ in first }
        return presentation.sections.flatMap { section -> [Row] in
            let members: [Row] = collapsedSectionIDs.contains(section.id) ? [] : section.slideIDs.compactMap { id in
                indices[id].map { .slide(presentation.slides[$0], index: $0) }
            }
            return [.section(section)] + members
        }
    }

    /// How far in from the strip's ends thumbnails blur: no further than its
    /// buttons reach, so as many thumbnails as fit stay sharp.
    private static let edgeFade: CGFloat = 40
    private static let edgeBlurRadius: CGFloat = 8
    /// Where the first and last thumbnails rest: clear of the strip's buttons.
    private static let edgeInset: CGFloat = 60

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axis == .vertical ? .vertical : .horizontal) {
                stack
                    .padding(axis == .vertical ? EdgeInsets(top: 4, leading: 12, bottom: 96, trailing: 12)
                             : EdgeInsets(top: 8, leading: Self.edgeInset, bottom: 8, trailing: Self.edgeInset))
                    .animation(.snappy(duration: 0.22), value: presentation.slides.map(\.id))
            }
            .scrollIndicators(.hidden)
            // Blurred thumbnails show through beneath the strip's buttons
            // rather than being cut off at its bounds.
            .scrollClipDisabled(axis == .horizontal)
            .onChange(of: state.selectedSlideID) { _, id in
                guard let id else { return }
                // A slide picked from elsewhere shows, even in a folded section.
                if let section = presentation.section(of: id), collapsedSectionIDs.contains(section.id) {
                    collapsedSectionIDs.remove(section.id)
                }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .alert("MasterView.Rename.Title", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("MasterView.LayoutName", text: $newName)
                .accessibilityIdentifier("layoutNameField")
            Button("Common.Cancel", role: .cancel) { renamingID = nil }
            Button("MasterView.Rename.Confirm") {
                if let renamingID { state.renameLayout(renamingID, to: newName, in: &presentation) }
                renamingID = nil
            }
        }
        .alert("Section.Rename", isPresented: Binding(
            get: { renamingSectionID != nil }, set: { if !$0 { renamingSectionID = nil } }
        )) {
            TextField("Section.Name", text: $sectionName)
                .accessibilityIdentifier("sectionNameField")
            Button("Common.Cancel", role: .cancel) { renamingSectionID = nil }
            Button("Section.Rename.Confirm") {
                if let id = renamingSectionID { state.renameSection(id, to: sectionName, in: &presentation) }
                renamingSectionID = nil
            }
        }
    }

    private func rename(_ section: SlideSection) {
        sectionName = section.name
        renamingSectionID = section.id
    }

    /// Starts a section at a slide, and offers to name it straight away.
    private func addSection(at slide: Slide) {
        state.selectSlide(slide.id)
        withAnimation(.snappy(duration: 0.22)) {
            if let id = state.addSection(in: &presentation),
               let section = presentation.sections.first(where: { $0.id == id }) {
                rename(section)
            }
        }
    }

    /// Blur that deepens point by point toward either end of the strip, so a
    /// thumbnail only softens where it has slid under a button.
    nonisolated private static func edgeBlur(for proxy: GeometryProxy) -> Shader {
        // The visible strip, in the thumbnail's own coordinates.
        let visible = proxy.bounds(of: .scrollView) ?? CGRect(origin: .zero, size: proxy.size)
        return ShaderLibrary.edgeBlur(
            .float(visible.minX), .float(visible.maxX), .float(edgeFade), .float(edgeBlurRadius)
        )
    }

    @ViewBuilder
    private var stack: some View {
        let items = ForEach(rows) { row in
            switch row {
            case .section(let section):
                header(for: section)
            case .slide(let slide, let index):
                item(for: slide, at: index)
                    .id(slide.id)
            }
        }
        if axis == .vertical {
            LazyVStack(spacing: 14) { items }
        } else {
            LazyHStack(spacing: 8) { items }
        }
    }

    private func item(for slide: Slide, at index: Int) -> some View {
        let isSelected = slide.id == state.selectedSlideID
        let thumbnail = SlideThumbnail(presentation: presentation, slide: slide, number: index + 1, isSelected: isSelected)
        return Group {
            if presentation.isInMasterView {
                templateItem(for: slide, thumbnail: thumbnail, isSelected: isSelected)
            } else if axis == .vertical {
                HStack(alignment: .top, spacing: 6) {
                    Text(String(index + 1))
                        .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: 22, alignment: .trailing)
                    thumbnail
                }
            } else {
                thumbnail.frame(height: 52)
                    .visualEffect { content, proxy in
                        content.layerEffect(Self.edgeBlur(for: proxy), maxSampleOffset: CGSize(width: Self.edgeBlurRadius, height: Self.edgeBlurRadius))
                    }
            }
        }
        .overlay {
            // The slide a dragged slide will take the place of.
            if dropTargetID == slide.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .padding(-4)
            }
        }
        .contentShape(.rect)
        .onTapGesture { state.selectSlide(slide.id) }
        .contextMenu { menu(for: slide, at: index) }
        .draggable(slide.id.uuidString) {
            SlideThumbnail(presentation: presentation, slide: slide, number: index + 1, isSelected: true)
                .frame(width: 160)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetID = nil
            guard let raw = items.first, let id = UUID(uuidString: raw), id != slide.id,
                  let target = presentation.index(of: slide.id) else { return false }
            withAnimation(.snappy(duration: 0.22)) {
                state.moveSlide(id, to: target, in: &presentation)
            }
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetID = slide.id
            } else if dropTargetID == slide.id {
                dropTargetID = nil
            }
        }
        .accessibilityIdentifier("slideThumbnail.\(index + 1)")
    }

    // MARK: - Sections

    private func header(for section: SlideSection) -> some View {
        let isCollapsed = collapsedSectionIDs.contains(section.id)
        let toggle = {
            withAnimation(.snappy(duration: 0.22)) {
                if isCollapsed { collapsedSectionIDs.remove(section.id) } else { collapsedSectionIDs.insert(section.id) }
            }
        }
        return Group {
            if axis == .vertical {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 22, alignment: .trailing)
                    Text(section.name.isEmpty ? SlideSection.untitledName : section.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(section.slideIDs.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else {
                VStack(spacing: 2) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text(section.name.isEmpty ? SlideSection.untitledName : section.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 56, height: 52)
                .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
        .overlay {
            // A dragged slide moves into the section.
            if dropTargetSectionID == section.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .padding(-4)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .contextMenu { menu(for: section) }
        .draggable("section:" + section.id) {
            Label(section.name, systemImage: "rectangle.stack")
                .padding(8)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetSectionID = nil
            guard let raw = items.first else { return false }
            withAnimation(.snappy(duration: 0.22)) {
                if raw.hasPrefix("section:") {
                    let moving = String(raw.dropFirst("section:".count))
                    if let target = presentation.sectionIndex(of: section.id), moving != section.id {
                        state.moveSection(moving, to: target, in: &presentation)
                    }
                } else if let id = UUID(uuidString: raw) {
                    state.moveSlides([id], toSection: section.id, in: &presentation)
                }
            }
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetSectionID = section.id
            } else if dropTargetSectionID == section.id {
                dropTargetSectionID = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isCollapsed ? Text("Section.Collapsed") : Text("Section.Expanded"))
        .accessibilityIdentifier("sectionHeader.\(section.name)")
    }

    @ViewBuilder
    private func menu(for section: SlideSection) -> some View {
        let index = presentation.sectionIndex(of: section.id) ?? 0
        Button("Section.Rename", systemImage: "pencil") { rename(section) }
        Section {
            Button("Section.MoveUp", systemImage: axis == .vertical ? "arrow.up" : "arrow.left") {
                withAnimation(.snappy(duration: 0.22)) { state.moveSection(section.id, to: index - 1, in: &presentation) }
            }
            .disabled(index == 0)
            Button("Section.MoveDown", systemImage: axis == .vertical ? "arrow.down" : "arrow.right") {
                withAnimation(.snappy(duration: 0.22)) { state.moveSection(section.id, to: index + 1, in: &presentation) }
            }
            .disabled(index == presentation.sections.count - 1)
        }
        Section {
            Button("Section.Remove", systemImage: "minus.square") {
                withAnimation(.snappy(duration: 0.22)) { state.removeSection(section.id, in: &presentation) }
            }
            Button("Section.RemoveAll", systemImage: "rectangle.stack.badge.minus") {
                withAnimation(.snappy(duration: 0.22)) { state.removeAllSections(in: &presentation) }
            }
        }
    }

    @ViewBuilder
    private func sectionMenu(for slide: Slide) -> some View {
        Button("Section.Add", systemImage: "rectangle.stack.badge.plus") { addSection(at: slide) }
        if presentation.sections.count > 1 {
            let current = presentation.section(of: slide.id)?.id
            Menu("Section.MoveSlideTo", systemImage: "arrow.right.square") {
                ForEach(presentation.sections) { section in
                    Button(section.name.isEmpty ? SlideSection.untitledName : section.name) {
                        withAnimation(.snappy(duration: 0.22)) {
                            state.moveSlides([slide.id], toSection: section.id, in: &presentation)
                        }
                    }
                    .disabled(section.id == current)
                }
            }
        }
    }

    /// A master or layout in master view: a master at full width, its
    /// layouts set in beneath it, each with its name.
    @ViewBuilder
    private func templateItem(for slide: Slide, thumbnail: SlideThumbnail, isSelected: Bool) -> some View {
        let name = slide.role == .master ? String(localized: "MasterView.Master") : slide.layoutName ?? ""
        if axis == .vertical {
            VStack(alignment: .leading, spacing: 4) {
                thumbnail
                Text(name)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .padding(.leading, slide.role == .master ? 0 : 28)
        } else {
            thumbnail.frame(height: slide.role == .master ? 52 : 44)
                .visualEffect { content, proxy in
                    content.layerEffect(Self.edgeBlur(for: proxy), maxSampleOffset: CGSize(width: Self.edgeBlurRadius, height: Self.edgeBlurRadius))
                }
        }
    }

    /// What can be done to a master or layout: a layout can be renamed,
    /// copied, and deleted once no slide is built on it.
    @ViewBuilder
    private func templateMenu(for slide: Slide) -> some View {
        if slide.role == .master {
            Button("MasterView.NewLayout", systemImage: "plus") {
                state.selectSlide(slide.id)
                state.addLayout(in: &presentation)
            }
        } else {
            Button("MasterView.Rename", systemImage: "pencil") {
                newName = slide.layoutName ?? ""
                renamingID = slide.id
            }
            Button("MasterView.Duplicate", systemImage: "plus.square.on.square") {
                state.duplicateSlide(slide.id, in: &presentation)
            }
            Section {
                Button("MasterView.Delete", systemImage: "trash", role: .destructive) {
                    state.deleteSlide(slide.id, in: &presentation)
                }
                .disabled(!state.canDeleteLayout(slide.id, in: presentation))
            }
        }
    }

    @ViewBuilder
    private func menu(for slide: Slide, at index: Int) -> some View {
        if presentation.isInMasterView {
            templateMenu(for: slide)
        } else {
            slideMenu(for: slide, at: index)
        }
    }

    @ViewBuilder
    private func slideMenu(for slide: Slide, at index: Int) -> some View {
        Button("Slide.Menu.Play", systemImage: "play") { play(index) }
        Button("Slide.Menu.Duplicate", systemImage: "plus.square.on.square") {
            state.duplicateSlide(slide.id, in: &presentation)
        }
        Section {
            Button("Edit.Copy", systemImage: "doc.on.doc") {
                state.copySlides([slide.id], in: presentation)
            }
            Button("Edit.Cut", systemImage: "scissors") {
                state.cutSlide(slide.id, in: &presentation)
            }
            .disabled(presentation.slides.count < 2)
            Button("Edit.PasteAfter", systemImage: "doc.on.clipboard") {
                state.selectSlide(slide.id)
                state.paste(in: &presentation)
            }
        }
        Button(slide.isHidden ? "Slide.Menu.Show" : "Slide.Menu.Hide", systemImage: slide.isHidden ? "eye" : "eye.slash") {
            state.toggleHidden(slide.id, in: &presentation)
        }
        Section { sectionMenu(for: slide) }
        Section {
            Button("Slide.Menu.MoveUp", systemImage: axis == .vertical ? "arrow.up" : "arrow.left") {
                state.moveSlide(slide.id, to: index - 1, in: &presentation)
            }
            .disabled(index == 0)
            Button("Slide.Menu.MoveDown", systemImage: axis == .vertical ? "arrow.down" : "arrow.right") {
                state.moveSlide(slide.id, to: index + 1, in: &presentation)
            }
            .disabled(index == presentation.slides.count - 1)
        }
        Section {
            Button("Slide.Menu.Delete", systemImage: "trash", role: .destructive) {
                state.deleteSlide(slide.id, in: &presentation)
            }
            .disabled(presentation.slides.count < 2)
        }
    }
}

/// New Slide: picks one of the presentation's layouts. In master view,
/// adds a layout instead.
struct NewSlideMenu<Label: View>: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    @ViewBuilder var label: () -> Label

    var body: some View {
        if presentation.isInMasterView {
            Button {
                state.addLayout(in: &presentation)
            } label: {
                label()
            }
            .accessibilityIdentifier("newLayout")
            .accessibilityLabel("MasterView.NewLayout")
        } else {
            slideMenu
        }
    }

    private var slideMenu: some View {
        Menu {
            ForEach(presentation.resources.orderedLayouts, id: \.path) { layout in
                Button(layout.name) { state.addSlide(using: layout, in: &presentation) }
            }
        } label: {
            label()
        }
        .accessibilityIdentifier("newSlide")
        .accessibilityLabel("Slide.New")
    }
}

/// The iPhone's strip of slides along the bottom, Tables' sheet tabs'
/// counterpart: the thumbnails, flowing beneath a glass add button at one
/// end and the trailing controls at the other.
struct SlideStrip<Trailing: View>: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    var play: (Int) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SlideNavigator(presentation: $presentation, state: state, axis: .horizontal, play: play)
            .overlay(alignment: .leading) {
                NewSlideMenu(presentation: $presentation, state: state) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.leading, 12)
            }
            .overlay(alignment: .trailing) {
                trailing()
                    .padding(.trailing, 12)
            }
            .frame(height: 68)
    }
}
