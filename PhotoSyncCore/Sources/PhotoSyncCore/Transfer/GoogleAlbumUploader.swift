import Foundation

/// One item of a source album, e.g. a PhotoKit asset.
public struct TransferItem: Sendable, Identifiable, Equatable {
    /// The source's stable identifier (PhotoKit local identifier, Takeout asset ID, …).
    public var id: String
    public var fileName: String
    public var kind: MediaKind

    public init(id: String, fileName: String, kind: MediaKind) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
    }
}

/// A file exported from the source, ready to upload.
public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var mimeType: String
    public var description: String?

    public init(url: URL, fileName: String, mimeType: String, description: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.mimeType = mimeType
        self.description = description
    }
}

/// Exports items of a source library to local files.
public protocol TransferSource: Sendable {
    /// Writes the item's file into `directory` (which the caller deletes afterwards).
    func export(_ item: TransferItem, into directory: URL) async throws -> ExportedFile
}

public struct TransferProgress: Sendable, Equatable {
    public var total: Int
    /// Items whose bytes were uploaded.
    public var uploaded = 0
    /// Items added to the album.
    public var added = 0
    public var failed = 0
    public var currentFileName: String?

    public init(total: Int) {
        self.total = total
    }

    public var completed: Int { added + failed }
    public var fractionCompleted: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

public struct TransferFailure: Sendable, Hashable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var fileName: String
    public var message: String
}

public struct TransferReport: Sendable, Equatable {
    public var album: GoogleAlbum
    /// Source item ID → Google media item ID, for the sync store.
    public var addedItems: [String: String]
    public var failures: [TransferFailure]
    public var wasCancelled: Bool
}

/// Copies a list of items into a new Google Photos album: export → upload →
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
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        let album = try await client.createAlbum(title: title)

        var state = TransferProgress(total: items.count)
        var added: [String: String] = [:]
        var failures: [TransferFailure] = []
        var pending: [(item: TransferItem, media: NewMediaItem)] = []
        progress(state)

        func fail(_ item: TransferItem, _ error: any Error) {
            failures.append(TransferFailure(itemID: item.id, fileName: item.fileName, message: Self.message(for: error)))
            state.failed += 1
        }

        func flush() async {
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
                    case .failed(let message):
                        failures.append(TransferFailure(itemID: entry.item.id, fileName: entry.item.fileName, message: message))
                        state.failed += 1
                    }
                }
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
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                fail(item, error)
            }

            if pending.count >= batchSize { await flush() }
        }
        if !wasCancelled { await flush() }

        state.currentFileName = nil
        progress(state)
        return TransferReport(album: album, addedItems: added, failures: failures, wasCancelled: wasCancelled)
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
