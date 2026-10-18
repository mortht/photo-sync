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
            case .ready: setup
            case .running:
                TransferProgressSection(progress: model.progress, isPreparing: false, onStop: model.cancel)
            case .finished(let report): finished(report)
            case .failed(let message): TransferErrorView(message: message) { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isRunning)
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
                TextField("Apple Photos album name", text: $model.targetTitle)
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
            Text("Creates a new album in Apple Photos and restores dates, locations and favorites from the Takeout metadata. Importing the same album again adds the photos a second time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.targetTitle.trimmingCharacters(in: .whitespaces).isEmpty || model.itemCount == 0)
            }
        }
    }

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransferResultLabel(
                text: "Imported \(model.progress.added) of \(model.progress.total) items into “\(report.albumTitle)”.",
                isComplete: report.failures.isEmpty && !report.wasCancelled
            )
            if report.wasCancelled {
                Text("The import was stopped. The album contains the items imported so far.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TransferIssueList(title: "Failed", issues: report.failures)
            TransferIssueList(title: "Imported with notes", issues: report.warnings)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
