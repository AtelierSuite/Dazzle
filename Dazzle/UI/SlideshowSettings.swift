import DazzleEngine
import SwiftUI

/// How every slideshow of the presentation plays: which slides, whether it
/// loops or runs as a kiosk, and whether timings, animations and
/// narrations play.
struct SlideshowSettingsView: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var settings: SlideshowSettings { presentation.showSettings }

    private enum RangeKind: Hashable {
        case all
        case slides
        case customShow
    }

    private var rangeKind: RangeKind {
        switch settings.range {
        case .all: .all
        case .slides: .slides
        case .customShow: .customShow
        }
    }

    private func update(_ change: @escaping (inout SlideshowSettings) -> Void) {
        state.updateShowSettings(in: &presentation, change)
    }

    var body: some View {
        Form {
            Section("Show.Range") {
                Picker("Show.Range", selection: Binding(get: { rangeKind }, set: chooseRange)) {
                    Text("Show.Range.All").tag(RangeKind.all)
                    Text("Show.Range.Slides").tag(RangeKind.slides)
                    if !presentation.customShows.isEmpty || rangeKind == .customShow {
                        Text("Show.Range.CustomShow").tag(RangeKind.customShow)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("showRange")
                if case .slides(let from, let to) = settings.range {
                    let count = max(presentation.slides.count, 1)
                    Stepper(value: Binding(get: { from }, set: { value in update { $0.range = .slides(from: value, to: max(value, to)) } }),
                            in: 1...count) {
                        LabeledContent("Show.From", value: "\(from)")
                    }
                    .accessibilityIdentifier("showFrom")
                    Stepper(value: Binding(get: { to }, set: { value in update { $0.range = .slides(from: min(from, value), to: value) } }),
                            in: 1...count) {
                        LabeledContent("Show.To", value: "\(to)")
                    }
                    .accessibilityIdentifier("showTo")
                }
                if case .customShow(let id) = settings.range {
                    Picker("Show.Range.CustomShow", selection: Binding(get: { id }, set: { value in update { $0.range = .customShow(value) } })) {
                        ForEach(presentation.customShows) { show in
                            Text(verbatim: show.name).tag(show.id)
                        }
                        if presentation.customShow(withID: id) == nil {
                            Text("Link.CustomShow.Missing").tag(id)
                        }
                    }
                    .accessibilityIdentifier("showCustomShow")
                }
            }

            Section {
                Toggle("Show.Kiosk", isOn: Binding(get: { settings.isKiosk }, set: { value in update { $0.isKiosk = value } }))
                    .accessibilityIdentifier("showKiosk")
                if settings.isKiosk {
                    Stepper(
                        value: Binding(
                            get: { settings.kioskRestartAfter / 60 },
                            set: { value in update { $0.kioskRestartAfter = max(value, 1) * 60 } }
                        ),
                        in: 1...60, step: 1
                    ) {
                        LabeledContent("Show.KioskRestart") {
                            Text((settings.kioskRestartAfter / 60).formatted(.number.precision(.fractionLength(0...1)))
                                + " " + String(localized: "Show.Minutes"))
                                .monospacedDigit()
                        }
                    }
                }
            } footer: {
                Text("Show.Kiosk.Footer")
            }

            Section {
                Toggle("Format.LoopSlideshow", isOn: Binding(
                    get: { settings.loops || settings.isKiosk },
                    set: { state.setLoopsSlideshow($0, in: &presentation) }
                ))
                .disabled(settings.isKiosk)
                .accessibilityIdentifier("loopSlideshow")
                Toggle("Show.UseTimings", isOn: Binding(
                    get: { settings.usesTimings || settings.isKiosk },
                    set: { value in update { $0.usesTimings = value } }
                ))
                .disabled(settings.isKiosk)
                .accessibilityIdentifier("showUseTimings")
                Toggle("Show.ShowAnimations", isOn: Binding(
                    get: { settings.showsAnimations }, set: { value in update { $0.showsAnimations = value } }
                ))
                .accessibilityIdentifier("showAnimations")
                Toggle("Show.PlayNarration", isOn: Binding(
                    get: { settings.playsNarration }, set: { value in update { $0.playsNarration = value } }
                ))
                .accessibilityIdentifier("showNarration")
            } footer: {
                Text("Show.Footer")
            }
        }
        .navigationTitle("Show.Title")
    }

    private func chooseRange(_ kind: RangeKind) {
        let range: SlideshowSettings.Range = switch kind {
        case .all: .all
        case .slides: .slides(from: 1, to: max(presentation.slides.count, 1))
        case .customShow: presentation.customShows.first.map { .customShow($0.id) } ?? .all
        }
        update { $0.range = range }
    }
}
