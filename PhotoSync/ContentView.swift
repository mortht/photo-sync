import SwiftUI

/// Two-pane album browser: Apple Photos on the left, Google on the right.
struct ContentView: View {
    @State private var apple = AppleLibraryModel()
    @State private var takeout = TakeoutModel()

    var body: some View {
        HSplitView {
            AppleAlbumsPane(model: apple)
                .frame(minWidth: 340, maxWidth: .infinity)
            TakeoutPane(model: takeout)
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
