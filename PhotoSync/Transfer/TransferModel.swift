import Foundation
import Observation
import PhotoSyncCore

/// Drives one Apple → Google album sync.
@MainActor
@Observable
final class TransferModel: Identifiable {
    enum Phase {
        /// Loading the album's items and sync history.
        case loading
        case ready
        case running
        case finished(TransferReport)
        case failed(String)
    }

    let album: AppleAlbum
    var targetTitle: String
    /// Copy into a fresh album even though an earlier one exists.
    var forceNewAlbum = false
    private(set) var phase: Phase = .loading
    private(set) var progress = TransferProgress(total: 0)
    private(set) var items: [TransferItem] = []
    private(set) var preview = SyncPreview.newAlbum
    /// Why the sync history couldn't be checked, if it couldn't.
    private(set) var previewError: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated var id: String { album.id }

    var isActive: Bool {
        switch phase {
        case .loading, .running: true
        default: false
        }
    }

    /// Whether the run adds to an album from an earlier sync.
    var addsToExistingAlbum: Bool { preview.existingAlbumTitle != nil && !forceNewAlbum }
    var newItemCount: Int { addsToExistingAlbum ? items.count - preview.alreadySyncedCount : items.count }

    init(album: AppleAlbum) {
        self.album = album
        targetTitle = album.title
    }

    func load(client: GooglePhotosLibraryClient?) async {
        let albumID = album.id
        items = await Task.detached(priority: .userInitiated) {
            PhotoKitAlbums.transferItems(inAlbum: albumID)
        }.value
        if let client {
            do {
                preview = try await AppleToGoogleSync(store: AppSync.store, client: client)
                    .preview(sourceAlbumID: albumID, itemIDs: items.map(\.id))
            } catch {
                previewError = error.localizedDescription
            }
        }
        phase = .ready
    }

    func start(client: GooglePhotosLibraryClient, onError: @escaping (any Error) -> Void) {
        guard task == nil else { return }
        let title = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let (album, items, forceNewAlbum) = (album, items, forceNewAlbum)
        progress = TransferProgress(total: items.count)
        phase = .running

        task = Task {
            do {
                let report = try await withProgressUpdates({ self.progress = $0 }) { report in
                    try await AppleToGoogleSync(store: AppSync.store, client: client).run(
                        sourceAlbumID: album.id, sourceAlbumTitle: album.title, items: items,
                        newAlbumTitle: title, forceNewAlbum: forceNewAlbum, from: PhotoKitTransferSource(),
                        progress: report)
                }
                phase = .finished(report)
            } catch {
                phase = .failed(error.localizedDescription)
                onError(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
