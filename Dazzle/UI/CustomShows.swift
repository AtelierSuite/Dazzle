import DazzleEngine
import SwiftUI

extension EnvironmentValues {
    /// Starts the slideshow playing a custom show, from the editor showing it.
    @Entry var playCustomShow: ((CustomShow.ID) -> Void)?
}

/// The presentation's custom shows: making, renaming and removing them.
struct CustomShowsView: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    @Environment(\.playCustomShow) private var play
    /// A show just made, opened for choosing its slides.
    @State private var made: CustomShow.ID?

    var body: some View {
        List {
            Section {
                ForEach(presentation.customShows) { show in
                    NavigationLink(value: show.id) {
                        LabeledContent(show.name) {
                            Text(String(format: String(localized: "CustomShow.SlideCount"), livingSlides(of: show)))
                        }
                    }
                    .contextMenu {
                        if let play {
                            Button("CustomShow.Play", systemImage: "play") { play(show.id) }
                        }
                        Button("CustomShow.Duplicate", systemImage: "plus.square.on.square") {
                            state.duplicateCustomShow(show.id, in: &presentation)
                        }
                        Button("CustomShow.Delete", systemImage: "trash", role: .destructive) {
                            state.deleteCustomShow(show.id, in: &presentation)
                        }
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ presentation.customShows[$0].id }) {
                        state.deleteCustomShow(id, in: &presentation)
                    }
                }
                Button("CustomShow.New", systemImage: "plus") {
                    // A new show starts with the slide being edited.
                    let first = state.selectedSlide(in: presentation).map { [$0.id] } ?? []
                    made = state.addCustomShow(slides: first, in: &presentation)
                }
                .accessibilityIdentifier("newCustomShow")
            } footer: {
                Text("CustomShow.Footer")
            }
        }
        .navigationTitle("CustomShow.Title")
        .navigationDestination(for: CustomShow.ID.self) { id in
            CustomShowEditor(presentation: $presentation, state: state, id: id)
        }
        .navigationDestination(item: $made) { id in
            CustomShowEditor(presentation: $presentation, state: state, id: id)
        }
    }

    private func livingSlides(of show: CustomShow) -> Int {
        show.slideIDs.filter { presentation.index(of: $0) != nil }.count
    }
}

/// One custom show: its name, and which slides it plays in what order.
struct CustomShowEditor: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    let id: CustomShow.ID

    @Environment(\.playCustomShow) private var play

    private var show: CustomShow? { presentation.customShow(withID: id) }
    /// The show's slides still in the presentation, each with its place in it.
    private var included: [(offset: Int, slide: Slide, index: Int)] {
        (show?.slideIDs ?? []).compactMap { presentation.index(of: $0) }.enumerated().map {
            (offset: $0.offset, slide: presentation.slides[$0.element], index: $0.element)
        }
    }

    var body: some View {
        Form {
            if let show {
                Section("CustomShow.Name") {
                    CommitTextField("CustomShow.Name", text: show.name) { name in
                        state.renameCustomShow(id, to: name, in: &presentation)
                    }
                    .accessibilityIdentifier("customShowName")
                }
                Section {
                    if included.isEmpty {
                        Text("CustomShow.Empty").foregroundStyle(.secondary)
                    }
                    ForEach(included, id: \.offset) { entry in
                        row(entry.slide, number: entry.index + 1)
                    }
                    .onMove { offsets, destination in
                        var slides = included.map(\.slide.id)
                        slides.move(fromOffsets: offsets, toOffset: destination)
                        state.setCustomShowSlides(id, to: slides, in: &presentation)
                    }
                    .onDelete { offsets in
                        var slides = included.map(\.slide.id)
                        slides.remove(atOffsets: offsets)
                        state.setCustomShowSlides(id, to: slides, in: &presentation)
                    }
                } header: {
                    Text("CustomShow.InShow")
                } footer: {
                    Text("CustomShow.InShow.Footer")
                }
                Section("CustomShow.AllSlides") {
                    ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
                        let isIncluded = show.slideIDs.contains(slide.id)
                        Button {
                            state.toggleSlide(slide.id, inCustomShow: id, in: &presentation)
                        } label: {
                            HStack {
                                row(slide, number: index + 1)
                                Spacer()
                                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isIncluded ? Color.accentColor : .secondary)
                                    .font(.title3)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isIncluded ? .isSelected : [])
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(show?.name ?? "")
        .toolbar {
            if let play {
                ToolbarItem(placement: .primaryAction) {
                    Button("CustomShow.Play", systemImage: "play.fill") { play(id) }
                        .disabled(included.isEmpty)
                        .accessibilityIdentifier("playCustomShow")
                }
            }
        }
    }

    private func row(_ slide: Slide, number: Int) -> some View {
        HStack(spacing: 12) {
            SlideThumbnail(presentation: presentation, slide: slide, number: number, isSelected: false)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(number)").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: slide.title ?? String(localized: "Slide.Untitled")).lineLimit(2)
            }
        }
    }
}
