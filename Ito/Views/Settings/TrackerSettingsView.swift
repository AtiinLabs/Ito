import SwiftUI

struct TrackerSettingsView: View {
    @StateObject private var viewModel: TrackerSettingsViewModel

    init(viewModel: TrackerSettingsViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            ForEach(viewModel.providers) { provider in
                Section(
                    header: Text(provider.name),
                    footer: Text(viewModel.footer(for: provider))
                ) {
                    providerContent(provider)

                    if let failure = viewModel.failure(for: provider.identifier) {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            Section(
                header: Text("Preferences"),
                footer: Text("When updating or tracking a series, automatically mark all previous chapters or episodes as read/watched in your local library.")
            ) {
                Toggle(
                    "Sync Trackers to Local Library",
                    isOn: $viewModel.syncTrackersToLocal
                )
            }
        }
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: viewModel.refreshAuthoritativeState)
        .onDisappear(perform: viewModel.cancelOwnedWork)
        .sheet(item: $viewModel.signInSheetProvider) { provider in
            TrackerTokenSignInSheet(provider: provider) { token in
                viewModel.signIn(providerID: provider.identifier, token: token)
            }
        }
    }

    @ViewBuilder
    private func providerContent(_ provider: TrackerProviderPresentation) -> some View {
        switch provider.credentialState {
        case .loading:
            HStack {
                ProgressView()
                    .padding(.trailing, 8)
                Text("Checking saved credentials…")
            }
        case .deferred:
            Label(
                "Saved credentials will be checked when protected data is available.",
                systemImage: "lock.fill"
            )
            .foregroundColor(.secondary)
        case .unavailable:
            Label(
                "Saved credentials are currently unavailable.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundColor(.orange)
        case .ready where provider.isAuthenticated:
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.accentColor)
                if let username = provider.username {
                    Text("Logged in as \(username)")
                } else {
                    Text("Logged in")
                }
                Spacer()
            }

            Button {
                viewModel.logout(providerID: provider.identifier)
            } label: {
                HStack {
                    if viewModel.operatingProviderID == provider.identifier,
                       viewModel.operationKind == .logout {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text("Sign Out")
                        .foregroundColor(.red)
                }
            }
            .disabled(viewModel.isAuthenticationOperationActive)
        case .ready:
            Button {
                viewModel.authenticate(providerID: provider.identifier)
            } label: {
                HStack {
                    if viewModel.operatingProviderID == provider.identifier,
                       viewModel.operationKind == .authentication {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text("Sign In with \(provider.name)")
                        .foregroundColor(.accentColor)
                }
            }
            .disabled(viewModel.isAuthenticationOperationActive)

            if provider.tokenCreationURL != nil {
                Button("Use a Personal Access Token") {
                    viewModel.presentTokenSignIn(providerID: provider.identifier)
                }
                .disabled(viewModel.isAuthenticationOperationActive)
            }
        }
    }
}

struct TrackerSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let dependencies = PreparedTrackingDependencies.unavailable()
        return NavigationView {
            TrackerSettingsView(
                viewModel: TrackerSettingsViewModel(
                    service: dependencies.settingsService,
                    settingsStore: dependencies.settingsStore,
                    messagePresenter: NoopTrackingMessagePresenter(),
                    presentationLogger: OSLogPresentationEventLogger()
                )
            )
        }
    }
}
