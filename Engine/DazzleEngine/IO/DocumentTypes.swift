import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML presentation, declared by the system.
    public static let openXMLPresentation = UTType("org.openxmlformats.presentationml.presentation") ?? .data
    /// The `.pptm` presentation, which may carry macros. Dazzle opens and
    /// saves these, keeping the macros, but never runs them.
    public static let macroEnabledPresentation = UTType("org.openxmlformats.presentationml.presentation.macroenabled") ?? .data
    /// The `.ppsx` slide show: a presentation that opens straight into playing.
    public static let openXMLSlideShow = UTType("org.openxmlformats.presentationml.slideshow") ?? .data
    /// A Keynote presentation saved as a single file, as iCloud Drive keeps them.
    public static let keynote = UTType("com.apple.iwork.keynote.sffkey") ?? .data
    /// A Keynote presentation saved as a package directory.
    public static let keynotePackage = UTType("com.apple.iwork.keynote.key") ?? .package
}

extension Presentation {
    /// A new presentation: one title slide on the built-in template.
    public static var blank: Presentation {
        do {
            return try PPTXReader.presentation(fromParts: PresentationTemplate.parts())
        } catch {
            preconditionFailure("The built-in template must always read: \(error)")
        }
    }
}
