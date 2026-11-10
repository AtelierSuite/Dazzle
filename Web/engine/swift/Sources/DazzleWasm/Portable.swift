import Foundation

// What the shared editing code (Shared/, linked from Common/) takes from
// SwiftUI on Apple platforms.

extension Array {
    /// Moves the elements at `offsets` to before `destination`, as SwiftUI's lists do.
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().filter { indices.contains($0) }.map { self[$0] }
        let before = offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) where indices.contains(offset) { remove(at: offset) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(destination - before, 0), count))
    }
}
