import PhotoSyncCore
import SwiftUI

/// Form rows choosing between the album from an earlier sync and a new one.
struct SyncTargetSection: View {
    let preview: SyncPreview
    /// Shown when the history couldn't be checked.
    var previewError: String?
    let totalItems: Int
    let titleLabel: String
    @Binding var title: String
    @Binding var forceNewAlbum: Bool

    var body: some View {
        if let previewError {
            SyncHistoryErrorRow(message: previewError)
        }
        if let existing = preview.existingAlbumTitle {
            LabeledContent("Synced before") {
                Text(preview.summary(totalItems: totalItems))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Copy into a new album instead of “\(existing)”", isOn: $forceNewAlbum)
        }
        if preview.existingAlbumTitle == nil || forceNewAlbum {
            TextField(titleLabel, text: $title)
        }
    }
}

/// Explains that the sheet couldn't tell whether the album was copied before.
struct SyncHistoryErrorRow: View {
    let message: String

    var body: some View {
        Label("Couldn't check the sync history: \(message) Items copied before are still skipped if their album exists.",
              systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
