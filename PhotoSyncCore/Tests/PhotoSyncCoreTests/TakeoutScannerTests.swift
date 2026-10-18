import Foundation
import Testing
@testable import PhotoSyncCore

/// Builds a fake Takeout export in a temporary directory.
final class TakeoutFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeoutFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ path: String, _ contents: String = "media") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func sidecar(
        _ path: String,
        title: String,
        taken: Int = 1_577_880_000,
        latitude: Double = 0,
        longitude: Double = 0,
        description: String = ""
    ) throws {
        try file(path, """
        {
          "title": "\(title)",
          "description": "\(description)",
          "imageViews": "3",
          "creationTime": { "timestamp": "1600000000", "formatted": "13.09.2020, 12:26:40 UTC" },
          "photoTakenTime": { "timestamp": "\(taken)", "formatted": "01.01.2020, 12:00:00 UTC" },
          "geoData": { "latitude": \(latitude), "longitude": \(longitude), "altitude": 0.0,
                       "latitudeSpan": 0.0, "longitudeSpan": 0.0 },
          "people": [{ "name": "Alice" }],
          "url": "https://photos.google.com/photo/abc"
        }
        """)
    }

    func albumMetadata(_ path: String, title: String) throws {
        try file(path, """
        { "title": "\(title)", "description": "", "access": "protected",
          "date": { "timestamp": "1577880000", "formatted": "01.01.2020" } }
        """)
    }
}

@Suite struct TakeoutScannerTests {
    let fixture: TakeoutFixture

    init() throws {
        fixture = try TakeoutFixture()
    }

    private func scan() throws -> TakeoutLibrary {
        try TakeoutScanner().scan(root: fixture.root)
    }

    private func album(_ id: String, in library: TakeoutLibrary) throws -> TakeoutAlbum {
        try #require(library.albums.first { $0.id == id })
    }

    @Test func albumWithMetadataAndSidecars() throws {
        let dir = "Takeout/Google Photos/Trip 2020"
        try fixture.albumMetadata("\(dir)/metadata.json", title: "Trip: Italy / 2020")
        try fixture.file("\(dir)/IMG_1.jpg")
        try fixture.sidecar("\(dir)/IMG_1.jpg.json", title: "IMG_1.jpg", latitude: 41.9, longitude: 12.5,
                            description: "Rome")
        try fixture.file("\(dir)/VID_2.mp4")
        try fixture.sidecar("\(dir)/VID_2.mp4.supplemental-metadata.json", title: "VID_2.mp4", taken: 1_577_890_000)
        try fixture.file("\(dir)/notes.html", "<html/>")

        let library = try scan()
        let trip = try album("Trip 2020", in: library)
        #expect(trip.title == "Trip: Italy / 2020")
        #expect(trip.kind == .album)
        #expect(trip.photoCount == 1)
        #expect(trip.videoCount == 1)
        #expect(trip.assetsWithoutMetadata == 0)
        #expect(trip.unmatchedSidecars.isEmpty)

        let photo = trip.assets[0]
        #expect(photo.primaryFile.lastPathComponent == "IMG_1.jpg")
        #expect(photo.id == "Trip 2020/IMG_1.jpg")
        #expect(photo.metadata?.description == "Rome")
        #expect(photo.metadata?.location == GeoLocation(latitude: 41.9, longitude: 12.5))
        #expect(photo.metadata?.people == ["Alice"])
        #expect(photo.captureDate == Date(timeIntervalSince1970: 1_577_880_000))
        #expect(trip.assets[1].kind == .video)
    }

    @Test func localizedAlbumMetadataFileAndFolderNameFallback() throws {
        try fixture.albumMetadata("Google Fotos/Urlaub/Metadaten.json", title: "Urlaub am Meer")
        try fixture.file("Google Fotos/Urlaub/a.jpg")
        try fixture.file("Google Fotos/Untitled/b.jpg")

        let library = try scan()
        #expect(try album("Urlaub", in: library).title == "Urlaub am Meer")
        #expect(try album("Untitled", in: library).title == "Untitled")
    }

    @Test func folderKinds() throws {
        try fixture.file("Google Photos/Photos from 2019/a.jpg")
        try fixture.file("Google Photos/Fotos von 2021/b.jpg")
        try fixture.file("Google Photos/Archive/c.jpg")
        try fixture.file("Google Photos/Papierkorb/d.jpg")
        try fixture.file("Google Photos/Zoo/e.jpg")
        try fixture.file("Google Photos/Album/f.jpg")

        let library = try scan()
        #expect(library.albums.map(\.id) == [
            "Album", "Zoo", "Fotos von 2021", "Photos from 2019", "Archive", "Papierkorb",
        ])
        #expect(try album("Photos from 2019", in: library).kind == .year(2019))
        #expect(try album("Fotos von 2021", in: library).kind == .year(2021))
        #expect(try album("Archive", in: library).kind == .archive)
        #expect(try album("Papierkorb", in: library).kind == .trash)
    }

    @Test func splitArchivesAreMerged() throws {
        try fixture.file("takeout-001/Takeout/Google Photos/Trip/IMG_1.jpg")
        try fixture.file("takeout-002/Takeout/Google Photos/Trip/IMG_2.jpg")
        try fixture.sidecar("takeout-002/Takeout/Google Photos/Trip/IMG_1.jpg.json", title: "IMG_1.jpg")
        try fixture.albumMetadata("takeout-002/Takeout/Google Photos/Trip/metadata.json", title: "The Trip")

        let library = try scan()
        #expect(library.albums.count == 1)
        let trip = try album("Trip", in: library)
        #expect(trip.title == "The Trip")
        #expect(trip.folderURLs.count == 2)
        #expect(trip.assets.count == 2)
        let first = try #require(trip.assets.first { $0.primaryFile.lastPathComponent == "IMG_1.jpg" })
        #expect(first.metadata != nil)
        #expect(first.sidecarFile?.path.contains("takeout-002") == true)
    }

    @Test func editedCopyIsGroupedWithOriginal() throws {
        let dir = "Google Photos/Edits"
        try fixture.file("\(dir)/IMG.jpg")
        try fixture.file("\(dir)/IMG-edited.jpg")
        try fixture.sidecar("\(dir)/IMG.jpg.json", title: "IMG.jpg")

        let edits = try album("Edits", in: try scan())
        #expect(edits.assets.count == 1)
        #expect(edits.assets[0].primaryFile.lastPathComponent == "IMG.jpg")
        #expect(edits.assets[0].editedFile?.lastPathComponent == "IMG-edited.jpg")
        #expect(edits.assets[0].metadata != nil)
    }

    @Test func livePhotoIsPaired() throws {
        let dir = "Google Photos/Live"
        try fixture.file("\(dir)/IMG_1234.HEIC")
        try fixture.file("\(dir)/IMG_1234.MOV")
        try fixture.sidecar("\(dir)/IMG_1234.HEIC.json", title: "IMG_1234.HEIC")
        // A video with its own sidecar stays a separate item.
        try fixture.file("\(dir)/IMG_5678.JPG")
        try fixture.file("\(dir)/IMG_5678.MP4")
        try fixture.sidecar("\(dir)/IMG_5678.JPG.json", title: "IMG_5678.JPG")
        try fixture.sidecar("\(dir)/IMG_5678.MP4.json", title: "IMG_5678.MP4")

        let live = try album("Live", in: try scan())
        #expect(live.assets.count == 3)
        let paired = try #require(live.assets.first { $0.primaryFile.lastPathComponent == "IMG_1234.HEIC" })
        #expect(paired.pairedVideoFile?.lastPathComponent == "IMG_1234.MOV")
        #expect(live.videoCount == 1)
    }

    @Test func missingSidecarsAreCountedAndOrphansReported() throws {
        let dir = "Google Photos/Messy"
        try fixture.file("\(dir)/a.jpg")
        try fixture.file("\(dir)/b.jpg")
        try fixture.sidecar("\(dir)/a.jpg.json", title: "a.jpg", taken: 2_000_000_000)
        try fixture.sidecar("\(dir)/zzz.jpg.json", title: "zzz.jpg")

        let messy = try album("Messy", in: try scan())
        #expect(messy.assetsWithoutMetadata == 1)
        #expect(messy.unmatchedSidecars.map(\.lastPathComponent) == ["zzz.jpg.json"])
        // Items with a capture date sort before those without.
        #expect(messy.assets.map(\.primaryFile.lastPathComponent) == ["a.jpg", "b.jpg"])
    }

    @Test func foldersWithoutMediaAreSkipped() throws {
        try fixture.file("Takeout/archive_browser.html", "<html/>")
        try fixture.file("Takeout/Google Photos/print-subscriptions.json", "{}")
        try fixture.albumMetadata("Takeout/Google Photos/Empty/metadata.json", title: "Empty")

        #expect(try scan().albums.isEmpty)
    }
}

@Suite struct TakeoutMetadataTests {
    @Test func zeroGeoDataFallsBackToExif() throws {
        let json = """
        { "title": "a.jpg", "photoTakenTime": { "timestamp": 1577880000 },
          "geoData": { "latitude": 0.0, "longitude": 0.0, "altitude": 0.0 },
          "geoDataExif": { "latitude": 52.52, "longitude": 13.4, "altitude": 34.0 },
          "favorited": true }
        """
        guard case .sidecar(let metadata) = TakeoutJSONDocument.parse(Data(json.utf8)) else {
            Issue.record("expected sidecar")
            return
        }
        #expect(metadata.location == GeoLocation(latitude: 52.52, longitude: 13.4, altitude: 34))
        #expect(metadata.photoTakenTime == Date(timeIntervalSince1970: 1_577_880_000))
        #expect(metadata.isFavorite)
        #expect(metadata.description == nil)
    }

    @Test func classification() {
        #expect(TakeoutJSONDocument.parse(Data(#"{"title":"Album"}"#.utf8))
            == .album(TakeoutAlbumMetadata(title: "Album", description: nil)))
        #expect(TakeoutJSONDocument.parse(Data("{}".utf8)) == .other)
        #expect(TakeoutJSONDocument.parse(Data("not json".utf8)) == .other)
    }
}
