import Foundation
import PhotoSyncCore

enum AppSync {
    /// Sync history shared by all transfers. Falls back to an in-memory store
    /// (history lasts until quit) if the file can't be opened.
    static let store: SyncStore = {
        if let url = try? SyncStore.defaultURL(), let store = try? SyncStore(url: url) { return store }
        return try! SyncStore(url: nil)
    }()
}

extension SyncPreview {
    /// "Already copied 12 of 40 items on 3 Mar 2026." for the sheets.
    func summary(totalItems: Int) -> String {
        var text = "Already copied \(alreadySyncedCount) of \(totalItems) items"
        if let lastSyncedAt {
            text += " (last sync \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened)))"
        }
        return text + "."
    }
}
