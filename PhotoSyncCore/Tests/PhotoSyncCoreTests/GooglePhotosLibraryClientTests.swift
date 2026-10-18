import Foundation
import Testing
@testable import PhotoSyncCore

@Suite struct GooglePhotosLibraryClientTests {
    static let noWait = RetryPolicy(maxAttempts: 3, sleep: { _ in })

    static func client(_ http: MockHTTPClient, tokens: Locked<[Bool]> = Locked([])) -> GooglePhotosLibraryClient {
        GooglePhotosLibraryClient(httpClient: http, retryPolicy: noWait) { force in
            tokens.withValue { $0.append(force) }
            return force ? "fresh-token" : "token"
        }
    }

    @Test func createAlbum() async throws {
        let http = MockHTTPClient { _ in
            .json(#"{"id":"album-1","title":"Trip","productUrl":"https://photos.google.com/lr/album/album-1"}"#)
        }
        let album = try await Self.client(http).createAlbum(title: "Trip")
        #expect(album == GoogleAlbum(id: "album-1", title: "Trip",
                                     productUrl: URL(string: "https://photos.google.com/lr/album/album-1")))
        let request = try #require(http.requests.first)
        #expect(request.request.httpMethod == "POST")
        #expect(request.path == "/v1/albums")
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect((request.bodyJSON["album"] as? [String: Any])?["title"] as? String == "Trip")
    }

    @Test func uploadSendsRawBytesWithHeaders() async throws {
        let http = MockHTTPClient { _ in .init(body: Data("upload-token-1\n".utf8)) }
        let file = URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")
        let token = try await Self.client(http).uploadFile(at: file, fileName: "Café.HEIC", mimeType: "image/heic")
        #expect(token == "upload-token-1")
        let request = try #require(http.requests.first)
        #expect(request.path == "/v1/uploads")
        #expect(request.uploadedFile == file)
        #expect(request.request.value(forHTTPHeaderField: "X-Goog-Upload-Protocol") == "raw")
        #expect(request.request.value(forHTTPHeaderField: "X-Goog-Upload-Content-Type") == "image/heic")
        #expect(request.request.value(forHTTPHeaderField: "X-Goog-Upload-File-Name") == "Caf%C3%A9.HEIC")
    }

    @Test func batchCreateMapsPartialFailures() async throws {
        let http = MockHTTPClient { _ in
            .json("""
            {"newMediaItemResults":[
              {"uploadToken":"t1","status":{"message":"Success"},"mediaItem":{"id":"m1"}},
              {"uploadToken":"t2","status":{"code":3,"message":"Failed: There was an error while trying to create this media item."}}
            ]}
            """, status: 207)
        }
        let results = try await Self.client(http).batchCreate(albumID: "album-1", items: [
            NewMediaItem(uploadToken: "t1", fileName: "a.jpg", description: "Rome"),
            NewMediaItem(uploadToken: "t2", fileName: "b.jpg"),
        ])
        #expect(results == [
            NewMediaItemResult(uploadToken: "t1", status: .created(mediaItemID: "m1")),
            NewMediaItemResult(uploadToken: "t2", status: .failed(
                message: "Failed: There was an error while trying to create this media item.")),
        ])
        let body = try #require(http.requests.first).bodyJSON
        #expect(body["albumId"] as? String == "album-1")
        let items = try #require(body["newMediaItems"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items[0]["description"] as? String == "Rome")
        #expect(items[1]["description"] == nil)
        #expect((items[0]["simpleMediaItem"] as? [String: Any])?["fileName"] as? String == "a.jpg")
    }

    @Test func retriesTransientErrors() async throws {
        let calls = Locked(0)
        let http = MockHTTPClient { _ in
            let call = calls.withValue { $0 += 1; return $0 }
            if call == 1 { throw URLError(.networkConnectionLost) }
            if call == 2 { return .json(#"{"error":{"code":429,"message":"Quota"}}"#, status: 429) }
            return .json(#"{"id":"a","title":"T"}"#)
        }
        _ = try await Self.client(http).createAlbum(title: "T")
        #expect(calls.current == 3)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let http = MockHTTPClient { _ in .json(#"{"error":{"code":503,"message":"Backend Error"}}"#, status: 503) }
        await #expect(throws: GoogleAPIError(statusCode: 503, message: "Backend Error")) {
            try await Self.client(http).createAlbum(title: "T")
        }
        #expect(http.requests.count == 3)
    }

    @Test func unauthorizedForcesOneTokenRefresh() async throws {
        let tokens = Locked<[Bool]>([])
        let http = MockHTTPClient { recorded in
            recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token"
                ? .json(#"{"id":"a","title":"T"}"#)
                : .json(#"{"error":{"code":401,"message":"Unauthenticated"}}"#, status: 401)
        }
        _ = try await Self.client(http, tokens: tokens).createAlbum(title: "T")
        #expect(tokens.current == [false, true])
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let http = MockHTTPClient { _ in .json(#"{"error":{"code":400,"message":"Invalid album title"}}"#, status: 400) }
        await #expect(throws: GoogleAPIError(statusCode: 400, message: "Invalid album title")) {
            try await Self.client(http).createAlbum(title: "")
        }
        #expect(http.requests.count == 1)
    }

    @Test func backoffGrowsAndHonorsRetryAfter() {
        let policy = RetryPolicy(baseDelay: .seconds(1), maxDelay: .seconds(8))
        #expect((Duration.milliseconds(500)...Duration.seconds(1)).contains(policy.delay(forAttempt: 1, retryAfter: nil)))
        #expect((Duration.seconds(2)...Duration.seconds(4)).contains(policy.delay(forAttempt: 3, retryAfter: nil)))
        #expect((Duration.seconds(4)...Duration.seconds(8)).contains(policy.delay(forAttempt: 10, retryAfter: nil)))
        #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(3)) == .seconds(3))
    }
}
