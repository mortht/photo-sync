import Foundation

/// Imports items picked in the Google Photos Picker into a photo library
/// album: download → `PhotoLibraryDestination.importAsset`, with the capture
/// date from `createTime`. Location can't be restored because Google strips it
/// from Picker downloads.
public struct PickerImporter: Sendable {
    private let client: GooglePhotosPickerClient
    private let temporaryDirectory: URL
    private let now: @Sendable () -> Date
    /// Re-list items ten minutes before their `baseUrl`s expire.
    static let refreshAfter = TimeInterval(GooglePhotosPickerClient.baseURLLifetime.components.seconds) - 10 * 60

    public init(client: GooglePhotosPickerClient,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.temporaryDirectory = temporaryDirectory
        self.now = now
    }

    public func importItems(
        _ items: [PickedMediaItem],
        listedAt: Date,
        sessionID: String,
        intoAlbumID albumID: String,
        albumTitle: String,
        into destination: some PhotoLibraryDestination,
        ledger: (any SyncLedger)? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        var report = ImportReport(albumID: albumID, albumTitle: albumTitle, importedItems: [:], failures: [],
                                  warnings: [], skippedCount: 0, wasCancelled: false)
        var state = TransferProgress(total: items.count)
        var fresh = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var listedAt = listedAt
        progress(state)

        for original in items {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }
            if let ledger, try await ledger.contains(itemID: original.id) {
                state.skipped += 1
                state.processed += 1
                report.skippedCount += 1
                progress(state)
                continue
            }
            if now().timeIntervalSince(listedAt) > Self.refreshAfter {
                let relisted = try await client.mediaItems(sessionID: sessionID)
                fresh = Dictionary(relisted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                listedAt = now()
            }
            let item = fresh[original.id] ?? original
            state.currentFileName = item.fileName
            progress(state)

            let workDirectory = temporaryDirectory.appending(path: "PhotoSync-\(UUID().uuidString)",
                                                             directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            do {
                let file = try await client.download(item, into: workDirectory)
                let request = AssetImportRequest(
                    kind: item.kind, file: file, pairedVideoFile: nil, originalFileName: file.lastPathComponent,
                    creationDate: item.createTime, location: nil, isFavorite: false)
                let assetID = try await destination.importAsset(request, intoAlbum: albumID)
                report.importedItems[item.id] = [assetID]
                state.added += 1
                try await ledger?.record(itemID: item.id, contentHash: nil, destinationIDs: [assetID])
            } catch let error as SyncStoreError {
                throw error
            } catch {
                // Downloads report cancellation as URLError(.cancelled).
                if Task.isCancelled || error is CancellationError {
                    report.wasCancelled = true
                    break
                }
                report.failures.append(TransferFailure(itemID: item.id, fileName: item.fileName,
                                                       message: error.localizedDescription))
                state.failed += 1
            }
            state.processed += 1
            progress(state)
        }

        state.currentFileName = nil
        progress(state)
        return report
    }
}

/// Picker selection → Apple Photos album, skipping items imported into the
/// same album before (Picker item IDs are stable across sessions).
public struct PickerToAppleSync: Sendable {
    public let store: SyncStore
    public let destination: any PhotoLibraryDestination
    public let importer: PickerImporter

    public init(store: SyncStore, destination: any PhotoLibraryDestination, importer: PickerImporter) {
        self.store = store
        self.destination = destination
        self.importer = importer
    }

    /// Sync history is kept per target album name.
    static func key(forAlbumTitle title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func preview(albumTitle: String, itemIDs: [String]) async throws -> SyncPreview {
        guard let pair = try await store.pair(direction: .pickerToApple,
                                              sourceAlbumID: Self.key(forAlbumTitle: albumTitle)),
              await destination.albumExists(id: pair.destinationAlbumID) else { return .newAlbum }
        let synced = try await store.syncedItemIDs(pairID: pair.id)
        return SyncPreview(existingAlbumTitle: pair.destinationAlbumTitle,
                           alreadySyncedCount: itemIDs.count { synced.contains($0) },
                           lastSyncedAt: pair.lastSyncedAt)
    }

    public func run(
        sessionID: String,
        items: [PickedMediaItem],
        listedAt: Date,
        albumTitle: String,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = try await SyncTarget.resolve(
            store: store, direction: .pickerToApple, sourceAlbumID: Self.key(forAlbumTitle: title),
            sourceAlbumTitle: title, forceNewAlbum: false, destination: destination, newAlbumTitle: title)
        let report = try await importer.importItems(
            items, listedAt: listedAt, sessionID: sessionID, intoAlbumID: target.album.id,
            albumTitle: target.album.title, into: destination, ledger: target.ledger, progress: progress)
        try await target.complete(wasCancelled: report.wasCancelled)
        return report
    }
}
