import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoSyncCore

/// Records imports; rejects Live Photo pairs and files named in `rejected`.
final class FakeLibrary: PhotoLibraryDestination, @unchecked Sendable {
    struct Rejected: Error, LocalizedError { var errorDescription: String? { "Unsupported file" } }

    var rejectsLivePhotos = false
    var rejected: Set<String> = []
    private let lock = NSLock()
    private var _albums: [String] = []
    private var _imports: [AssetImportRequest] = []

    private var _deletedAlbums: Set<String> = []

    var albums: [String] { lock.withLock { _albums } }

    /// Simulates the user deleting an album in Photos.
    func deleteAlbum(id: String) { lock.withLock { _ = _deletedAlbums.insert(id) } }

    func albumExists(id: String) async -> Bool {
        lock.withLock { _albums.contains { "album-\($0)" == id } && !_deletedAlbums.contains(id) }
    }
    var imports: [AssetImportRequest] { lock.withLock { _imports } }

    func createAlbum(title: String) async throws -> String {
        lock.withLock { _albums.append(title) }
        return "album-\(title)"
    }

    func importAsset(_ request: AssetImportRequest, intoAlbum albumID: String) async throws -> String {
        if rejected.contains(request.originalFileName) { throw Rejected() }
        if rejectsLivePhotos && request.pairedVideoFile != nil { throw Rejected() }
        // The file must still exist while PhotoKit reads it.
        #expect(FileManager.default.fileExists(atPath: request.file.path))
        return lock.withLock {
            _imports.append(request)
            return "asset-\(_imports.count)"
        }
    }
}

enum TestImages {
    /// Writes a small solid-color image of the given type.
    static func write(to url: URL, type: UTType = .jpeg) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func description(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?
    }

    static func iptcCaption(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else { return nil }
        return iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
    }

}

@Suite struct TakeoutAlbumImporterTests {
    let fixture: TakeoutFixture
    let temp: URL

    init() throws {
        fixture = try TakeoutFixture()
        temp = fixture.root.appending(path: "work")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    private func scanAlbum(_ id: String) throws -> TakeoutAlbum {
        let library = try TakeoutScanner().scan(root: fixture.root.appending(path: "Google Photos"))
        return try #require(library.albums.first { $0.id == id })
    }

    @Test func restoresDateLocationAndFavorite() async throws {
        try TestImages.write(to: fixture.root.appending(path: "Google Photos/Trip/IMG_1.jpg"))
        try fixture.file("Google Photos/Trip/IMG_1.jpg.json", """
        { "title": "IMG_1.jpg", "favorited": true,
          "photoTakenTime": { "timestamp": "1482000000" },
          "creationTime": { "timestamp": "1600000000" },
          "geoData": { "latitude": 49.6, "longitude": 6.1, "altitude": 300 } }
        """)
        try fixture.file("Google Photos/Trip/VID_2.mp4")
        let library = FakeLibrary()

        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Trip"), title: "Trip 2016", into: library)

        #expect(library.albums == ["Trip 2016"])
        #expect(report.albumID == "album-Trip 2016")
        #expect(report.importedCount == 2)
        #expect(report.failures.isEmpty)
        let photo = try #require(library.imports.first { $0.originalFileName == "IMG_1.jpg" })
        #expect(photo.creationDate == Date(timeIntervalSince1970: 1_482_000_000))
        #expect(photo.location == GeoLocation(latitude: 49.6, longitude: 6.1, altitude: 300))
        #expect(photo.isFavorite)
        #expect(photo.kind == .photo)
        // Without a sidecar, the date is left for Photos to read from the file.
        let video = try #require(library.imports.first { $0.originalFileName == "VID_2.mp4" })
        #expect(video.creationDate == nil)
        #expect(video.kind == .video)
    }

    @Test func writesDescriptionIntoACopyOfJPEG() async throws {
        let original = fixture.root.appending(path: "Google Photos/Trip/IMG_1.jpg")
        try TestImages.write(to: original)
        try fixture.sidecar("Google Photos/Trip/IMG_1.jpg.json", title: "IMG_1.jpg", description: "Schöne Feier 🎄")
        let library = FakeLibrary()

        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Trip"), title: "Trip", into: library)

        #expect(report.warnings.isEmpty)
        let imported = try #require(library.imports.first)
        #expect(imported.file != original)
        #expect(imported.originalFileName == "IMG_1.jpg")
        #expect(TestImages.description(of: original) == nil)
    }

    @Test func metadataWriterSetsXMPAndIPTCCaption() throws {
        let original = temp.appending(path: "in.jpg"), copy = temp.appending(path: "out.jpg")
        try TestImages.write(to: original)
        try ImageMetadataWriter.copy(original, to: copy, settingDescription: "Schöne Feier 🎄")
        #expect(TestImages.description(of: copy) == "Schöne Feier 🎄")
        #expect(TestImages.iptcCaption(of: copy) == "Schöne Feier 🎄")
    }

    @Test func heicDescriptionBecomesWarning() async throws {
        try TestImages.write(to: fixture.root.appending(path: "Google Photos/Trip/IMG_1.heic"), type: .heic)
        try fixture.sidecar("Google Photos/Trip/IMG_1.heic.json", title: "IMG_1.heic", description: "Party")
        let library = FakeLibrary()
        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Trip"), title: "Trip", into: library)
        #expect(report.importedCount == 1)
        #expect(report.warnings.map(\.fileName) == ["IMG_1.heic"])
        #expect(library.imports.first?.file.path.contains("/Google Photos/") == true)
    }

    @Test func descriptionsCanBeSkipped() async throws {
        try TestImages.write(to: fixture.root.appending(path: "Google Photos/Trip/IMG_1.jpg"))
        try fixture.sidecar("Google Photos/Trip/IMG_1.jpg.json", title: "IMG_1.jpg", description: "Party")
        let library = FakeLibrary()
        _ = try await TakeoutAlbumImporter(temporaryDirectory: temp).importAlbum(
            try scanAlbum("Trip"), title: "Trip", into: library,
            options: TakeoutImportOptions(restoreDescriptions: false))
        #expect(library.imports.first?.file.lastPathComponent == "IMG_1.jpg")
        #expect(library.imports.first?.file.path.contains("/Google Photos/") == true)
    }

    @Test func unreadableImageStillImportsWithWarning() async throws {
        try fixture.file("Google Photos/Trip/broken.jpg", "not really a jpeg")
        try fixture.sidecar("Google Photos/Trip/broken.jpg.json", title: "broken.jpg", description: "Hi")
        let library = FakeLibrary()
        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Trip"), title: "Trip", into: library)
        #expect(report.importedCount == 1)
        #expect(report.warnings.map(\.fileName) == ["broken.jpg"])
    }

    @Test(arguments: [
        (EditedVersionPolicy.preferEdited, ["IMG-edited.jpg"]),
        (.originalOnly, ["IMG.jpg"]),
        (.both, ["IMG.jpg", "IMG-edited.jpg"]),
    ])
    func editedVersionPolicy(policy: EditedVersionPolicy, expected: [String]) async throws {
        try fixture.file("Google Photos/Edits/IMG.jpg")
        try fixture.file("Google Photos/Edits/IMG-edited.jpg")
        try fixture.sidecar("Google Photos/Edits/IMG.jpg.json", title: "IMG.jpg")
        let library = FakeLibrary()
        let album = try scanAlbum("Edits")
        let options = TakeoutImportOptions(editedVersions: policy)
        #expect(TakeoutAlbumImporter.itemCount(of: album, options: options) == expected.count)

        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(album, title: "Edits", into: library, options: options)
        #expect(library.imports.map(\.originalFileName) == expected)
        #expect(library.imports.allSatisfy { $0.creationDate != nil })
        #expect(report.importedItems["Edits/IMG.jpg"]?.count == expected.count)
    }

    @Test func livePhotoIsImportedAsPair() async throws {
        try fixture.file("Google Photos/Live/IMG_1234.HEIC")
        try fixture.file("Google Photos/Live/IMG_1234.MOV")
        try fixture.sidecar("Google Photos/Live/IMG_1234.HEIC.json", title: "IMG_1234.HEIC")
        let library = FakeLibrary()
        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Live"), title: "Live", into: library)
        #expect(library.imports.count == 1)
        #expect(library.imports[0].pairedVideoFile?.lastPathComponent == "IMG_1234.MOV")
        #expect(report.warnings.isEmpty)
    }

    @Test func rejectedLivePhotoFallsBackToSeparateItems() async throws {
        try fixture.file("Google Photos/Live/IMG_1234.HEIC")
        try fixture.file("Google Photos/Live/IMG_1234.MOV")
        try fixture.sidecar("Google Photos/Live/IMG_1234.HEIC.json", title: "IMG_1234.HEIC")
        let library = FakeLibrary()
        library.rejectsLivePhotos = true
        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp)
            .importAlbum(try scanAlbum("Live"), title: "Live", into: library)
        #expect(library.imports.map(\.originalFileName) == ["IMG_1234.HEIC", "IMG_1234.MOV"])
        #expect(library.imports.map(\.kind) == [.photo, .video])
        #expect(library.imports.allSatisfy { $0.creationDate != nil && $0.pairedVideoFile == nil })
        #expect(report.importedItems["Live/IMG_1234.HEIC"] == ["asset-1", "asset-2"])
        #expect(report.warnings.count == 1)
    }

    @Test func failuresAreCollectedAndProgressReported() async throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try fixture.file("Google Photos/Trip/\(name)") }
        let library = FakeLibrary()
        library.rejected = ["b.jpg"]
        let updates = Locked<[TransferProgress]>([])

        let report = try await TakeoutAlbumImporter(temporaryDirectory: temp).importAlbum(
            try scanAlbum("Trip"), title: "Trip", into: library
        ) { progress in updates.withValue { $0.append(progress) } }

        #expect(report.importedCount == 2)
        #expect(report.failures.map(\.fileName) == ["b.jpg"])
        #expect(report.failures[0].message == "Unsupported file")
        let last = try #require(updates.current.last)
        #expect(last.total == 3)
        #expect(last.added == 2)
        #expect(last.failed == 1)
        #expect(last.currentFileName == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }
}
