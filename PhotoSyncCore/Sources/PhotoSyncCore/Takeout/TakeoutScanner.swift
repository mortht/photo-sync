import Foundation

/// Scans an extracted Google Takeout export.
///
/// The root may be any folder containing the export: the `Takeout` or
/// `Google Photos` folder, a single album folder, or a parent folder holding
/// several extracted archive parts (`takeout-…-001`, `takeout-…-002`, …).
/// Folders with the same name are merged, because a split export can place
/// an album's media and sidecars in different parts.
public struct TakeoutScanner: Sendable {
    public init() {}

    public func scan(root: URL) throws -> TakeoutLibrary {
        let folders = try collectFolders(under: root)

        var albums: [TakeoutAlbum] = []
        for (name, contents) in folders {
            guard !contents.media.isEmpty else { continue }
            albums.append(makeAlbum(id: name, contents: contents))
        }
        albums.sort(by: Self.albumOrder)
        return TakeoutLibrary(rootURL: root, albums: albums)
    }

    // MARK: - Folder collection

    private struct FolderContents {
        var urls: [URL] = []
        var media: [String: URL] = [:]
        var json: [String: URL] = [:]
    }

    private func collectFolders(under root: URL) throws -> [String: FolderContents] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: root])
        }

        var folders: [String: FolderContents] = [:]
        var seenFolders: [String: Set<URL>] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let folderURL = url.deletingLastPathComponent()
            let folderName = folderURL.lastPathComponent
            let fileName = url.lastPathComponent

            var contents = folders[folderName, default: FolderContents()]
            if seenFolders[folderName, default: []].insert(folderURL.standardizedFileURL).inserted {
                contents.urls.append(folderURL)
            }
            if MediaFileType.kind(ofFileNamed: fileName) != nil {
                // Names are unique within an album; a repeat across parts is the same file.
                if contents.media[fileName] == nil { contents.media[fileName] = url }
            } else if MediaFileType.isJSON(fileName) {
                if contents.json[fileName] == nil { contents.json[fileName] = url }
            }
            folders[folderName] = contents
        }
        return folders
    }

    // MARK: - Album assembly

    private func makeAlbum(id: String, contents: FolderContents) -> TakeoutAlbum {
        var sidecars: [SidecarMatcher.Sidecar] = []
        var metadataBySidecar: [String: TakeoutMetadata] = [:]
        var albumMetadata: TakeoutAlbumMetadata?
        for (name, url) in contents.json.sorted(by: { $0.key < $1.key }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            switch TakeoutJSONDocument.parse(data) {
            case .sidecar(let metadata):
                sidecars.append(.init(name: name, title: metadata.title))
                metadataBySidecar[name] = metadata
            case .album(let metadata):
                if albumMetadata == nil { albumMetadata = metadata }
            case .other:
                break
            }
        }

        let mediaNames = contents.media.keys.sorted()
        let match = SidecarMatcher.match(mediaNames: mediaNames, sidecars: sidecars)
        let assets = groupAssets(albumID: id, mediaNames: mediaNames, contents: contents, match: match,
                                 metadataBySidecar: metadataBySidecar)

        return TakeoutAlbum(
            id: id,
            title: albumMetadata?.title ?? id,
            description: albumMetadata?.description,
            kind: Self.kind(ofFolderNamed: id),
            folderURLs: contents.urls.sorted { $0.path < $1.path },
            assets: assets,
            unmatchedSidecars: match.unmatchedSidecars.compactMap { contents.json[$0] }
        )
    }

    private func groupAssets(
        albumID: String,
        mediaNames: [String],
        contents: FolderContents,
        match: SidecarMatcher.Result,
        metadataBySidecar: [String: TakeoutMetadata]
    ) -> [TakeoutAsset] {
        let nameByLowercased = Dictionary(mediaNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Edited copies attach to their original when it is present.
        var editedByOriginal: [String: String] = [:]
        var attached: Set<String> = []
        for name in mediaNames {
            guard let original = SidecarMatcher.originalName(forEdited: name),
                  let originalName = nameByLowercased[original.lowercased()],
                  editedByOriginal[originalName] == nil else { continue }
            editedByOriginal[originalName] = name
            attached.insert(name)
        }

        // Live Photos: a still and a video with the same stem, where the video has no sidecar of its own.
        var stillByStem: [String: String] = [:]
        for name in mediaNames where !attached.contains(name) {
            let (stem, ext) = SidecarMatcher.splitExtension(name)
            if MediaFileType.livePhotoStillExtensions.contains(String(ext.dropFirst()).lowercased()) {
                stillByStem[stem.lowercased()] = name
            }
        }
        var videoByStill: [String: String] = [:]
        for name in mediaNames where !attached.contains(name) && match.sidecarByMedia[name] == nil {
            guard MediaFileType.kind(ofFileNamed: name) == .video else { continue }
            let stem = SidecarMatcher.splitExtension(name).stem.lowercased()
            guard let still = stillByStem[stem], videoByStill[still] == nil else { continue }
            videoByStill[still] = name
            attached.insert(name)
        }

        var assets: [TakeoutAsset] = []
        for name in mediaNames where !attached.contains(name) {
            let edited = editedByOriginal[name]
            let sidecarName = match.sidecarByMedia[name] ?? edited.flatMap { match.sidecarByMedia[$0] }
            assets.append(TakeoutAsset(
                id: "\(albumID)/\(name)",
                kind: MediaFileType.kind(ofFileNamed: name) ?? .photo,
                primaryFile: contents.media[name]!,
                editedFile: edited.flatMap { contents.media[$0] },
                pairedVideoFile: videoByStill[name].flatMap { contents.media[$0] },
                sidecarFile: sidecarName.flatMap { contents.json[$0] },
                metadata: sidecarName.flatMap { metadataBySidecar[$0] }
            ))
        }
        assets.sort { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (l?, r?) where l != r: l < r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.primaryFile.lastPathComponent < rhs.primaryFile.lastPathComponent
            }
        }
        return assets
    }

    // MARK: - Folder kinds

    static let yearFolderPrefixes = [
        "Photos from ", "Fotos von ", "Fotos de ", "Photos de ", "Foto dal ", "Foto's uit ", "Foton från ",
    ]
    static let archiveFolderNames: Set<String> = ["archive", "archiv", "archives", "archivo", "archivio", "archief", "arkiv"]
    static let trashFolderNames: Set<String> = ["trash", "papierkorb", "corbeille", "papelera", "cestino", "prullenbak", "papperskorg"]

    static func kind(ofFolderNamed name: String) -> TakeoutAlbum.Kind {
        for prefix in yearFolderPrefixes where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.count == 4, rest.allSatisfy(\.isASCII), let year = Int(rest) { return .year(year) }
        }
        let lower = name.lowercased()
        if archiveFolderNames.contains(lower) { return .archive }
        if trashFolderNames.contains(lower) { return .trash }
        return .album
    }

    /// Albums by title, then years (newest first), then archive and trash.
    static func albumOrder(_ lhs: TakeoutAlbum, _ rhs: TakeoutAlbum) -> Bool {
        func rank(_ kind: TakeoutAlbum.Kind) -> (Int, Int) {
            switch kind {
            case .album: (0, 0)
            case .year(let year): (1, -year)
            case .archive: (2, 0)
            case .trash: (3, 0)
            }
        }
        let (l, r) = (rank(lhs.kind), rank(rhs.kind))
        if l != r { return l < r }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
