import SwiftUI

/// Two-pane album browser: Apple Photos on the left, Google on the right.
struct ContentView: View {
    @State private var apple = AppleLibraryModel()
    @State private var takeout = TakeoutModel()
    @State private var google = GoogleAccountModel()
    @State private var transfer: TransferModel?

    var body: some View {
        HSplitView {
            AppleAlbumsPane(model: apple, canTransfer: google.isSignedIn) { album in
                transfer = TransferModel(album: album)
            }
            .frame(minWidth: 340, maxWidth: .infinity)
            TakeoutPane(model: takeout)
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                GoogleAccountButton(model: google)
            }
        }
        .task { await google.start() }
        .sheet(item: $transfer) { transfer in
            TransferSheet(model: transfer, google: google)
        }
    }
}
