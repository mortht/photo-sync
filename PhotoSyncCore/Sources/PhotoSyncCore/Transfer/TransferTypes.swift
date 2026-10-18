import Foundation

/// One item of a source album, e.g. a PhotoKit asset.
public struct TransferItem: Sendable, Identifiable, Equatable {
    /// The source's stable identifier (PhotoKit local identifier, Takeout asset ID, …).
    public var id: String
    public var fileName: String
    public var kind: MediaKind

    public init(id: String, fileName: String, kind: MediaKind) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
    }
}

/// A file exported from the source, ready to upload.
public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var mimeType: String
    public var description: String?

    public init(url: URL, fileName: String, mimeType: String, description: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.mimeType = mimeType
        self.description = description
    }
}

/// Exports items of a source library to local files.
public protocol TransferSource: Sendable {
    /// Writes the item's file into `directory` (which the caller deletes afterwards).
    func export(_ item: TransferItem, into directory: URL) async throws -> ExportedFile
}

public struct TransferProgress: Sendable, Equatable {
    public var total: Int
    /// Items handled so far (uploaded, failed or skipped). Drives the progress
    /// bar, because uploads are only added to the album in batches.
    public var processed = 0
    /// Items whose bytes were uploaded.
    public var uploaded = 0
    /// Items added to the album.
    public var added = 0
    public var failed = 0
    /// Items skipped because an earlier run already copied them.
    public var skipped = 0
    public var currentFileName: String?

    public init(total: Int) {
        self.total = total
    }

    /// Final tally of items that reached an outcome.
    public var completed: Int { added + failed + skipped }
    public var fractionCompleted: Double { total == 0 ? 1 : min(Double(processed) / Double(total), 1) }
}

public struct TransferFailure: Sendable, Hashable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var fileName: String
    public var message: String
}
