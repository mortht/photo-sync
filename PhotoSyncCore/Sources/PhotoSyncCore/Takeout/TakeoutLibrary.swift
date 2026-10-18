import Foundation

/// The result of scanning a Google Takeout export.
public struct TakeoutLibrary: Sendable {
    public var rootURL: URL
    public var albums: [TakeoutAlbum]

    public init(rootURL: URL, albums: [TakeoutAlbum]) {
        self.rootURL = rootURL
        self.albums = albums
    }
}

/// One album folder (merged across split Takeout archives).
public struct TakeoutAlbum: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A real Google Photos album (user-created or shared).
        case album
        /// `Photos from 2019` and localized variants: all items of a year.
        case year(Int)
        case archive
        case trash
    }

    /// The folder name, which is unique within an export.
    public var id: String
    /// The album title from its metadata file, or the folder name.
    public var title: String
    public var description: String?
    public var kind: Kind
    /// Every folder that contributed to this album (one per Takeout part).
    public var folderURLs: [URL]
    public var assets: [TakeoutAsset]
    /// Sidecars that could not be matched to a media file.
    public var unmatchedSidecars: [URL]

    public var photoCount: Int { assets.count { $0.kind == .photo } }
    public var videoCount: Int { assets.count { $0.kind == .video } }
    public var assetsWithoutMetadata: Int { assets.count { $0.metadata == nil } }
}

/// A single item to import: one media file plus related files.
public struct TakeoutAsset: Sendable, Identifiable, Hashable {
    /// `<album id>/<primary file name>`.
    public var id: String
    public var kind: MediaKind
    /// The original file.
    public var primaryFile: URL
    /// An edited copy (`IMG-edited.jpg`) of the original, if any.
    public var editedFile: URL?
    /// The video half of a Live Photo (`IMG_1234.HEIC` + `IMG_1234.MOV`).
    public var pairedVideoFile: URL?
    public var sidecarFile: URL?
    public var metadata: TakeoutMetadata?

    public var captureDate: Date? { metadata?.captureDate }
}
