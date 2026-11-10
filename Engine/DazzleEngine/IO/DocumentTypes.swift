import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UniformTypeIdentifiers)
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
#endif

/// The MIME type a package declares for a file by its extension.
public enum MediaTypes {
    public static func mimeType(forExtension ext: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext)?.preferredMIMEType { return type }
        #endif
        return known[ext.lowercased()] ?? "application/octet-stream"
    }

    /// What pictures, movies and sounds in presentations are, for platforms
    /// without a system type registry.
    private static let known: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic",
        "emf": "image/x-emf", "wmf": "image/x-wmf", "pdf": "application/pdf",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "avi": "video/x-msvideo", "wmv": "video/x-ms-wmv",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "aac": "audio/aac", "ogg": "audio/ogg",
        "wma": "audio/x-ms-wma",
    ]
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
