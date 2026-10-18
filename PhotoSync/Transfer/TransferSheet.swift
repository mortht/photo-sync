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
            case .ready: setup
            case .preparing, .running: running
            case .finished(let report): finished(report)
            case .failed(let message): failed(message)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isActive)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Items", value: AlbumRow<EmptyView>.countSummary(
                    photos: model.album.photoCount, videos: model.album.videoCount))
                TextField("Google album name", text: $model.targetTitle)
            }
            Text("Creates a new album in Google Photos. Edited items are uploaded as you see them in Photos; Live Photos are uploaded as stills.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    guard let client = google.libraryClient() else { return }
                    model.start(client: client, onError: google.noteFailure)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.targetTitle.trimmingCharacters(in: .whitespaces).isEmpty || !google.isSignedIn)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .preparing = model.phase {
                ProgressView("Preparing…")
            } else {
                ProgressView(value: model.progress.fractionCompleted) {
                    Text("\(model.progress.completed) of \(model.progress.total) items")
                } currentValueLabel: {
                    Text(model.progress.currentFileName ?? " ")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack {
                if model.progress.failed > 0 {
                    Label("\(model.progress.failed) failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                Button("Stop") { model.cancel() }
            }
        }
    }

    private func finished(_ report: TransferReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Added \(report.addedItems.count) of \(model.progress.total) items to “\(report.album.title)”.",
                systemImage: report.failures.isEmpty && !report.wasCancelled
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(report.failures.isEmpty && !report.wasCancelled ? .green : .orange)
            if report.wasCancelled {
                Text("The transfer was stopped. Items not yet added were skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.failures.isEmpty {
                List(report.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.fileName)
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 160)
            }
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

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
