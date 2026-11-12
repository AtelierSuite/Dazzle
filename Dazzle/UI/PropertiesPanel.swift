import DazzleEngine
import SwiftUI

/// Properties: what the presentation says about itself, from its title and
/// author to when it was last saved, and by whom.
struct PropertiesPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    /// Who saving says saved the file last, shared with comments.
    @AppStorage("commentAuthorName") private var authorName = ""

    var body: some View {
        Form {
            Section {
                field(.title, "Properties.Title")
                field(.subject, "Properties.Subject")
                field(.author, "Properties.Author")
                field(.company, "Properties.Company")
            }
            Section {
                field(.keywords, "Properties.Keywords")
                field(.category, "Properties.Category")
            }
            Section("Properties.Comments") {
                TextField("Properties.Comments", text: binding(.comments), axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
                    .accessibilityIdentifier("property.comments")
            }
            Section("Properties.Section.History") {
                LabeledContent("Properties.Created", value: date(properties.created))
                LabeledContent("Properties.Modified", value: date(properties.modified))
                LabeledContent("Properties.LastModifiedBy", value: properties.lastModifiedBy.nilIfEmpty ?? "—")
                if let revision = properties.revision {
                    LabeledContent("Properties.Revision", value: String(revision))
                }
                if !properties.applicationDescription.isEmpty {
                    LabeledContent("Properties.Application", value: properties.applicationDescription)
                }
            }
            Section {
                TextField("Comments.YourName", text: $authorName)
                    .textContentType(.name)
                    .accessibilityIdentifier("property.yourName")
            } header: {
                Text("Comments.YourName")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Properties.SaveAs.Footer")
                    if presentation.keynoteSource != nil { Text("Properties.Keynote.Footer") }
                }
            }
        }
    }

    private var properties: DocumentProperties { presentation.properties }

    private func field(_ field: DocumentProperties.Field, _ label: LocalizedStringKey) -> some View {
        LabeledContent(label) {
            TextField(label, text: binding(field))
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("property.\(field.rawValue)")
        }
    }

    private func binding(_ field: DocumentProperties.Field) -> Binding<String> {
        Binding(
            get: { presentation.properties[field] },
            set: { state.setProperty(field, to: $0, in: &presentation) }
        )
    }

    private func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }
}
