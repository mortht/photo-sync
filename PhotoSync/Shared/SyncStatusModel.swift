import Foundation
import Observation
import PhotoSyncCore

/// Sync history per album, for the badges in the album lists.
@MainActor
@Observable
final class SyncStatusModel {
    private var summaries: [SyncDirection: [String: SyncSummary]] = [:]

    func refresh() async {
        let all = (try? await AppSync.store.summaries()) ?? []
        summaries = Dictionary(grouping: all, by: \.pair.direction)
            .mapValues { Dictionary($0.map { ($0.pair.sourceAlbumID, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    func badge(_ direction: SyncDirection, sourceAlbumID: String, totalItems: Int) -> SyncBadgeInfo? {
        guard let summary = summaries[direction]?[sourceAlbumID] else { return nil }
        return SyncBadgeInfo(
            destination: direction == .appleToGoogle ? "Google Photos" : "Apple Photos",
            albumTitle: summary.pair.destinationAlbumTitle,
            syncedCount: min(summary.syncedItemCount, totalItems),
            totalCount: totalItems,
            lastSyncedAt: summary.pair.lastSyncedAt
        )
    }
}
