import PhotoSyncCore
import SwiftUI

struct ImportSheet: View {
    @Bindable var model: ImportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy “\(model.album.title)” to Apple Photos")
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
        .task { await model.load() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Items to import", value: "\(model.itemCount)")
                if model.album.assetsWithoutMetadata > 0 {
                    LabeledContent("Without metadata") {
                        Text("\(model.album.assetsWithoutMetadata)")
                            .foregroundStyle(.orange)
                            .help("These items keep the date stored in the file; their location can't be restored.")
                    }
                }
                SyncTargetSection(preview: model.preview, previewError: model.previewError, totalItems: model.album.assets.count,
                                  titleLabel: "Apple Photos album name", title: $model.targetTitle,
                                  forceNewAlbum: $model.forceNewAlbum)
                if model.hasEditedCopies {
                    Picker("Edited photos", selection: $model.options.editedVersions) {
                        Text("Edited version").tag(EditedVersionPolicy.preferEdited)
                        Text("Original only").tag(EditedVersionPolicy.originalOnly)
                        Text("Both").tag(EditedVersionPolicy.both)
                    }
                }
                if model.hasDescriptions {
                    Toggle("Restore descriptions as captions", isOn: $model.options.restoreDescriptions)
                        .help("Writes the Google Photos description into a copy of each JPEG/PNG before import.")
                }
            }
            Text("Restores dates, locations and favorites from the Takeout metadata. Items imported before are skipped, even from a newer export.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.addsToExistingAlbum ? "Add New Items" : "Import") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard model.itemCount > 0 else { return false }
        if model.addsToExistingAlbum { return model.preview.alreadySyncedCount < model.album.assets.count }
        return !model.targetTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransferResultLabel(
                text: "Imported \(model.progress.added) items into “\(report.albumTitle)”."
                    + (report.skippedCount > 0 ? " \(report.skippedCount) were already there." : ""),
                isComplete: report.failures.isEmpty && !report.wasCancelled
            )
            if report.wasCancelled {
                Text("The import was stopped. Run it again to import the remaining items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TransferIssueList(title: "Failed (retried next time)", issues: report.failures)
            TransferIssueList(title: "Imported with notes", issues: report.warnings)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
