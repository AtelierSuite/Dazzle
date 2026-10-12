import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures a converted presentation carries, each written once however
/// many slides use it.
///
/// PNG, JPEG and GIF go in as they are. Other formats Keynote accepts —
/// PDF, TIFF, HEIC — are drawn into PNG, since PowerPoint readers cannot be
/// relied on to show them.
final class KeynoteMedia {
    private let archive: KeynoteArchive
    private var paths: [UInt64: String] = [:]
    private var failed: Set<UInt64> = []
    private(set) var parts: [String: Data] = [:]
    /// Content types for parts their extension does not settle, such as charts.
    private(set) var contentTypes: [String: String] = [:]

    init(archive: KeynoteArchive) {
        self.archive = archive
    }

    var extensions: Set<String> {
        Set(parts.keys.map { ($0 as NSString).pathExtension.lowercased() })
    }

    /// Adds a chart part, returning where it went.
    func addChart(_ data: Data) -> String {
        let path = "ppt/charts/chart\(contentTypes.count + 1).xml"
        parts[path] = data
        contentTypes[path] = ChartWriter.contentType
        return path
    }

    /// The next chart's path, for a chart model that must name its part.
    var nextChartPath: String { "ppt/charts/chart\(contentTypes.count + 1).xml" }

    func path(for identifier: UInt64) -> String? {
        if let path = paths[identifier] { return path }
        guard !failed.contains(identifier), let file = archive.data[identifier],
              let (contents, ext) = Self.portable(file.contents) else {
            failed.insert(identifier)
            return nil
        }
        let path = "ppt/media/image\(paths.count + 1).\(ext)"
        paths[identifier] = path
        parts[path] = contents
        return path
    }

    static func portable(_ data: Data) -> (Data, String)? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "png") }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "jpeg") }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (data, "gif") }
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return pdfToPNG(data).map { ($0, "png") } }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return png(image).map { ($0, "png") }
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The first page. Icons are often drawn on tiny pages and shown much
    /// larger, so the long side is drawn at no fewer than 2,048 pixels.
    private static func pdfToPNG(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let longest = max(box.width, box.height, 1)
        let scale = min(max(2, 2_048 / longest), 4_096 / longest)
        let width = max(Int((box.width * scale).rounded()), 1)
        let height = max(Int((box.height * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage().flatMap(png)
    }
}
