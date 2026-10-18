import Foundation
import SQLite3

/// Which way an album pair syncs.
public enum SyncDirection: String, Sendable, Codable {
    case appleToGoogle
    case takeoutToApple
}

/// A source album linked to the destination album it was copied into.
public struct SyncPair: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var direction: SyncDirection
    public var sourceAlbumID: String
    public var sourceAlbumTitle: String
    public var destinationAlbumID: String
    public var destinationAlbumTitle: String
    public var lastSyncedAt: Date?
}

/// A pair and how many of its items are synced, for album lists.
public struct SyncSummary: Sendable, Equatable {
    public var pair: SyncPair
    public var syncedItemCount: Int
}

public struct SyncStoreError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { "Sync history error: \(message)" }
}

/// Persists which items of which album were copied where, so re-running a
/// transfer only copies new items. Backed by SQLite; each record is written
/// immediately so an interrupted transfer resumes where it stopped.
public actor SyncStore {
    /// Owns the SQLite handle; only used from the actor.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer?
        init(_ handle: OpaquePointer?) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.handle }

    /// Opens (or creates) the store at `url`; `nil` keeps it in memory.
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SyncStoreError(message: message)
        }
        connection = Connection(handle)
        try Self.migrate(handle)
    }

    /// The default store in Application Support (the app container when sandboxed).
    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PhotoSync/sync.sqlite")
    }

    // MARK: - Pairs

    public func pair(direction: SyncDirection, sourceAlbumID: String) throws -> SyncPair? {
        try query("""
            SELECT id, direction, source_album_id, source_title, destination_album_id, destination_title, last_synced_at
            FROM album_pairs WHERE direction = ? AND source_album_id = ?
            """, [.text(direction.rawValue), .text(sourceAlbumID)]) { row in
            SyncPair(
                id: row.int(0), direction: SyncDirection(rawValue: row.text(1)) ?? direction,
                sourceAlbumID: row.text(2), sourceAlbumTitle: row.text(3),
                destinationAlbumID: row.text(4), destinationAlbumTitle: row.text(5),
                lastSyncedAt: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:))
            )
        }.first
    }

    public func allPairs() throws -> [SyncPair] {
        try query("""
            SELECT id, direction, source_album_id, source_title, destination_album_id, destination_title, last_synced_at
            FROM album_pairs ORDER BY source_title
            """) { row in
            SyncPair(
                id: row.int(0), direction: SyncDirection(rawValue: row.text(1)) ?? .appleToGoogle,
                sourceAlbumID: row.text(2), sourceAlbumTitle: row.text(3),
                destinationAlbumID: row.text(4), destinationAlbumTitle: row.text(5),
                lastSyncedAt: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    public func summaries() throws -> [SyncSummary] {
        try query("""
            SELECT p.id, p.direction, p.source_album_id, p.source_title, p.destination_album_id,
                   p.destination_title, p.last_synced_at, COUNT(i.source_item_id)
            FROM album_pairs p LEFT JOIN synced_items i ON i.pair_id = p.id
            GROUP BY p.id
            """) { row in
            SyncSummary(
                pair: SyncPair(
                    id: row.int(0), direction: SyncDirection(rawValue: row.text(1)) ?? .appleToGoogle,
                    sourceAlbumID: row.text(2), sourceAlbumTitle: row.text(3),
                    destinationAlbumID: row.text(4), destinationAlbumTitle: row.text(5),
                    lastSyncedAt: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:))
                ),
                syncedItemCount: Int(row.int(7))
            )
        }
    }

    /// Links the source album to a (new) destination album. Linking to a
    /// different destination forgets the items synced to the old one.
    @discardableResult
    public func linkPair(direction: SyncDirection, sourceAlbumID: String, sourceAlbumTitle: String,
                         destinationAlbumID: String, destinationAlbumTitle: String) throws -> SyncPair {
        if var existing = try pair(direction: direction, sourceAlbumID: sourceAlbumID) {
            if existing.destinationAlbumID != destinationAlbumID {
                try execute("DELETE FROM synced_items WHERE pair_id = ?", [.int(existing.id)])
            }
            try execute("""
                UPDATE album_pairs SET source_title = ?, destination_album_id = ?, destination_title = ? WHERE id = ?
                """, [.text(sourceAlbumTitle), .text(destinationAlbumID), .text(destinationAlbumTitle), .int(existing.id)])
            existing.sourceAlbumTitle = sourceAlbumTitle
            existing.destinationAlbumID = destinationAlbumID
            existing.destinationAlbumTitle = destinationAlbumTitle
            return existing
        }
        try execute("""
            INSERT INTO album_pairs (direction, source_album_id, source_title, destination_album_id, destination_title)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(direction.rawValue), .text(sourceAlbumID), .text(sourceAlbumTitle),
                  .text(destinationAlbumID), .text(destinationAlbumTitle)])
        return SyncPair(id: sqlite3_last_insert_rowid(db), direction: direction, sourceAlbumID: sourceAlbumID,
                        sourceAlbumTitle: sourceAlbumTitle, destinationAlbumID: destinationAlbumID,
                        destinationAlbumTitle: destinationAlbumTitle, lastSyncedAt: nil)
    }

    public func markSynced(pairID: Int64, at date: Date = Date()) throws {
        try execute("UPDATE album_pairs SET last_synced_at = ? WHERE id = ?",
                    [.double(date.timeIntervalSince1970), .int(pairID)])
    }

    public func removePair(id: Int64) throws {
        try execute("DELETE FROM synced_items WHERE pair_id = ?", [.int(id)])
        try execute("DELETE FROM album_pairs WHERE id = ?", [.int(id)])
    }

    // MARK: - Items

    public func syncedItemIDs(pairID: Int64) throws -> Set<String> {
        Set(try query("SELECT source_item_id FROM synced_items WHERE pair_id = ?", [.int(pairID)]) { $0.text(0) })
    }

    public func containsItem(pairID: Int64, sourceItemID: String) throws -> Bool {
        try !query("SELECT 1 FROM synced_items WHERE pair_id = ? AND source_item_id = ?",
                   [.int(pairID), .text(sourceItemID)]) { _ in true }.isEmpty
    }

    public func containsContent(pairID: Int64, contentHash: String) throws -> Bool {
        try !query("SELECT 1 FROM synced_items WHERE pair_id = ? AND content_hash = ? LIMIT 1",
                   [.int(pairID), .text(contentHash)]) { _ in true }.isEmpty
    }

    public func destinationIDs(pairID: Int64, sourceItemID: String) throws -> [String] {
        try query("SELECT destination_ids FROM synced_items WHERE pair_id = ? AND source_item_id = ?",
                  [.int(pairID), .text(sourceItemID)]) { row in
            row.text(0).split(separator: "\n").map(String.init)
        }.first ?? []
    }

    public func recordItem(pairID: Int64, sourceItemID: String, contentHash: String?, destinationIDs: [String],
                           at date: Date = Date()) throws {
        try execute("""
            INSERT INTO synced_items (pair_id, source_item_id, content_hash, destination_ids, synced_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (pair_id, source_item_id) DO UPDATE SET
              content_hash = excluded.content_hash, destination_ids = excluded.destination_ids,
              synced_at = excluded.synced_at
            """, [.int(pairID), .text(sourceItemID), contentHash.map { .text($0) } ?? .null,
                  .text(destinationIDs.joined(separator: "\n")), .double(date.timeIntervalSince1970)])
    }

    // MARK: - Schema

    private static func migrate(_ db: OpaquePointer?) throws {
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS album_pairs (
              id INTEGER PRIMARY KEY,
              direction TEXT NOT NULL,
              source_album_id TEXT NOT NULL,
              source_title TEXT NOT NULL,
              destination_album_id TEXT NOT NULL,
              destination_title TEXT NOT NULL,
              last_synced_at REAL,
              UNIQUE (direction, source_album_id)
            );
            CREATE TABLE IF NOT EXISTS synced_items (
              pair_id INTEGER NOT NULL,
              source_item_id TEXT NOT NULL,
              content_hash TEXT,
              destination_ids TEXT NOT NULL,
              synced_at REAL NOT NULL,
              PRIMARY KEY (pair_id, source_item_id)
            );
            CREATE INDEX IF NOT EXISTS synced_items_hash ON synced_items (pair_id, content_hash);
            PRAGMA user_version = 1;
            """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "migration failed"
            sqlite3_free(error)
            throw SyncStoreError(message: message)
        }
    }

    // MARK: - SQLite helpers

    private enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    private struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
    }

    /// Tells SQLite to copy bound strings.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SyncStoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let int): sqlite3_bind_int64(statement, position, int)
            case .double(let double): sqlite3_bind_double(statement, position, double)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SyncStoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw SyncStoreError(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

/// Records progress for one album pair while a transfer runs.
public protocol SyncLedger: Sendable {
    func contains(itemID: String) async throws -> Bool
    func contains(contentHash: String) async throws -> Bool
    func record(itemID: String, contentHash: String?, destinationIDs: [String]) async throws
}

/// A `SyncLedger` for one pair in a `SyncStore`.
public struct AlbumSyncLedger: SyncLedger {
    public let store: SyncStore
    public let pairID: Int64

    public init(store: SyncStore, pairID: Int64) {
        self.store = store
        self.pairID = pairID
    }

    public func contains(itemID: String) async throws -> Bool {
        try await store.containsItem(pairID: pairID, sourceItemID: itemID)
    }

    public func contains(contentHash: String) async throws -> Bool {
        try await store.containsContent(pairID: pairID, contentHash: contentHash)
    }

    public func record(itemID: String, contentHash: String?, destinationIDs: [String]) async throws {
        try await store.recordItem(pairID: pairID, sourceItemID: itemID, contentHash: contentHash,
                                   destinationIDs: destinationIDs)
    }
}
