import Foundation
import Observation
import PhotoSyncCore

/// Drives one Takeout → Apple Photos album sync.
@MainActor
@Observable
final class ImportModel: Identifiable {
    enum Phase {
        case loading
        case ready
        case running
        case finished(ImportReport)
        case failed(String)
    }

    let album: TakeoutAlbum
    var targetTitle: String
    var options = TakeoutImportOptions()
    var forceNewAlbum = false
    private(set) var phase: Phase = .loading
    private(set) var progress = TransferProgress(total: 0)
    private(set) var preview = SyncPreview.newAlbum

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated var id: String { album.id }

    var isActive: Bool {
        switch phase {
        case .loading, .running: true
        default: false
        }
    }
    var itemCount: Int { TakeoutAlbumImporter.itemCount(of: album, options: options) }
    var hasEditedCopies: Bool { album.assets.contains { $0.editedFile != nil } }
    var hasDescriptions: Bool { album.assets.contains { $0.metadata?.description != nil } }
    var addsToExistingAlbum: Bool { preview.existingAlbumTitle != nil && !forceNewAlbum }

    init(album: TakeoutAlbum) {
        self.album = album
        targetTitle = album.title
    }

    private var sync: TakeoutToAppleSync {
        TakeoutToAppleSync(store: AppSync.store, destination: PhotoKitImportDestination())
    }

    func load() async {
        preview = (try? await sync.preview(album: album)) ?? .newAlbum
        phase = .ready
    }

    func start() {
        guard task == nil else { return }
        let title = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let (album, options, forceNewAlbum, sync) = (album, options, forceNewAlbum, sync)
        progress = TransferProgress(total: itemCount)
        phase = .running

        task = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self,
                                                                 bufferingPolicy: .bufferingNewest(1))
            let consumer = Task { for await update in updates { progress = update } }
            defer { consumer.cancel() }
            do {
                let report = try await sync.run(album: album, newAlbumTitle: title, forceNewAlbum: forceNewAlbum,
                                                options: options) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                phase = .finished(report)
            } catch {
                continuation.finish()
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
