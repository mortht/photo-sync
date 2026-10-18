import Foundation
import Observation
import PhotoSyncCore

@MainActor
@Observable
final class TakeoutModel {
    private(set) var library: TakeoutLibrary?
    private(set) var isScanning = false
    var errorMessage: String?

    /// The folder the user picked; kept accessible for importing later.
    @ObservationIgnored private var accessedURL: URL?

    var albums: [TakeoutAlbum] { library?.albums.filter { $0.kind == .album } ?? [] }
    var years: [TakeoutAlbum] { library?.albums.filter { if case .year = $0.kind { true } else { false } } ?? [] }
    var other: [TakeoutAlbum] {
        library?.albums.filter { $0.kind == .archive || $0.kind == .trash } ?? []
    }

    func open(_ url: URL) async {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil

        isScanning = true
        defer { isScanning = false }
        do {
            library = try await Task.detached(priority: .userInitiated) {
                try TakeoutScanner().scan(root: url)
            }.value
        } catch {
            library = nil
            errorMessage = error.localizedDescription
        }
    }
}
