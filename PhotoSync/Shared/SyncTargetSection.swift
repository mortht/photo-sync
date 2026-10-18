import PhotoSyncCore
import SwiftUI

/// Form rows choosing between the album from an earlier sync and a new one.
struct SyncTargetSection: View {
    let preview: SyncPreview
    let totalItems: Int
    let titleLabel: String
    @Binding var title: String
    @Binding var forceNewAlbum: Bool

    var body: some View {
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
