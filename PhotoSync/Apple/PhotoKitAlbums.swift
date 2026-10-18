import AppKit
import Photos

/// An album in the user's Apple Photos library.
struct AppleAlbum: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case regular
        /// An iCloud Shared Album.
        case shared
    }

    /// The `PHAssetCollection` local identifier.
    let id: String
    let title: String
    let kind: Kind
    /// Names of the folders containing the album, outermost first.
    let folderPath: [String]
    let photoCount: Int
    let videoCount: Int
    let keyAssetID: String?
}

/// Reads albums from PhotoKit. PhotoKit fetches are thread-safe, so these
/// run off the main actor.
enum PhotoKitAlbums {
    static func fetchAll() -> [AppleAlbum] {
        var albums: [AppleAlbum] = []
        collect(PHCollectionList.fetchTopLevelUserCollections(with: nil), path: [], into: &albums)

        let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        for index in 0..<shared.count {
            albums.append(makeAlbum(shared.object(at: index), kind: .shared, path: []))
        }

        var seen: Set<String> = []
        return albums
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func collect(_ collections: PHFetchResult<PHCollection>, path: [String], into albums: inout [AppleAlbum]) {
        for index in 0..<collections.count {
            switch collections.object(at: index) {
            case let album as PHAssetCollection:
                let kind: AppleAlbum.Kind = album.assetCollectionSubtype == .albumCloudShared ? .shared : .regular
                albums.append(makeAlbum(album, kind: kind, path: path))
            case let folder as PHCollectionList:
                let title = folder.localizedTitle ?? "Untitled Folder"
                collect(PHCollection.fetchCollections(in: folder, options: nil), path: path + [title], into: &albums)
            default:
                break
            }
        }
    }

    private static func makeAlbum(_ collection: PHAssetCollection, kind: AppleAlbum.Kind, path: [String]) -> AppleAlbum {
        AppleAlbum(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? "Untitled Album",
            kind: kind,
            folderPath: path,
            photoCount: count(of: .image, in: collection),
            videoCount: count(of: .video, in: collection),
            keyAssetID: PHAsset.fetchKeyAssets(in: collection, options: nil)?.firstObject?.localIdentifier
        )
    }

    private static func count(of type: PHAssetMediaType, in collection: PHAssetCollection) -> Int {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", type.rawValue)
        return PHAsset.fetchAssets(in: collection, options: options).count
    }
}

/// Wraps an `NSImage` so it can be handed from PhotoKit's callback to the UI.
struct ThumbnailImage: @unchecked Sendable {
    let image: NSImage
}

enum ThumbnailLoader {
    static func thumbnail(forAssetID id: String, pointSize: CGFloat) async -> ThumbnailImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        // Shared album items usually live only in iCloud.
        options.isNetworkAccessAllowed = true
        let pixels = pointSize * 2
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixels, height: pixels),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image.map(ThumbnailImage.init))
            }
        }
    }
}

/// Notifies about library changes, e.g. when shared albums finish syncing.
final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
