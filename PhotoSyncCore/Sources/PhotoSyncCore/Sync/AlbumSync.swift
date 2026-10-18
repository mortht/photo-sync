import Foundation

/// What re-running a transfer for an album will do.
public struct SyncPreview: Sendable, Equatable {
    /// The album new items will be added to; `nil` means a new album is created.
    public var existingAlbumTitle: String?
    /// Source items that an earlier run already copied.
    public var alreadySyncedCount: Int
    public var lastSyncedAt: Date?

    public static let newAlbum = SyncPreview(existingAlbumTitle: nil, alreadySyncedCount: 0, lastSyncedAt: nil)
}

/// Apple Photos album → Google Photos album, adding only new items on re-runs.
public struct AppleToGoogleSync: Sendable {
    public let store: SyncStore
    public let client: GooglePhotosLibraryClient

    public init(store: SyncStore, client: GooglePhotosLibraryClient) {
        self.store = store
        self.client = client
    }

    public func preview(sourceAlbumID: String, itemIDs: [String]) async throws -> SyncPreview {
        guard let pair = try await store.pair(direction: .appleToGoogle, sourceAlbumID: sourceAlbumID),
              let album = try await client.album(id: pair.destinationAlbumID) else { return .newAlbum }
        let synced = try await store.syncedItemIDs(pairID: pair.id)
        return SyncPreview(existingAlbumTitle: album.title,
                           alreadySyncedCount: itemIDs.count { synced.contains($0) },
                           lastSyncedAt: pair.lastSyncedAt)
    }

    /// Adds the album's new items to the Google album from earlier runs, or to
    /// a new album when there is none, it was deleted, or `forceNewAlbum` is set.
    public func run(
        sourceAlbumID: String,
        sourceAlbumTitle: String,
        items: [TransferItem],
        newAlbumTitle: String,
        forceNewAlbum: Bool = false,
        from source: some TransferSource,
        uploader: GoogleAlbumUploader? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        var album: GoogleAlbum?
        if !forceNewAlbum, let pair = try await store.pair(direction: .appleToGoogle, sourceAlbumID: sourceAlbumID) {
            album = try await client.album(id: pair.destinationAlbumID)
        }
        let target: GoogleAlbum
        if let album {
            target = album
        } else {
            target = try await client.createAlbum(title: newAlbumTitle)
        }
        let pair = try await store.linkPair(direction: .appleToGoogle, sourceAlbumID: sourceAlbumID,
                                            sourceAlbumTitle: sourceAlbumTitle, destinationAlbumID: target.id,
                                            destinationAlbumTitle: target.title)
        let report = try await (uploader ?? GoogleAlbumUploader(client: client)).transfer(
            items, into: target, from: source, ledger: AlbumSyncLedger(store: store, pairID: pair.id),
            progress: progress)
        if !report.wasCancelled { try await store.markSynced(pairID: pair.id) }
        return report
    }
}

/// Takeout album → Apple Photos album, adding only new items on re-runs.
public struct TakeoutToAppleSync: Sendable {
    public let store: SyncStore
    public let destination: any PhotoLibraryDestination
    public let importer: TakeoutAlbumImporter

    public init(store: SyncStore, destination: any PhotoLibraryDestination,
                importer: TakeoutAlbumImporter = TakeoutAlbumImporter()) {
        self.store = store
        self.destination = destination
        self.importer = importer
    }

    public func preview(album: TakeoutAlbum) async throws -> SyncPreview {
        guard let pair = try await store.pair(direction: .takeoutToApple, sourceAlbumID: album.id),
              await destination.albumExists(id: pair.destinationAlbumID) else { return .newAlbum }
        let synced = try await store.syncedItemIDs(pairID: pair.id)
        return SyncPreview(existingAlbumTitle: pair.destinationAlbumTitle,
                           alreadySyncedCount: album.assets.count { synced.contains($0.id) },
                           lastSyncedAt: pair.lastSyncedAt)
    }

    public func run(
        album: TakeoutAlbum,
        newAlbumTitle: String,
        forceNewAlbum: Bool = false,
        options: TakeoutImportOptions = TakeoutImportOptions(),
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        var target: (id: String, title: String)?
        if !forceNewAlbum, let pair = try await store.pair(direction: .takeoutToApple, sourceAlbumID: album.id),
           await destination.albumExists(id: pair.destinationAlbumID) {
            target = (pair.destinationAlbumID, pair.destinationAlbumTitle)
        }
        if target == nil {
            target = (try await destination.createAlbum(title: newAlbumTitle), newAlbumTitle)
        }
        let (albumID, albumTitle) = target!
        let pair = try await store.linkPair(direction: .takeoutToApple, sourceAlbumID: album.id,
                                            sourceAlbumTitle: album.title, destinationAlbumID: albumID,
                                            destinationAlbumTitle: albumTitle)
        let report = try await importer.importAlbum(
            album, intoAlbumID: albumID, albumTitle: albumTitle, into: destination, options: options,
            ledger: AlbumSyncLedger(store: store, pairID: pair.id), progress: progress)
        if !report.wasCancelled { try await store.markSynced(pairID: pair.id) }
        return report
    }
}
