import Photos
import SwiftUI

struct AppleAlbumsPane: View {
    let model: AppleLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Apple Photos", systemImage: "apple.logo") {
                if model.hasAccess {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.isLoading)
                    .help("Reload albums")
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.start() }
    }

    @ViewBuilder private var content: some View {
        switch model.authorization {
        case .authorized:
            if !model.hasLoaded {
                ProgressView("Loading albums…")
            } else if model.albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "rectangle.stack",
                                       description: Text("Your Photos library has no albums yet."))
            } else {
                albumList
            }
        case .notDetermined:
            ContentUnavailableView {
                Label("Photos Access Needed", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Photo Sync needs full access to your library to list albums, including Shared Albums.")
            } actions: {
                Button("Allow Access") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            ContentUnavailableView {
                Label("No Photos Access", systemImage: "lock")
            } description: {
                Text("Allow full access for Photo Sync in System Settings › Privacy & Security › Photos.")
            } actions: {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }
        }
    }

    private var albumList: some View {
        List {
            if !model.regularAlbums.isEmpty {
                Section("Albums") {
                    ForEach(model.regularAlbums) { row(for: $0) }
                }
            }
            if !model.sharedAlbums.isEmpty {
                Section("Shared Albums") {
                    ForEach(model.sharedAlbums) { row(for: $0) }
                }
            }
        }
    }

    private func row(for album: AppleAlbum) -> some View {
        AlbumRow(
            title: album.title,
            subtitle: album.folderPath.isEmpty ? nil : album.folderPath.joined(separator: " › "),
            photoCount: album.photoCount,
            videoCount: album.videoCount
        ) {
            AssetThumbnail(assetID: album.keyAssetID, fallbackSymbol: album.kind == .shared
                ? "person.2.crop.square.stack" : "rectangle.stack")
        }
    }
}

struct AssetThumbnail: View {
    let assetID: String?
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                SymbolArtwork(systemName: fallbackSymbol)
            }
        }
        .task(id: assetID) {
            guard let assetID else { return }
            image = await ThumbnailLoader.thumbnail(forAssetID: assetID, pointSize: 44)?.image
        }
    }
}
