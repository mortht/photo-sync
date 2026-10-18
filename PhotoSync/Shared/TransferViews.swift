import PhotoSyncCore
import SwiftUI

/// Progress bar with the current file and a Stop button.
struct TransferProgressSection: View {
    let progress: TransferProgress
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fractionCompleted) {
                Text("\(progress.processed) of \(progress.total) items")
            } currentValueLabel: {
                Text(progress.currentFileName ?? " ")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                if progress.skipped > 0 {
                    Text("\(progress.skipped) already copied")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if progress.failed > 0 {
                    Label("\(progress.failed) failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                Button("Stop", action: onStop)
            }
        }
    }
}

/// Summary line shown when a transfer ends.
struct TransferResultLabel: View {
    let text: String
    let isComplete: Bool

    var body: some View {
        Label(text, systemImage: isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isComplete ? .green : .orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Per-item problems, e.g. failed or partially imported files.
struct TransferIssueList: View {
    let title: String
    let issues: [TransferFailure]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                List(issues, id: \.self) { issue in
                    VStack(alignment: .leading) {
                        Text(issue.fileName)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: min(CGFloat(issues.count) * 44 + 8, 160))
            }
        }
    }
}

/// An error that stopped the whole transfer.
struct TransferErrorView: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
