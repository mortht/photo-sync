import Foundation
import Observation
import PhotoSyncCore

/// Drives one Takeout → Apple Photos album import.
@MainActor
@Observable
final class ImportModel: Identifiable {
    enum Phase {
        case ready
        case running
        case finished(ImportReport)
        case failed(String)
    }

    let album: TakeoutAlbum
    var targetTitle: String
    var options = TakeoutImportOptions()
    private(set) var phase: Phase = .ready
    private(set) var progress = TransferProgress(total: 0)

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated var id: String { album.id }

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var itemCount: Int { TakeoutAlbumImporter.itemCount(of: album, options: options) }
    var hasEditedCopies: Bool { album.assets.contains { $0.editedFile != nil } }
    var hasDescriptions: Bool { album.assets.contains { $0.metadata?.description != nil } }

    init(album: TakeoutAlbum) {
        self.album = album
        targetTitle = album.title
    }

    func start() {
        guard task == nil else { return }
        let title = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album
        let options = options
        progress = TransferProgress(total: itemCount)
        phase = .running

        task = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self,
                                                                 bufferingPolicy: .bufferingNewest(1))
            let consumer = Task { for await update in updates { progress = update } }
            defer { consumer.cancel() }
            do {
                let report = try await TakeoutAlbumImporter().importAlbum(
                    album, title: title, into: PhotoKitImportDestination(), options: options
                ) { continuation.yield($0) }
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
