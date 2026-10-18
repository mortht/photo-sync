import PhotoSyncCore
import SwiftUI

struct PickerImportSheet: View {
    @Bindable var model: PickerImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick from Google Photos")
                .font(.title3.bold())
            switch model.phase {
            case .starting: ProgressView("Opening Google Photos…")
            case .waiting: waiting
            case .loading: ProgressView("Loading your selection…")
            case .picked: picked
            case .running:
                TransferProgressSection(progress: model.progress, onStop: model.cancel)
            case .finished(let report): finished(report)
            case .failed(let message): TransferErrorView(message: message) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear { model.begin() }
        .onDisappear { model.close() }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Pick photos and videos in the browser window, then confirm your selection there.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("You can pick up to \(GooglePhotosPickerClient.maxItemsPerSession) items. The window closes by itself when you're done.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Picker Again") { model.openPicker() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var picked: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Picked", value: AlbumRow<EmptyView>.countSummary(
                    photos: model.photoCount, videos: model.videoCount))
                TextField("Apple Photos album name", text: $model.albumTitle)
                if let previewError = model.previewError {
                    SyncHistoryErrorRow(message: previewError)
                }
                if model.preview.existingAlbumTitle != nil {
                    LabeledContent("Synced before") {
                        Text(model.preview.summary(totalItems: model.items.count))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .task(id: model.albumTitle) {
                // Debounce typing before looking up the album's history.
                try? await Task.sleep(for: .milliseconds(300))
                await model.updatePreview()
            }
            Text("Imports into this Apple Photos album, adding to it if you picked into the same name before. Capture dates are kept, but Google removes location data from picked items; use Takeout to keep locations and descriptions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.preview.existingAlbumTitle == nil ? "Import" : "Add \(model.newItemCount) New Items") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.albumTitle.trimmingCharacters(in: .whitespaces).isEmpty || model.newItemCount == 0)
            }
        }
    }

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransferResultLabel(
                text: "Imported \(model.progress.added) items into “\(report.albumTitle)”."
                    + (report.skippedCount > 0 ? " \(report.skippedCount) were already there." : ""),
                isComplete: report.failures.isEmpty && !report.wasCancelled
            )
            if report.wasCancelled {
                Text("The import was stopped. Pick the same items again to import the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TransferIssueList(title: "Failed", issues: report.failures)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
