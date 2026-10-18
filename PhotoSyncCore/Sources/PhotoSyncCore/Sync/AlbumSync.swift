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
        let target = try await SyncTarget.resolve(
            store: store, direction: .appleToGoogle, sourceAlbumID: sourceAlbumID,
            sourceAlbumTitle: sourceAlbumTitle, forceNewAlbum: forceNewAlbum,
            existing: { try await client.album(id: $0.destinationAlbumID) },
            create: { try await client.createAlbum(title: newAlbumTitle) },
            identity: { ($0.id, $0.title) })
        let report = try await (uploader ?? GoogleAlbumUploader(client: client)).transfer(
            items, into: target.album, from: source, ledger: target.ledger, progress: progress)
        try await target.complete(wasCancelled: report.wasCancelled)
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
        let target = try await SyncTarget.resolve(
            store: store, direction: .takeoutToApple, sourceAlbumID: album.id, sourceAlbumTitle: album.title,
            forceNewAlbum: forceNewAlbum, destination: destination, newAlbumTitle: newAlbumTitle)
        let report = try await importer.importAlbum(
            album, intoAlbumID: target.album.id, albumTitle: target.album.title, into: destination,
            options: options, ledger: target.ledger, progress: progress)
        try await target.complete(wasCancelled: report.wasCancelled)
        return report
    }
}

/// An album in the photo library, as stored in a sync pair.
struct LibraryAlbum {
    var id: String
    var title: String
}

/// The destination of one sync run and its ledger. Encodes the rule shared by
/// all directions: reuse the album linked to the source while it exists
/// (unless a new one is forced), otherwise create one and relink.
struct SyncTarget<Album> {
    let store: SyncStore
    let pair: SyncPair
    let album: Album

    var ledger: AlbumSyncLedger { AlbumSyncLedger(store: store, pairID: pair.id) }

    static func resolve(
        store: SyncStore,
        direction: SyncDirection,
        sourceAlbumID: String,
        sourceAlbumTitle: String,
        forceNewAlbum: Bool,
        existing: (SyncPair) async throws -> Album?,
        create: () async throws -> Album,
        identity: (Album) -> (id: String, title: String)
    ) async throws -> SyncTarget {
        var album: Album?
        if !forceNewAlbum, let pair = try await store.pair(direction: direction, sourceAlbumID: sourceAlbumID) {
            album = try await existing(pair)
        }
        let target: Album
        if let album {
            target = album
        } else {
            target = try await create()
        }
        let (id, title) = identity(target)
        let pair = try await store.linkPair(direction: direction, sourceAlbumID: sourceAlbumID,
                                            sourceAlbumTitle: sourceAlbumTitle, destinationAlbumID: id,
                                            destinationAlbumTitle: title)
        return SyncTarget(store: store, pair: pair, album: target)
    }

    /// Records the sync time unless the run was stopped early.
    func complete(wasCancelled: Bool) async throws {
        if !wasCancelled { try await store.markSynced(pairID: pair.id) }
    }
}

extension SyncTarget where Album == LibraryAlbum {
    /// Resolves an album in a `PhotoLibraryDestination`.
    static func resolve(
        store: SyncStore,
        direction: SyncDirection,
        sourceAlbumID: String,
        sourceAlbumTitle: String,
        forceNewAlbum: Bool,
        destination: any PhotoLibraryDestination,
        newAlbumTitle: String
    ) async throws -> SyncTarget {
        try await resolve(
            store: store, direction: direction, sourceAlbumID: sourceAlbumID, sourceAlbumTitle: sourceAlbumTitle,
            forceNewAlbum: forceNewAlbum,
            existing: { pair in
                await destination.albumExists(id: pair.destinationAlbumID)
                    ? LibraryAlbum(id: pair.destinationAlbumID, title: pair.destinationAlbumTitle) : nil
            },
            create: { LibraryAlbum(id: try await destination.createAlbum(title: newAlbumTitle), title: newAlbumTitle) },
            identity: { ($0.id, $0.title) })
    }
}
