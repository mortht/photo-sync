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

    /// Coalesces bursts of change notifications into one reload.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }
}
