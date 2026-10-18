import SwiftUI

/// Toolbar control showing the Google connection state.
struct GoogleAccountButton: View {
    @Bindable var model: GoogleAccountModel
    @State private var showsSetupHelp = false

    var body: some View {
        Group {
            switch model.state {
            case .notConfigured:
                Button {
                    showsSetupHelp = true
                } label: {
                    Label("Google Not Configured", systemImage: "exclamationmark.circle")
                }
                .popover(isPresented: $showsSetupHelp) {
                    Text("""
                        Add your Google OAuth client to Config/Secrets.xcconfig \
                        (copy Secrets.example.xcconfig), then rebuild. See the README \
                        for the Google Cloud setup.
                        """)
                    .frame(width: 280)
                    .padding()
                }
            case .signedOut:
                Button("Connect Google…") { model.signIn() }
            case .signingIn:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser…")
                    Button("Cancel") { model.cancelSignIn() }
                }
            case .signedIn(let email):
                Menu {
                    Button("Disconnect") { Task { await model.signOut() } }
                } label: {
                    Label(email ?? "Google Account", systemImage: "person.crop.circle.badge.checkmark")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .alert("Google Sign-In Failed", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
