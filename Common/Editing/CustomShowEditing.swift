import DazzleEngine
import Foundation

/// Making, renaming and choosing the slides of custom shows.
extension EditorState {
    /// Adds a custom show of the slides given, named after the next free
    /// "Custom Show n", and returns its id.
    @discardableResult
    func addCustomShow(slides: [Slide.ID] = [], in presentation: inout Presentation) -> CustomShow.ID {
        let id = presentation.unusedCustomShowID
        let names = Set(presentation.customShows.map(\.name))
        let name = (1...).lazy.map { String(format: String(localized: "CustomShow.DefaultName"), $0) }.first { !names.contains($0) }!
        presentation.customShows.append(CustomShow(id: id, name: name, slideIDs: slides))
        presentation.areCustomShowsModified = true
        return id
    }

    func renameCustomShow(_ id: CustomShow.ID, to name: String, in presentation: inout Presentation) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateCustomShow(id, in: &presentation) { $0.name = name }
    }

    func setCustomShowSlides(_ id: CustomShow.ID, to slides: [Slide.ID], in presentation: inout Presentation) {
        updateCustomShow(id, in: &presentation) { $0.slideIDs = slides }
    }

    /// Adds a slide to the end of a show, or takes every appearance of it out.
    func toggleSlide(_ slide: Slide.ID, inCustomShow id: CustomShow.ID, in presentation: inout Presentation) {
        updateCustomShow(id, in: &presentation) { show in
            if show.slideIDs.contains(slide) {
                show.slideIDs.removeAll { $0 == slide }
            } else {
                show.slideIDs.append(slide)
            }
        }
    }

    func duplicateCustomShow(_ id: CustomShow.ID, in presentation: inout Presentation) {
        guard let show = presentation.customShow(withID: id) else { return }
        let copy = addCustomShow(slides: show.slideIDs, in: &presentation)
        renameCustomShow(copy, to: String(format: String(localized: "CustomShow.CopyName"), show.name), in: &presentation)
    }

    func deleteCustomShow(_ id: CustomShow.ID, in presentation: inout Presentation) {
        presentation.customShows.removeAll { $0.id == id }
        presentation.areCustomShowsModified = true
        // A slideshow set to play the show plays every slide again.
        if presentation.showSettings.range == .customShow(id) {
            updateShowSettings(in: &presentation) { $0.range = .all }
        }
    }

    private func updateCustomShow(_ id: CustomShow.ID, in presentation: inout Presentation, _ change: (inout CustomShow) -> Void) {
        guard let index = presentation.customShows.firstIndex(where: { $0.id == id }) else { return }
        change(&presentation.customShows[index])
        presentation.areCustomShowsModified = true
    }
}
