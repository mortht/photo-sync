import Foundation

public struct TransferReport: Sendable, Equatable {
    public var album: GoogleAlbum
    /// Source item ID → Google media item ID, for the sync store.
    public var addedItems: [String: String]
    public var failures: [TransferFailure]
    /// Items already copied by an earlier run.
    public var skippedCount: Int
    public var wasCancelled: Bool
}

/// Copies a list of items into a Google Photos album: export → upload →
/// `batchCreate` in batches of up to 50. Item failures are collected rather
/// than aborting the whole transfer.
public struct GoogleAlbumUploader: Sendable {
    private let client: GooglePhotosLibraryClient
    private let batchSize: Int
    private let temporaryDirectory: URL

    public init(
        client: GooglePhotosLibraryClient,
        batchSize: Int = GooglePhotosLibraryClient.maxBatchSize,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.client = client
        self.batchSize = min(max(batchSize, 1), GooglePhotosLibraryClient.maxBatchSize)
        self.temporaryDirectory = temporaryDirectory
    }

    public func transfer(
        _ items: [TransferItem],
        toNewAlbumTitled title: String,
        from source: some TransferSource,
        ledger: (any SyncLedger)? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        let album = try await client.createAlbum(title: title)
        return try await transfer(items, into: album, from: source, ledger: ledger, progress: progress)
    }

    /// Copies items into an existing app-created album. With a `ledger`,
    /// items it already contains are skipped and new ones are recorded as
    /// soon as Google confirms them.
    public func transfer(
        _ items: [TransferItem],
        into album: GoogleAlbum,
        from source: some TransferSource,
        ledger: (any SyncLedger)? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        var state = TransferProgress(total: items.count)
        var added: [String: String] = [:]
        var failures: [TransferFailure] = []
        var pending: [(item: TransferItem, media: NewMediaItem)] = []
        progress(state)

        func fail(_ item: TransferItem, _ error: any Error) {
            failures.append(TransferFailure(itemID: item.id, fileName: item.fileName, message: error.localizedDescription))
            state.failed += 1
        }

        func flush() async throws {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending.removeAll()
            do {
                let results = try await client.batchCreate(albumID: album.id, items: batch.map(\.media))
                for (entry, result) in zip(batch, results) {
                    switch result.status {
                    case .created(let mediaItemID):
                        added[entry.item.id] = mediaItemID
                        state.added += 1
                        try await ledger?.record(itemID: entry.item.id, contentHash: nil, destinationIDs: [mediaItemID])
                    case .failed(let message):
                        failures.append(TransferFailure(itemID: entry.item.id, fileName: entry.item.fileName, message: message))
                        state.failed += 1
                    }
                }
            } catch let error as SyncStoreError {
                throw error
            } catch {
                batch.forEach { fail($0.item, error) }
            }
            progress(state)
        }

        var wasCancelled = false
        for item in items {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            if let ledger, try await ledger.contains(itemID: item.id) {
                state.skipped += 1
                state.processed += 1
                progress(state)
                continue
            }
            state.currentFileName = item.fileName
            progress(state)

            let workDirectory = temporaryDirectory.appending(path: "PhotoSync-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: workDirectory) }
                let file = try await source.export(item, into: workDirectory)
                let token = try await client.uploadFile(at: file.url, fileName: file.fileName, mimeType: file.mimeType)
                pending.append((item, NewMediaItem(uploadToken: token, fileName: file.fileName, description: file.description)))
                state.uploaded += 1
            } catch {
                // URLSession reports a cancelled task as URLError(.cancelled), not CancellationError.
                if Task.isCancelled || error is CancellationError {
                    wasCancelled = true
                    break
                }
                fail(item, error)
            }
            state.processed += 1
            progress(state)

            if pending.count >= batchSize { try await flush() }
        }
        if !wasCancelled { try await flush() }

        state.currentFileName = nil
        progress(state)
        return TransferReport(album: album, addedItems: added, failures: failures, skippedCount: state.skipped,
                              wasCancelled: wasCancelled)
    }
}
