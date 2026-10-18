import Foundation
import Observation
import PhotoSyncCore

/// Drives one Apple → Google album transfer.
@MainActor
@Observable
final class TransferModel: Identifiable {
    enum Phase {
        case ready
        case preparing
        case running
        case finished(TransferReport)
        case failed(String)
    }

    let album: AppleAlbum
    var targetTitle: String
    private(set) var phase: Phase = .ready
    private(set) var progress = TransferProgress(total: 0)

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated var id: String { album.id }

    var isActive: Bool {
        switch phase {
        case .preparing, .running: true
        default: false
        }
    }

    init(album: AppleAlbum) {
        self.album = album
        targetTitle = album.title
    }

    func start(client: GooglePhotosLibraryClient, onError: @escaping (any Error) -> Void) {
        guard task == nil else { return }
        let title = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumID = album.id
        phase = .preparing

        task = Task {
            let items = await Task.detached(priority: .userInitiated) {
                PhotoKitAlbums.transferItems(inAlbum: albumID)
            }.value
            progress = TransferProgress(total: items.count)
            phase = .running

            // An ordered stream keeps progress updates from arriving out of order.
            let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self,
                                                                 bufferingPolicy: .bufferingNewest(1))
            let consumer = Task { for await update in updates { progress = update } }
            defer { consumer.cancel() }

            do {
                let report = try await GoogleAlbumUploader(client: client).transfer(
                    items, toNewAlbumTitled: title, from: PhotoKitTransferSource()
                ) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                phase = .finished(report)
            } catch {
                continuation.finish()
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                onError(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
