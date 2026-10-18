import Foundation

/// What to import when Takeout has both an original and an edited copy.
public enum EditedVersionPolicy: String, Sendable, CaseIterable {
    /// The edited copy, which is what Google Photos shows.
    case preferEdited
    case originalOnly
    /// Both, as separate items.
    case both
}

public struct TakeoutImportOptions: Sendable, Equatable {
    public var editedVersions: EditedVersionPolicy
    /// Writes sidecar descriptions into the image file (XMP/IPTC), which Photos
    /// shows as the caption. PhotoKit has no API to set captions directly.
    public var restoreDescriptions: Bool

    public init(editedVersions: EditedVersionPolicy = .preferEdited, restoreDescriptions: Bool = true) {
        self.editedVersions = editedVersions
        self.restoreDescriptions = restoreDescriptions
    }
}

/// One asset to create in the photo library.
public struct AssetImportRequest: Sendable, Equatable {
    public var kind: MediaKind
    public var file: URL
    /// The video half of a Live Photo.
    public var pairedVideoFile: URL?
    public var originalFileName: String
    public var creationDate: Date?
    public var location: GeoLocation?
    public var isFavorite: Bool
}

/// A photo library that can receive imported assets (PhotoKit in the app).
public protocol PhotoLibraryDestination: Sendable {
    /// Creates an album and returns its identifier.
    func createAlbum(title: String) async throws -> String
    /// Whether an album created earlier still exists.
    func albumExists(id: String) async -> Bool
    /// Creates the asset in the album and returns the new asset's identifier.
    func importAsset(_ request: AssetImportRequest, intoAlbum albumID: String) async throws -> String
}

public struct ImportReport: Sendable, Equatable {
    public var albumID: String
    public var albumTitle: String
    /// Takeout asset ID → identifiers of the assets created for it.
    public var importedItems: [String: [String]]
    public var failures: [TransferFailure]
    /// Items that were imported with something missing.
    public var warnings: [TransferFailure]
    /// Library items skipped because an earlier run already imported them.
    public var skippedCount: Int
    public var wasCancelled: Bool

    public var importedCount: Int { importedItems.values.reduce(0) { $0 + $1.count } }
}

/// Imports a scanned Takeout album into a new photo library album, restoring
/// capture date, location, favorite state and (optionally) descriptions from
/// the sidecars.
public struct TakeoutAlbumImporter: Sendable {
    private let temporaryDirectory: URL

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    /// The number of library items an album produces with these options.
    public static func itemCount(of album: TakeoutAlbum, options: TakeoutImportOptions) -> Int {
        album.assets.reduce(0) { $0 + plannedFiles(for: $1, policy: options.editedVersions).count }
    }

    public func importAlbum(
        _ album: TakeoutAlbum,
        title: String,
        into destination: some PhotoLibraryDestination,
        options: TakeoutImportOptions = TakeoutImportOptions(),
        ledger: (any SyncLedger)? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        let albumID = try await destination.createAlbum(title: title)
        return try await importAlbum(album, intoAlbumID: albumID, albumTitle: title, into: destination,
                                     options: options, ledger: ledger, progress: progress)
    }

    /// Imports into an existing album. With a `ledger`, assets it already
    /// knows (by Takeout ID or by file content) are skipped, and each new
    /// asset is recorded right after it is imported.
    public func importAlbum(
        _ album: TakeoutAlbum,
        intoAlbumID albumID: String,
        albumTitle: String,
        into destination: some PhotoLibraryDestination,
        options: TakeoutImportOptions = TakeoutImportOptions(),
        ledger: (any SyncLedger)? = nil,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        var report = ImportReport(albumID: albumID, albumTitle: albumTitle, importedItems: [:], failures: [],
                                  warnings: [], skippedCount: 0, wasCancelled: false)
        var state = TransferProgress(total: Self.itemCount(of: album, options: options))
        progress(state)

        for asset in album.assets {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }
            let plannedFiles = Self.plannedFiles(for: asset, policy: options.editedVersions)

            var contentHash: String?
            if let ledger {
                var known = try await ledger.contains(itemID: asset.id)
                if !known {
                    // A re-export may name the same file differently, e.g. `IMG(1).jpg`.
                    contentHash = try? ContentHash.sha256(of: asset.primaryFile)
                    if let contentHash, try await ledger.contains(contentHash: contentHash) {
                        try await ledger.record(itemID: asset.id, contentHash: contentHash, destinationIDs: [])
                        known = true
                    }
                }
                if known {
                    state.skipped += plannedFiles.count
                    report.skippedCount += plannedFiles.count
                    progress(state)
                    continue
                }
            }

            var importedIDs: [String] = []
            for planned in plannedFiles {
                if Task.isCancelled {
                    report.wasCancelled = true
                    break
                }
                let fileName = planned.file.lastPathComponent
                state.currentFileName = fileName
                progress(state)

                let workDirectory = temporaryDirectory.appending(path: "PhotoSync-\(UUID().uuidString)",
                                                                 directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: workDirectory) }
                do {
                    importedIDs += try await importFile(planned, of: asset, options: options,
                                                        workDirectory: workDirectory, into: destination,
                                                        albumID: albumID, report: &report)
                    state.added += 1
                } catch is CancellationError {
                    report.wasCancelled = true
                    break
                } catch {
                    report.failures.append(TransferFailure(itemID: asset.id, fileName: fileName,
                                                           message: Self.message(for: error)))
                    state.failed += 1
                }
                progress(state)
            }

            if !importedIDs.isEmpty {
                report.importedItems[asset.id] = importedIDs
                try await ledger?.record(itemID: asset.id, contentHash: contentHash, destinationIDs: importedIDs)
            }
            if report.wasCancelled { break }
        }

        state.currentFileName = nil
        progress(state)
        return report
    }

    // MARK: - Planning

    struct PlannedFile: Equatable {
        var file: URL
        var pairedVideoFile: URL?
    }

    static func plannedFiles(for asset: TakeoutAsset, policy: EditedVersionPolicy) -> [PlannedFile] {
        let original = PlannedFile(file: asset.primaryFile, pairedVideoFile: asset.pairedVideoFile)
        guard let edited = asset.editedFile else { return [original] }
        // An edited still no longer matches the original's Live Photo video.
        let editedFile = PlannedFile(file: edited, pairedVideoFile: nil)
        switch policy {
        case .preferEdited: return [editedFile]
        case .originalOnly: return [original]
        case .both: return [original, editedFile]
        }
    }

    // MARK: - Importing

    private func importFile(
        _ planned: PlannedFile,
        of asset: TakeoutAsset,
        options: TakeoutImportOptions,
        workDirectory: URL,
        into destination: some PhotoLibraryDestination,
        albumID: String,
        report: inout ImportReport
    ) async throws -> [String] {
        var file = planned.file
        let fileName = planned.file.lastPathComponent
        if options.restoreDescriptions, asset.kind == .photo, let description = asset.metadata?.description {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let copy = workDirectory.appending(path: fileName)
            do {
                try ImageMetadataWriter.copy(planned.file, to: copy, settingDescription: description)
                file = copy
            } catch {
                report.warnings.append(TransferFailure(itemID: asset.id, fileName: fileName,
                                                       message: "The description could not be restored."))
            }
        }

        let request = AssetImportRequest(
            kind: asset.kind,
            file: file,
            pairedVideoFile: planned.pairedVideoFile,
            originalFileName: fileName,
            creationDate: asset.metadata?.photoTakenTime,
            location: asset.metadata?.location,
            isFavorite: asset.metadata?.isFavorite ?? false
        )
        do {
            return [try await destination.importAsset(request, intoAlbum: albumID)]
        } catch let error where !(error is CancellationError) {
            guard let video = planned.pairedVideoFile else { throw error }
            // Live Photo pairing fails when the two files' content identifiers
            // don't match (e.g. after Google re-encoded the video). Keep both halves.
            var still = request
            still.pairedVideoFile = nil
            var motion = request
            motion.kind = .video
            motion.file = video
            motion.pairedVideoFile = nil
            motion.originalFileName = video.lastPathComponent
            let stillID = try await destination.importAsset(still, intoAlbum: albumID)
            let videoID = try await destination.importAsset(motion, intoAlbum: albumID)
            report.warnings.append(TransferFailure(
                itemID: asset.id, fileName: fileName,
                message: "Imported as a separate photo and video; the Live Photo could not be recreated."
            ))
            return [stillID, videoID]
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
