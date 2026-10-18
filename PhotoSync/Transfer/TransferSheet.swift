import PhotoSyncCore
import SwiftUI

struct TransferSheet: View {
    @Bindable var model: TransferModel
    let google: GoogleAccountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy “\(model.album.title)” to Google Photos")
                .font(.title3.bold())
            switch model.phase {
            case .loading: ProgressView("Checking sync history…")
            case .ready: setup
            case .running:
                TransferProgressSection(progress: model.progress, onStop: model.cancel)
            case .finished(let report): finished(report)
            case .failed(let message): TransferErrorView(message: message) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isActive)
        .task { await model.load(client: google.libraryClient()) }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Items", value: AlbumRow<EmptyView>.countSummary(
                    photos: model.album.photoCount, videos: model.album.videoCount))
                SyncTargetSection(preview: model.preview, previewError: model.previewError, totalItems: model.items.count,
                                  titleLabel: "Google album name", title: $model.targetTitle,
                                  forceNewAlbum: $model.forceNewAlbum)
            }
            Text("Edited items are uploaded as you see them in Photos; Live Photos are uploaded as stills. Items copied before are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.addsToExistingAlbum ? "Add \(model.newItemCount) New Items" : "Copy") {
                    guard let client = google.libraryClient() else { return }
                    model.start(client: client, onError: google.noteFailure)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard google.isSignedIn, !model.items.isEmpty else { return false }
        if model.addsToExistingAlbum { return model.newItemCount > 0 }
        return !model.targetTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func finished(_ report: TransferReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransferResultLabel(
                text: "Added \(report.addedItems.count) items to “\(report.album.title)”."
                    + (report.skippedCount > 0 ? " \(report.skippedCount) were already there." : ""),
                isComplete: report.failures.isEmpty && !report.wasCancelled
            )
            if report.wasCancelled {
                Text("The transfer was stopped. Run it again to copy the remaining items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TransferIssueList(title: "Failed (retried next time)", issues: report.failures)
            HStack {
                if let url = report.album.productUrl {
                    Link("Open in Google Photos", destination: url)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
