import CoreTransferable
import DazzleEngine
import Foundation
import UniformTypeIdentifiers

/// A movie handed over by the photo picker, copied somewhere it can be read.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
