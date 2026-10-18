import SwiftUI

/// Two-pane album browser: Apple Photos on the left, Google on the right.
struct ContentView: View {
    @State private var apple = AppleLibraryModel()
    @State private var takeout = TakeoutModel()
    @State private var google = GoogleAccountModel()
    @State private var transfer: TransferModel?
    @State private var takeoutImport: ImportModel?
    @State private var syncStatus = SyncStatusModel()

    var body: some View {
        HSplitView {
            AppleAlbumsPane(model: apple, syncStatus: syncStatus, canTransfer: google.isSignedIn) { album in
                transfer = TransferModel(album: album)
            }
            .frame(minWidth: 340, maxWidth: .infinity)
            TakeoutPane(model: takeout, syncStatus: syncStatus, canImport: apple.hasAccess) { album in
                takeoutImport = ImportModel(album: album)
            }
            .frame(minWidth: 340, maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                GoogleAccountButton(model: google)
            }
        }
        .task {
            await google.start()
            await syncStatus.refresh()
        }
        .sheet(item: $transfer, onDismiss: refreshSyncStatus) { transfer in
            TransferSheet(model: transfer, google: google)
        }
        .sheet(item: $takeoutImport, onDismiss: refreshSyncStatus) { takeoutImport in
            ImportSheet(model: takeoutImport)
        }
    }

    private func refreshSyncStatus() {
        Task { await syncStatus.refresh() }
    }
}
