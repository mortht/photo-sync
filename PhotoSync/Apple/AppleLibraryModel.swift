import Observation
import Photos

@MainActor
@Observable
final class AppleLibraryModel {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var albums: [AppleAlbum] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    @ObservationIgnored private var observer: LibraryChangeObserver?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var changedSinceReload = false

    var hasAccess: Bool { authorization == .authorized }
    var regularAlbums: [AppleAlbum] { albums.filter { $0.kind == .regular } }
    var sharedAlbums: [AppleAlbum] { albums.filter { $0.kind == .shared } }

    func start() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else { return }
        startObserving()
        if !hasLoaded { await reload() }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await start()
    }

    func reload() async {
        isLoading = true
        albums = await Task.detached(priority: .userInitiated) { PhotoKitAlbums.fetchAll() }.value
        isLoading = false
        hasLoaded = true
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    /// Reloads at most once every few seconds. An import adds assets one by
    /// one, and each change would otherwise refetch every album.
    private func scheduleReload() {
        changedSinceReload = true
        guard reloadTask == nil else { return }
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(3))
            changedSinceReload = false
            await reload()
            reloadTask = nil
            // Changes that arrived during the reload.
            if changedSinceReload { scheduleReload() }
        }
    }
}
