import Foundation
import Testing
@testable import PhotoSyncCore

/// Writes a small file per item; fails for IDs in `failing`.
struct FakeSource: TransferSource {
    var failing: Set<String> = []

    struct ExportError: Error, LocalizedError {
        var errorDescription: String? { "Not downloaded from iCloud" }
    }

    func export(_ item: TransferItem, into directory: URL) async throws -> ExportedFile {
        if failing.contains(item.id) { throw ExportError() }
        let url = directory.appending(path: item.fileName)
        try Data("bytes of \(item.id)".utf8).write(to: url)
        return ExportedFile(url: url, fileName: item.fileName, mimeType: "image/jpeg")
    }
}

@Suite struct GoogleAlbumUploaderTests {
    let temp: URL

    init() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "UploaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    /// Fake Google: uploads return `tok-<file name>`; batchCreate fails items named in `rejected`.
    static func fakeGoogle(rejected: Set<String> = []) -> MockHTTPClient {
        MockHTTPClient { recorded in
            switch recorded.path {
            case "/v1/albums":
                return .json(#"{"id":"album-1","title":"Trip"}"#)
            case "/v1/uploads":
                let name = recorded.request.value(forHTTPHeaderField: "X-Goog-Upload-File-Name")!
                #expect(FileManager.default.fileExists(atPath: recorded.uploadedFile!.path))
                return .init(body: Data("tok-\(name)".utf8))
            case "/v1/mediaItems:batchCreate":
                let items = recorded.bodyJSON["newMediaItems"] as! [[String: Any]]
                let results = items.map { item -> String in
                    let simple = item["simpleMediaItem"] as! [String: String]
                    let token = simple["uploadToken"]!
                    return rejected.contains(simple["fileName"]!)
                        ? #"{"uploadToken":"\#(token)","status":{"code":3,"message":"Rejected"}}"#
                        : #"{"uploadToken":"\#(token)","status":{"message":"Success"},"mediaItem":{"id":"m-\#(token)"}}"#
                }
                return .json(#"{"newMediaItemResults":[\#(results.joined(separator: ","))]}"#)
            default:
                return .init(status: 404)
            }
        }
    }

    static func items(_ count: Int) -> [TransferItem] {
        (1...count).map { TransferItem(id: "id-\($0)", fileName: "IMG_\($0).jpg", kind: .photo) }
    }

    @Test func uploadsInBatchesAndCollectsFailures() async throws {
        let http = Self.fakeGoogle(rejected: ["IMG_7.jpg"])
        let client = GooglePhotosLibraryClient(httpClient: http, retryPolicy: .init(sleep: { _ in })) { _ in "t" }
        let uploader = GoogleAlbumUploader(client: client, temporaryDirectory: temp)
        let updates = Locked<[TransferProgress]>([])

        let report = try await uploader.transfer(
            Self.items(120), toNewAlbumTitled: "Trip", from: FakeSource(failing: ["id-3"])
        ) { progress in updates.withValue { $0.append(progress) } }

        #expect(report.album.id == "album-1")
        #expect(report.addedItems.count == 118)
        #expect(report.addedItems["id-1"] == "m-tok-IMG_1.jpg")
        #expect(report.failures.map(\.itemID).sorted() == ["id-3", "id-7"])
        #expect(report.failures.first { $0.itemID == "id-3" }?.message == "Not downloaded from iCloud")
        #expect(!report.wasCancelled)

        let batches = http.requests.filter { $0.path == "/v1/mediaItems:batchCreate" }
        #expect(batches.map { ($0.bodyJSON["newMediaItems"] as! [Any]).count } == [50, 50, 19])
        #expect(batches.allSatisfy { $0.bodyJSON["albumId"] as? String == "album-1" })

        let last = try #require(updates.current.last)
        #expect(last.total == 120)
        #expect(last.added == 118)
        #expect(last.failed == 2)
        #expect(last.uploaded == 119)
        #expect(last.fractionCompleted == 1)

        // Exported files are cleaned up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }

    @Test func failedBatchMarksAllItsItemsFailed() async throws {
        let http = MockHTTPClient { recorded in
            switch recorded.path {
            case "/v1/albums": .json(#"{"id":"album-1","title":"Trip"}"#)
            case "/v1/uploads": .init(body: Data("tok".utf8))
            default: .json(#"{"error":{"code":400,"message":"Bad batch"}}"#, status: 400)
            }
        }
        let client = GooglePhotosLibraryClient(httpClient: http, retryPolicy: .init(sleep: { _ in })) { _ in "t" }
        let report = try await GoogleAlbumUploader(client: client, temporaryDirectory: temp)
            .transfer(Self.items(3), toNewAlbumTitled: "Trip", from: FakeSource())
        #expect(report.addedItems.isEmpty)
        #expect(report.failures.count == 3)
        #expect(report.failures[0].message.contains("Bad batch"))
    }

    @Test func albumCreationFailureAbortsTransfer() async throws {
        let http = MockHTTPClient { _ in .json(#"{"error":{"code":403,"message":"Insufficient scopes"}}"#, status: 403) }
        let client = GooglePhotosLibraryClient(httpClient: http) { _ in "t" }
        await #expect(throws: GoogleAPIError.self) {
            try await GoogleAlbumUploader(client: client, temporaryDirectory: temp)
                .transfer(Self.items(2), toNewAlbumTitled: "Trip", from: FakeSource())
        }
        #expect(http.requests.count == 1)
    }
}
