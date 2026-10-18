import SwiftUI

/// A list row showing an album's artwork, title and item counts.
struct AlbumRow<Artwork: View>: View {
    let title: String
    let subtitle: String?
    let photoCount: Int
    let videoCount: Int
    var warning: String?
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        HStack(spacing: 10) {
            artwork()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text([subtitle, Self.countSummary(photos: photoCount, videos: videoCount)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let warning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(warning)
            }
        }
        .padding(.vertical, 2)
    }

    static func countSummary(photos: Int, videos: Int) -> String {
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append("\(photos) \(photos == 1 ? "photo" : "photos")") }
        if videos > 0 { parts.append("\(videos) \(videos == 1 ? "video" : "videos")") }
        return parts.joined(separator: ", ")
    }
}

/// Placeholder artwork with an SF Symbol.
struct SymbolArtwork: View {
    let systemName: String

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
        }
    }
}

/// Title bar above each pane of the browser.
struct PaneHeader<Actions: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
