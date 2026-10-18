import Foundation
import Testing
@testable import PhotoSyncCore

/// Fake Picker API: one session that is picked after `pollsUntilPicked` polls,
/// with `items` listed `pageSize` per page.
final class FakePicker: @unchecked Sendable {
    struct Item { var id: String; var name: String; var video = false; var ready = true; var time = "2016-12-16T18:46:03Z" }

    let items: [Item]
    var pollsUntilPicked = 2
    var pageSize = 2
    private let lock = NSLock()
    private var polls = 0
    private var listCalls = 0
    var listCount: Int { lock.withLock { listCalls } }

    init(_ items: [Item]) { self.items = items }

    lazy var http = MockHTTPClient { [unowned self] recorded in try self.reply(recorded) }

    func json(_ item: Item) -> String {
        let metadata = item.video
            ? #","mediaFileMetadata":{"videoMetadata":{"processingStatus":"\#(item.ready ? "READY" : "PROCESSING")"}}"#
            : ""
        return #"""
        {"id":"\#(item.id)","createTime":"\#(item.time)","type":"\#(item.video ? "VIDEO" : "PHOTO")",
         "mediaFile":{"baseUrl":"https://lh3.googleusercontent.com/\#(item.id)","mimeType":"\#(item.video ? "video/quicktime" : "image/jpeg")","filename":"\#(item.name)"\#(metadata)}}
        """#
    }

    private func reply(_ recorded: MockHTTPClient.Recorded) throws -> MockHTTPClient.Reply {
        let url = recorded.request.url!
        switch (recorded.request.httpMethod ?? "GET", url.host, url.path) {
        case ("POST", _, "/v1/sessions"):
            return .json(#"{"id":"s1","pickerUri":"https://photos.google.com/picker/s1","pollingConfig":{"pollInterval":"2.5s","timeoutIn":"1800s"},"expireTime":"2026-10-19T10:00:00.123Z","mediaItemsSet":false}"#)
        case ("GET", _, "/v1/sessions/s1"):
            let picked = lock.withLock { polls += 1; return polls >= pollsUntilPicked }
            return .json(picked
                ? #"{"id":"s1","pickerUri":"https://photos.google.com/picker/s1","mediaItemsSet":true}"#
                : #"{"id":"s1","pickerUri":"https://photos.google.com/picker/s1","pollingConfig":{"pollInterval":"2.5s","timeoutIn":"1800s"},"mediaItemsSet":false}"#)
        case ("DELETE", _, "/v1/sessions/s1"):
            return .json("{}")
        case ("GET", _, "/v1/mediaItems"):
            lock.withLock { listCalls += 1 }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            #expect(query.first { $0.name == "sessionId" }?.value == "s1")
            let start = Int(query.first { $0.name == "pageToken" }?.value ?? "0")!
            let page = items[start..<min(start + pageSize, items.count)]
            let next = start + pageSize < items.count ? #","nextPageToken":"\#(start + pageSize)""# : ""
            return .json(#"{"mediaItems":[\#(page.map(json).joined(separator: ","))]\#(next)}"#)
        case ("GET", "lh3.googleusercontent.com", _):
            let last = url.lastPathComponent
            if last.hasSuffix("=dv") {
                return .init(body: Data("video \(last)".utf8), headers: ["Content-Type": "video/mp4"])
            }
            return .init(body: Data("photo \(last)".utf8), headers: ["Content-Type": "image/jpeg"])
        default:
            return .init(status: 404)
        }
    }
}

@Suite struct GooglePhotosPickerClientTests {
    static func client(_ http: MockHTTPClient) -> GooglePhotosPickerClient {
        GooglePhotosPickerClient(httpClient: http, retryPolicy: .init(sleep: { _ in })) { _ in "token" }
    }

    @Test func createSessionAndWaitForPicking() async throws {
        let picker = FakePicker([])
        picker.pollsUntilPicked = 3
        let client = Self.client(picker.http)

        let session = try await client.createSession()
        #expect(session.id == "s1")
        #expect(session.autoclosePickerURL.absoluteString == "https://photos.google.com/picker/s1/autoclose")
        #expect(session.expireTime != nil)
        let body = try #require(picker.http.requests.first).bodyJSON
        #expect((body["pickingConfig"] as? [String: Any])?["maxItemCount"] as? String == "2000")

        let sleeps = Locked<[Duration]>([])
        let picked = try await client.waitForPicking(session) { d in sleeps.withValue { $0.append(d) } }
        #expect(picked.isPicked)
        #expect(sleeps.current == [.milliseconds(2500), .milliseconds(2500), .milliseconds(2500)])
    }

    @Test func zeroTimeoutStopsPolling() async throws {
        let session = PickerSession(id: "s1", pickerUri: URL(string: "https://photos.google.com/picker/s1")!,
                                    pollingConfig: .init(pollInterval: "1s", timeoutIn: "0s"),
                                    expireTime: nil, mediaItemsSet: false)
        await #expect(throws: PickerError.timedOut) {
            try await Self.client(FakePicker([]).http).waitForPicking(session) { _ in }
        }
    }

    @Test func listsAllPages() async throws {
        let picker = FakePicker((1...5).map { .init(id: "i\($0)", name: "IMG_\($0).jpg") })
        let items = try await Self.client(picker.http).mediaItems(sessionID: "s1")
        #expect(items.map(\.id) == ["i1", "i2", "i3", "i4", "i5"])
        #expect(picker.listCount == 3)
        #expect(items[0].createTime == Date(timeIntervalSince1970: 1_481_913_963))
        #expect(items[0].kind == .photo)
    }

    @Test func downloadsPhotosAndTranscodedVideos() async throws {
        let picker = FakePicker([.init(id: "p", name: "IMG.jpg"), .init(id: "v", name: "VID.MOV", video: true)])
        let client = Self.client(picker.http)
        let items = try await client.mediaItems(sessionID: "s1")
        let dir = FileManager.default.temporaryDirectory.appending(path: "PickerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let photo = try await client.download(items[0], into: dir)
        #expect(photo.lastPathComponent == "IMG.jpg")
        #expect(try String(contentsOf: photo, encoding: .utf8) == "photo p=d")
        let video = try await client.download(items[1], into: dir)
        #expect(video.lastPathComponent == "VID.mp4")
        #expect(try String(contentsOf: video, encoding: .utf8) == "video v=dv")
        let auth = picker.http.requests.last?.request.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer token")
    }

    @Test func unprocessedVideoIsNotDownloaded() async throws {
        let picker = FakePicker([.init(id: "v", name: "VID.mp4", video: true, ready: false)])
        let client = Self.client(picker.http)
        let item = try #require(try await client.mediaItems(sessionID: "s1").first)
        await #expect(throws: PickerError.videoNotReady) {
            try await client.download(item, into: FileManager.default.temporaryDirectory)
        }
    }

    @Test func helpers() {
        #expect(GooglePhotosPickerClient.duration("5s") == .seconds(5))
        #expect(GooglePhotosPickerClient.duration("3.5s") == .milliseconds(3500))
        #expect(GooglePhotosPickerClient.duration("soon") == nil)
        #expect(GooglePhotosPickerClient.fileName("a.MOV", mimeType: "video/mp4") == "a.mp4")
        #expect(GooglePhotosPickerClient.fileName("a.JPG", mimeType: "image/jpeg") == "a.JPG")
        #expect(GooglePhotosPickerClient.fileName("3806", mimeType: "image/jpeg") == "3806.jpeg")
    }
}

@Suite struct PickerImportTests {
    let temp: URL

    init() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "PickerImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    func makeSync(_ picker: FakePicker, _ library: FakeLibrary, store: SyncStore,
                  now: @escaping @Sendable () -> Date = Date.init) -> PickerToAppleSync {
        let client = GooglePhotosPickerClient(httpClient: picker.http, retryPolicy: .init(sleep: { _ in })) { _ in "t" }
        return PickerToAppleSync(store: store, destination: library,
                                 importer: PickerImporter(client: client, temporaryDirectory: temp, now: now))
    }

    func items(_ picker: FakePicker) async throws -> [PickedMediaItem] {
        try await GooglePhotosPickerClient(httpClient: picker.http) { _ in "t" }.mediaItems(sessionID: "s1")
    }

    @Test func importsWithCaptureDateAndSkipsOnSecondPick() async throws {
        let picker = FakePicker([.init(id: "a", name: "a.jpg"), .init(id: "b", name: "b.MOV", video: true)])
        let library = FakeLibrary()
        let store = try SyncStore(url: nil)
        let sync = makeSync(picker, library, store: store)
        let picked = try await items(picker)

        let first = try await sync.run(sessionID: "s1", items: picked, listedAt: Date(), albumTitle: "Weekend")
        #expect(first.importedCount == 2)
        #expect(library.albums == ["Weekend"])
        #expect(library.imports.map(\.originalFileName) == ["a.jpg", "b.mp4"])
        #expect(library.imports.map(\.kind) == [.photo, .video])
        #expect(library.imports.allSatisfy { $0.creationDate == Date(timeIntervalSince1970: 1_481_913_963) })
        #expect(library.imports.allSatisfy { $0.location == nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)

        // Picking the same items into the same album name (any case) adds nothing.
        #expect(try await sync.preview(albumTitle: " weekend ", itemIDs: ["a", "b", "c"]).alreadySyncedCount == 2)
        let second = try await sync.run(sessionID: "s1", items: picked, listedAt: Date(), albumTitle: "WEEKEND")
        #expect(second.skippedCount == 2)
        #expect(second.albumID == first.albumID)
        #expect(library.albums == ["Weekend"])

        // Another album name is a separate history.
        #expect(try await sync.preview(albumTitle: "Other", itemIDs: ["a"]) == .newAlbum)
    }

    @Test func relistsItemsBeforeBaseURLsExpire() async throws {
        let picker = FakePicker([.init(id: "a", name: "a.jpg"), .init(id: "b", name: "b.jpg")])
        picker.pageSize = 10
        let clock = Locked(Date(timeIntervalSince1970: 0))
        let sync = makeSync(picker, FakeLibrary(), store: try SyncStore(url: nil)) {
            // Each check moves time forward 30 minutes.
            clock.withValue { $0 += 30 * 60; return $0 }
        }
        let picked = try await items(picker)
        let before = picker.listCount
        let report = try await sync.run(sessionID: "s1", items: picked, listedAt: Date(timeIntervalSince1970: 0),
                                        albumTitle: "Weekend")
        #expect(report.importedCount == 2)
        #expect(picker.listCount > before)
    }

    @Test func failuresAreReportedAndRetriedLater() async throws {
        let picker = FakePicker([.init(id: "a", name: "a.jpg"),
                                 .init(id: "v", name: "v.mp4", video: true, ready: false)])
        let library = FakeLibrary()
        let sync = makeSync(picker, library, store: try SyncStore(url: nil))
        let report = try await sync.run(sessionID: "s1", items: try await items(picker), listedAt: Date(),
                                        albumTitle: "Weekend")
        #expect(report.importedCount == 1)
        #expect(report.failures.map(\.fileName) == ["v.mp4"])
        #expect(try await sync.preview(albumTitle: "Weekend", itemIDs: ["a", "v"]).alreadySyncedCount == 1)
    }
}
