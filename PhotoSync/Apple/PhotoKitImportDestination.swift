import CoreLocation
import Photos
import PhotoSyncCore

/// Creates albums and assets in the Apple Photos library.
struct PhotoKitImportDestination: PhotoLibraryDestination {
    struct ImportError: LocalizedError {
        var errorDescription: String?
    }

    /// Carries a placeholder identifier out of a change block.
    private final class IdentifierBox: @unchecked Sendable {
        var value: String?
    }

    func createAlbum(title: String) async throws -> String {
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            box.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = box.value else { throw ImportError(errorDescription: "Photos did not create the album.") }
        return id
    }

    func importAsset(_ request: AssetImportRequest, intoAlbum albumID: String) async throws -> String {
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = request.originalFileName
            creation.addResource(with: request.kind == .video ? .video : .photo, fileURL: request.file, options: options)
            if let video = request.pairedVideoFile {
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = video.lastPathComponent
                creation.addResource(with: .pairedVideo, fileURL: video, options: videoOptions)
            }
            if let date = request.creationDate {
                creation.creationDate = date
            }
            if let location = request.location {
                creation.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    altitude: location.altitude,
                    horizontalAccuracy: 0,
                    verticalAccuracy: location.altitude == 0 ? -1 : 0,
                    timestamp: request.creationDate ?? Date()
                )
            }
            creation.isFavorite = request.isFavorite

            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            box.value = placeholder.localIdentifier
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([placeholder] as NSArray)
            }
        }
        guard let id = box.value else { throw ImportError(errorDescription: "Photos did not create the item.") }
        return id
    }
}
