import AppKit
import Foundation
import Observation
import PhotoSyncCore

/// Drives one Google Photos Picker → Apple Photos import.
@MainActor
@Observable
final class PickerImportModel: Identifiable {
    enum Phase {
        case starting
        /// The picker is open in the browser.
        case waiting
        case loading
        case picked
        case running
        case finished(ImportReport)
        case failed(String)
    }

    let id = UUID()
    var albumTitle = "From Google Photos"
    private(set) var phase: Phase = .starting
    private(set) var items: [PickedMediaItem] = []
    private(set) var preview = SyncPreview.newAlbum
    private(set) var progress = TransferProgress(total: 0)

    private let client: GooglePhotosPickerClient
    private let onError: (any Error) -> Void
    @ObservationIgnored private var session: PickerSession?
    @ObservationIgnored private var listedAt = Date()
    @ObservationIgnored private var task: Task<Void, Never>?

    var photoCount: Int { items.count { $0.kind == .photo } }
    var videoCount: Int { items.count { $0.kind == .video } }
    var newItemCount: Int { items.count - preview.alreadySyncedCount }
    var isRunning: Bool { if case .running = phase { true } else { false } }

    init(client: GooglePhotosPickerClient, onError: @escaping (any Error) -> Void) {
        self.client = client
        self.onError = onError
    }

    private var sync: PickerToAppleSync {
        PickerToAppleSync(store: AppSync.store, destination: PhotoKitImportDestination(),
                          importer: PickerImporter(client: client))
    }

    /// Creates a session, opens the picker in the browser and waits for the selection.
    func begin() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            do {
                let created = try await client.createSession()
                session = created
                openPicker()
                phase = .waiting
                let picked = try await client.waitForPicking(created)
                phase = .loading
                items = try await client.mediaItems(sessionID: picked.id)
                listedAt = Date()
                await updatePreview()
                phase = .picked
            } catch is CancellationError {
                // Closed by the user.
            } catch {
                fail(error)
            }
        }
    }

    func openPicker() {
        guard let url = session?.autoclosePickerURL else { return }
        NSWorkspace.shared.open(url)
    }

    func updatePreview() async {
        preview = (try? await sync.preview(albumTitle: albumTitle, itemIDs: items.map(\.id))) ?? .newAlbum
    }

    func start() {
        guard task == nil, let session else { return }
        let (items, listedAt, title, sync) = (items, listedAt, albumTitle, sync)
        progress = TransferProgress(total: items.count)
        phase = .running

        task = Task {
            defer { task = nil }
            let (updates, continuation) = AsyncStream.makeStream(of: TransferProgress.self,
                                                                 bufferingPolicy: .bufferingNewest(1))
            let consumer = Task { for await update in updates { progress = update } }
            defer { consumer.cancel() }
            do {
                let report = try await sync.run(sessionID: session.id, items: items, listedAt: listedAt,
                                                albumTitle: title) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                phase = .finished(report)
            } catch {
                continuation.finish()
                fail(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Stops any work and deletes the session at Google (best effort).
    func close() {
        task?.cancel()
        guard let session else { return }
        self.session = nil
        let client = client
        Task { try? await client.deleteSession(id: session.id) }
    }

    private func fail(_ error: any Error) {
        phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        onError(error)
    }
}
