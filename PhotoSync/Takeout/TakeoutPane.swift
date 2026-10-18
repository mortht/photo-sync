import PhotoSyncCore
import SwiftUI

struct TakeoutPane: View {
    @Bindable var model: TakeoutModel
    /// Whether Photos access was granted.
    let canImport: Bool
    let onImport: (TakeoutAlbum) -> Void
    @State private var isPickingFolder = false
    @State private var selection: TakeoutAlbum.ID?

    private var selectedAlbum: TakeoutAlbum? {
        model.library?.albums.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Google Takeout",
                systemImage: "shippingbox",
                subtitle: model.library?.rootURL.lastPathComponent
            ) {
                if model.library != nil {
                    Button("Choose Folder…") { isPickingFolder = true }
                        .buttonStyle(.borderless)
                        .disabled(model.isScanning)
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.library?.albums.isEmpty == false && !model.isScanning {
                Divider()
                HStack {
                    Spacer()
                    Button("Copy to Apple Photos…") {
                        if let selectedAlbum { onImport(selectedAlbum) }
                    }
                    .disabled(selectedAlbum == nil || !canImport)
                    .help(canImport ? "Import the selected album into a new Apple Photos album"
                                    : "Allow Photos access first")
                }
                .padding(8)
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.open(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Could Not Read Takeout Folder", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if model.isScanning {
            ProgressView("Scanning Takeout…")
        } else if let library = model.library, !library.albums.isEmpty {
            albumList
        } else {
            ContentUnavailableView {
                Label(model.library == nil ? "No Takeout Selected" : "No Photos Found", systemImage: "shippingbox")
            } description: {
                Text("Export your albums with Google Takeout, extract the archives, then choose the folder that contains them.")
            } actions: {
                Button("Choose Takeout Folder…") { isPickingFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var albumList: some View {
        List(selection: $selection) {
            section("Albums", model.albums)
            section("Photos by Year", model.years)
            section("Other", model.other)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ albums: [TakeoutAlbum]) -> some View {
        if !albums.isEmpty {
            Section(title) {
                ForEach(albums) { album in
                    AlbumRow(
                        title: album.title,
                        subtitle: album.folderURLs.count > 1 ? "\(album.folderURLs.count) archive parts" : nil,
                        photoCount: album.photoCount,
                        videoCount: album.videoCount,
                        warning: Self.warning(for: album)
                    ) {
                        SymbolArtwork(systemName: Self.symbol(for: album.kind))
                    }
                    .contextMenu {
                        Button("Copy to Apple Photos…") { onImport(album) }
                            .disabled(!canImport)
                    }
                }
            }
        }
    }

    static func symbol(for kind: TakeoutAlbum.Kind) -> String {
        switch kind {
        case .album: "rectangle.stack"
        case .year: "calendar"
        case .archive: "archivebox"
        case .trash: "trash"
        }
    }

    static func warning(for album: TakeoutAlbum) -> String? {
        var lines: [String] = []
        if album.assetsWithoutMetadata > 0 {
            lines.append("\(album.assetsWithoutMetadata) items have no metadata file; their date and location can't be restored.")
        }
        if !album.unmatchedSidecars.isEmpty {
            lines.append("\(album.unmatchedSidecars.count) metadata files don't match any photo.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
