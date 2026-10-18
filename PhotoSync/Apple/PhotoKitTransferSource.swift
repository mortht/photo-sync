import Photos
import PhotoSyncCore
import UniformTypeIdentifiers

extension PhotoKitAlbums {
    /// The album's photos and videos, in album order.
    static func transferItems(inAlbum albumID: String) -> [TransferItem] {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            .firstObject else { return [] }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        return (0..<assets.count).compactMap { index in
            let asset = assets.object(at: index)
            let kind: MediaKind
            switch asset.mediaType {
            case .image: kind = .photo
            case .video: kind = .video
            default: return nil
            }
            let fileName = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Untitled"
            return TransferItem(id: asset.localIdentifier, fileName: fileName, kind: kind)
        }
    }
}

/// Exports PhotoKit assets for upload. Uses the current (edited) version
/// when there is one, which is what the user sees in Photos; for Live
/// Photos only the still image is uploaded.
struct PhotoKitTransferSource: TransferSource {
    struct ExportError: LocalizedError {
        var errorDescription: String?
    }

    func export(_ item: TransferItem, into directory: URL) async throws -> ExportedFile {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            throw ExportError(errorDescription: "The item is no longer in your library.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.preferredResource(in: resources, for: asset.mediaType) else {
            throw ExportError(errorDescription: "The item has no exportable file.")
        }
        let original = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename
        let fileName = Self.fileName(original: original ?? resource.originalFilename, for: resource)
        let destination = directory.appending(path: fileName)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)

        let type = UTType(resource.uniformTypeIdentifier)
        return ExportedFile(url: destination, fileName: fileName,
                            mimeType: type?.preferredMIMEType ?? "application/octet-stream")
    }

    static func preferredResource(in resources: [PHAssetResource], for mediaType: PHAssetMediaType) -> PHAssetResource? {
        let order: [PHAssetResourceType] = mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        for type in order {
            if let resource = resources.first(where: { $0.type == type }) { return resource }
        }
        return nil
    }

    /// Keeps the original name, swapping the extension if the edited
    /// version has a different format (e.g. an edited HEIC rendered as JPEG).
    static func fileName(original: String, for resource: PHAssetResource) -> String {
        guard let type = UTType(resource.uniformTypeIdentifier) else { return original }
        let ext = (original as NSString).pathExtension
        if let originalType = UTType(filenameExtension: ext), originalType.conforms(to: type) { return original }
        guard let newExt = type.preferredFilenameExtension else { return original }
        return (original as NSString).deletingPathExtension + "." + newExt
    }
}
