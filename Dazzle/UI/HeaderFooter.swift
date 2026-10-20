import DazzleEngine
import SwiftUI

/// Header & Footer: what goes along the bottom of the slides.
struct HeaderFooterPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    @State private var settings = HeaderFooterSettings()

    var body: some View {
        Form {
            Section {
                Toggle("HeaderFooter.Date", isOn: $settings.showsDate)
                    .accessibilityIdentifier("showDate")
                if settings.showsDate {
                    Picker("HeaderFooter.DateKind", selection: $settings.updatesDate) {
                        Text("HeaderFooter.Automatic").tag(true)
                        Text("HeaderFooter.Fixed").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if settings.updatesDate {
                        Picker("HeaderFooter.Format", selection: $settings.dateFormat) {
                            ForEach(DateField.allCases) { format in
                                Text(verbatim: format.string(for: Date())).tag(format)
                            }
                        }
                    } else {
                        TextField("HeaderFooter.FixedDate", text: $settings.fixedDate)
                    }
                }
            }
            Section {
                Toggle("HeaderFooter.SlideNumber", isOn: $settings.showsSlideNumber)
                    .accessibilityIdentifier("showSlideNumber")
                Toggle("HeaderFooter.Footer", isOn: $settings.showsFooter)
                    .accessibilityIdentifier("showFooter")
                if settings.showsFooter {
                    TextField("HeaderFooter.FooterText", text: $settings.footer)
                        .accessibilityIdentifier("footerText")
                }
            }
            Section {
                Toggle("HeaderFooter.HideOnTitle", isOn: $settings.hidesOnTitleSlide)
            } footer: {
                Text("HeaderFooter.Footer.Note")
            }
            Section {
                Button("HeaderFooter.ApplyToAll") {
                    state.applyHeaderFooter(settings, toAll: true, in: &presentation)
                    state.presentedPanel = nil
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("applyToAll")
                Button("HeaderFooter.Apply") {
                    state.applyHeaderFooter(settings, toAll: false, in: &presentation)
                    state.presentedPanel = nil
                }
                .accessibilityIdentifier("applyToSlide")
            }
        }
        .onAppear { settings = state.headerFooter(in: presentation) }
    }
}
