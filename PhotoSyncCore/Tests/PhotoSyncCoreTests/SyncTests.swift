import Foundation
import Testing
@testable import PhotoSyncCore

@Suite struct SyncStoreTests {
    @Test func pairsAndItemsPersistAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SyncStore-\(UUID().uuidString)/sync.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try SyncStore(url: url)
            let pair = try await store.linkPair(direction: .appleToGoogle, sourceAlbumID: "A1", sourceAlbumTitle: "Trip",
                                                destinationAlbumID: "G1", destinationAlbumTitle: "Trip")
            try await store.recordItem(pairID: pair.id, sourceItemID: "asset-1", contentHash: "h1",
                                       destinationIDs: ["m1", "m2"])
            try await store.markSynced(pairID: pair.id, at: Date(timeIntervalSince1970: 1000))
        }

        let reopened = try SyncStore(url: url)
        let pair = try #require(try await reopened.pair(direction: .appleToGoogle, sourceAlbumID: "A1"))
        #expect(pair.destinationAlbumID == "G1")
        #expect(pair.lastSyncedAt == Date(timeIntervalSince1970: 1000))
        #expect(try await reopened.syncedItemIDs(pairID: pair.id) == ["asset-1"])
        #expect(try await reopened.destinationIDs(pairID: pair.id, sourceItemID: "asset-1") == ["m1", "m2"])
        #expect(try await reopened.containsContent(pairID: pair.id, contentHash: "h1"))
        #expect(try await reopened.pair(direction: .takeoutToApple, sourceAlbumID: "A1") == nil)
    }

    @Test func relinkingToAnotherDestinationForgetsItems() async throws {
        let store = try SyncStore(url: nil)
        let first = try await store.linkPair(direction: .takeoutToApple, sourceAlbumID: "Trip", sourceAlbumTitle: "Trip",
                                             destinationAlbumID: "P1", destinationAlbumTitle: "Trip")
        try await store.recordItem(pairID: first.id, sourceItemID: "Trip/a.jpg", contentHash: nil, destinationIDs: ["x"])

        let same = try await store.linkPair(direction: .takeoutToApple, sourceAlbumID: "Trip", sourceAlbumTitle: "Trip",
                                            destinationAlbumID: "P1", destinationAlbumTitle: "Trip")
        #expect(same.id == first.id)
        #expect(try await store.syncedItemIDs(pairID: first.id) == ["Trip/a.jpg"])

        let moved = try await store.linkPair(direction: .takeoutToApple, sourceAlbumID: "Trip", sourceAlbumTitle: "Trip",
                                             destinationAlbumID: "P2", destinationAlbumTitle: "Trip (2)")
        #expect(moved.id == first.id)
        #expect(moved.destinationAlbumID == "P2")
        #expect(try await store.syncedItemIDs(pairID: first.id).isEmpty)
    }

    @Test func summariesCountSyncedItemsPerPair() async throws {
        let store = try SyncStore(url: nil)
        let a = try await store.linkPair(direction: .appleToGoogle, sourceAlbumID: "A", sourceAlbumTitle: "A",
                                         destinationAlbumID: "G", destinationAlbumTitle: "A")
        _ = try await store.linkPair(direction: .takeoutToApple, sourceAlbumID: "T", sourceAlbumTitle: "T",
                                     destinationAlbumID: "P", destinationAlbumTitle: "T")
        for id in ["1", "2"] {
            try await store.recordItem(pairID: a.id, sourceItemID: id, contentHash: nil, destinationIDs: ["m\(id)"])
        }
        let summaries = try await store.summaries()
        #expect(summaries.first { $0.pair.sourceAlbumID == "A" }?.syncedItemCount == 2)
        #expect(summaries.first { $0.pair.sourceAlbumID == "T" }?.syncedItemCount == 0)
    }

    @Test func recordingTwiceUpdates() async throws {
        let store = try SyncStore(url: nil)
        let pair = try await store.linkPair(direction: .appleToGoogle, sourceAlbumID: "A", sourceAlbumTitle: "A",
                                            destinationAlbumID: "G", destinationAlbumTitle: "A")
        try await store.recordItem(pairID: pair.id, sourceItemID: "i", contentHash: nil, destinationIDs: ["1"])
        try await store.recordItem(pairID: pair.id, sourceItemID: "i", contentHash: "h", destinationIDs: ["2"])
        #expect(try await store.destinationIDs(pairID: pair.id, sourceItemID: "i") == ["2"])
        try await store.removePair(id: pair.id)
        #expect(try await store.allPairs().isEmpty)
    }
}

@Suite struct AppleToGoogleSyncTests {
    let temp: URL

    init() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "AppleToGoogleSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    /// Fake Google that remembers created albums; `deleted` albums answer 404.
    static func fakeGoogle(deleted: Locked<Set<String>> = Locked([])) -> MockHTTPClient {
        let albums = Locked(0)
        let base = GoogleAlbumUploaderTests.fakeGoogle()
        return MockHTTPClient { recorded in
            let path = recorded.path
            if path == "/v1/albums" {
                let number = albums.withValue { $0 += 1; return $0 }
                return .json(#"{"id":"album-\#(number)","title":"Trip"}"#)
            }
            if path.hasPrefix("/v1/albums/") {
                let id = String(path.dropFirst("/v1/albums/".count))
                return deleted.current.contains(id)
                    ? .json(#"{"error":{"code":404,"message":"Not found"}}"#, status: 404)
                    : .json(#"{"id":"\#(id)","title":"Trip"}"#)
            }
            return try base.data(for: recorded.request, uploadedFile: recorded.uploadedFile)
        }
    }

    func sync(_ http: MockHTTPClient, store: SyncStore) -> AppleToGoogleSync {
        let client = GooglePhotosLibraryClient(httpClient: http, retryPolicy: .init(sleep: { _ in })) { _ in "t" }
        return AppleToGoogleSync(store: store, client: client)
    }

    func run(_ sync: AppleToGoogleSync, _ items: [TransferItem], forceNew: Bool = false) async throws -> TransferReport {
        try await sync.run(sourceAlbumID: "apple-album", sourceAlbumTitle: "Trip", items: items, newAlbumTitle: "Trip",
                           forceNewAlbum: forceNew, from: FakeSource(),
                           uploader: GoogleAlbumUploader(client: sync.client, temporaryDirectory: temp))
    }

    @Test func secondRunOnlyUploadsNewItems() async throws {
        let http = Self.fakeGoogle()
        let store = try SyncStore(url: nil)
        let sync = sync(http, store: store)

        let first = try await run(sync, GoogleAlbumUploaderTests.items(3))
        #expect(first.addedItems.count == 3)
        #expect(first.album.id == "album-1")
        #expect(try await sync.preview(sourceAlbumID: "apple-album", itemIDs: GoogleAlbumUploaderTests.items(5).map(\.id))
            == SyncPreview(existingAlbumTitle: "Trip", alreadySyncedCount: 3,
                           lastSyncedAt: try await store.pair(direction: .appleToGoogle, sourceAlbumID: "apple-album")?.lastSyncedAt))

        let second = try await run(sync, GoogleAlbumUploaderTests.items(5))
        #expect(second.album.id == "album-1")
        #expect(second.skippedCount == 3)
        #expect(Set(second.addedItems.keys) == ["id-4", "id-5"])
        #expect(http.requests.filter { $0.path == "/v1/albums" }.count == 1)
        #expect(http.requests.filter { $0.path == "/v1/uploads" }.count == 5)
    }

    @Test func deletedGoogleAlbumStartsOver() async throws {
        let deleted = Locked<Set<String>>([])
        let http = Self.fakeGoogle(deleted: deleted)
        let store = try SyncStore(url: nil)
        let sync = sync(http, store: store)

        _ = try await run(sync, GoogleAlbumUploaderTests.items(2))
        deleted.withValue { _ = $0.insert("album-1") }
        #expect(try await sync.preview(sourceAlbumID: "apple-album", itemIDs: ["id-1"]) == .newAlbum)

        let second = try await run(sync, GoogleAlbumUploaderTests.items(2))
        #expect(second.album.id == "album-2")
        #expect(second.addedItems.count == 2)
        #expect(second.skippedCount == 0)
    }

    @Test func forceNewAlbumCopiesEverythingAgain() async throws {
        let http = Self.fakeGoogle()
        let sync = sync(http, store: try SyncStore(url: nil))
        _ = try await run(sync, GoogleAlbumUploaderTests.items(2))
        let second = try await run(sync, GoogleAlbumUploaderTests.items(2), forceNew: true)
        #expect(second.album.id == "album-2")
        #expect(second.addedItems.count == 2)
    }

    @Test func failedItemsAreRetriedNextRun() async throws {
        let http = Self.fakeGoogle()
        let sync = sync(http, store: try SyncStore(url: nil))
        let items = GoogleAlbumUploaderTests.items(3)
        let first = try await sync.run(sourceAlbumID: "apple-album", sourceAlbumTitle: "Trip", items: items,
                                       newAlbumTitle: "Trip", from: FakeSource(failing: ["id-2"]),
                                       uploader: GoogleAlbumUploader(client: sync.client, temporaryDirectory: temp))
        #expect(first.failures.map(\.itemID) == ["id-2"])
        let second = try await run(sync, items)
        #expect(second.skippedCount == 2)
        #expect(Array(second.addedItems.keys) == ["id-2"])
    }
}

@Suite struct TakeoutToAppleSyncTests {
    let fixture: TakeoutFixture
    let temp: URL

    init() throws {
        fixture = try TakeoutFixture()
        temp = fixture.root.appending(path: "work")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    func scan(_ folder: String = "Google Photos") throws -> TakeoutAlbum {
        let library = try TakeoutScanner().scan(root: fixture.root.appending(path: folder))
        return try #require(library.albums.first { $0.id == "Party" })
    }

    func sync(_ library: FakeLibrary, store: SyncStore) -> TakeoutToAppleSync {
        TakeoutToAppleSync(store: store, destination: library, importer: TakeoutAlbumImporter(temporaryDirectory: temp))
    }

    @Test func reimportAddsOnlyNewItemsToSameAlbum() async throws {
        try fixture.file("Google Photos/Party/a.jpg", "A")
        try fixture.file("Google Photos/Party/b.jpg", "B")
        let library = FakeLibrary()
        let store = try SyncStore(url: nil)
        let sync = sync(library, store: store)

        let first = try await sync.run(album: try scan(), newAlbumTitle: "Party")
        #expect(first.importedCount == 2)
        #expect(try await sync.preview(album: try scan()).alreadySyncedCount == 2)

        try fixture.file("Google Photos/Party/c.jpg", "C")
        let second = try await sync.run(album: try scan(), newAlbumTitle: "Party")
        #expect(second.albumID == first.albumID)
        #expect(second.skippedCount == 2)
        #expect(Array(second.importedItems.keys) == ["Party/c.jpg"])
        #expect(library.albums == ["Party"])
        #expect(library.imports.count == 3)
    }

    @Test func renamedFileInNewExportIsRecognizedByContent() async throws {
        try fixture.file("export-1/Party/IMG.jpg", "same bytes")
        let library = FakeLibrary()
        let sync = sync(library, store: try SyncStore(url: nil))
        _ = try await sync.run(album: try scan("export-1"), newAlbumTitle: "Party")

        // The next export numbers the same photo differently.
        try fixture.file("export-2/Party/IMG(1).jpg", "same bytes")
        try fixture.file("export-2/Party/new.jpg", "new bytes")
        let second = try await sync.run(album: try scan("export-2"), newAlbumTitle: "Party")
        #expect(second.skippedCount == 1)
        #expect(Array(second.importedItems.keys) == ["Party/new.jpg"])

        // Known by ID from now on, without hashing again.
        let third = try await sync.run(album: try scan("export-2"), newAlbumTitle: "Party")
        #expect(third.skippedCount == 2)
        #expect(third.importedItems.isEmpty)
    }

    @Test func deletedAppleAlbumStartsOver() async throws {
        try fixture.file("Google Photos/Party/a.jpg", "A")
        let library = FakeLibrary()
        let sync = sync(library, store: try SyncStore(url: nil))
        let first = try await sync.run(album: try scan(), newAlbumTitle: "Party")
        library.deleteAlbum(id: first.albumID)
        #expect(try await sync.preview(album: try scan()) == .newAlbum)

        let second = try await sync.run(album: try scan(), newAlbumTitle: "Party again")
        #expect(second.albumTitle == "Party again")
        #expect(second.importedCount == 1)
        #expect(second.skippedCount == 0)
    }

    @Test func skippedItemsCountTowardProgress() async throws {
        try fixture.file("Google Photos/Party/a.jpg", "A")
        try fixture.file("Google Photos/Party/b.jpg", "B")
        let library = FakeLibrary()
        let sync = sync(library, store: try SyncStore(url: nil))
        _ = try await sync.run(album: try scan(), newAlbumTitle: "Party")

        let updates = Locked<[TransferProgress]>([])
        _ = try await sync.run(album: try scan(), newAlbumTitle: "Party") { p in updates.withValue { $0.append(p) } }
        let last = try #require(updates.current.last)
        #expect(last.skipped == 2)
        #expect(last.fractionCompleted == 1)
    }
}
