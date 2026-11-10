import Foundation

#if canImport(Darwin)
extension Bundle {
    /// The bundle holding DazzleEngine's localised strings.
    static let engine: Bundle = #bundle
}
#endif
