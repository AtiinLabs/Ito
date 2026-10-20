import SwiftUI

/// Collects a token for trackers that sign in with tokens instead of OAuth, such as MangaBaka.
struct TrackerTokenSignInSheet: View {
    let provider: TrackerProviderPresentation
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    footer: Text("Ito keeps the token in the Keychain on this device. Revoke it on \(provider.name) when you no longer need it.")
                ) {
                    SecureField("Personal Access Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit(submit)
                }

                if let url = provider.tokenCreationURL {
                    Section(
                        footer: Text("Create a Personal Access Token in your \(provider.name) settings, then paste it here.")
                    ) {
                        Link("Create a Token on \(provider.name)", destination: url)
                    }
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In", action: submit)
                        .disabled(trimmedToken.isEmpty)
                }
            }
        }
    }

    private func submit() {
        guard !trimmedToken.isEmpty else { return }
        onSubmit(trimmedToken)
    }
}
