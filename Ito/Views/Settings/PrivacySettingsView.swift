import SwiftUI

struct PrivacySettingsView: View {
    @StateObject private var viewModel: PrivacySettingsViewModel
    @FocusState private var isEditingDiscordURL: Bool

    init(viewModel: PrivacySettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section(
                header: Text("History"),
                footer: Text("When Incognito Mode is enabled, items you read or watch will not be saved to your History. Your library and progress trackers will still be updated.")
            ) {
                Toggle(isOn: Binding(
                    get: { viewModel.incognitoMode },
                    set: { value in
                        Task { await viewModel.setIncognitoMode(value) }
                    }
                )) {
                    Label("Incognito Mode", systemImage: "eyes")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.discordRPCEnabled },
                    set: { value in
                        Task { await viewModel.setDiscordRPCEnabled(value) }
                    }
                )) {
                    Label("Discord Rich Presence", systemImage: "gamecontroller")
                }

                if viewModel.showsDiscordDetails {
                    TextField("Server URL (e.g. ws://127.0.0.1:3000)", text: $viewModel.discordRPCURLDraft)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .focused($isEditingDiscordURL)
                        .onChange(of: isEditingDiscordURL) { isEditing in
                            guard !isEditing else { return }
                            Task { await viewModel.commitDiscordRPCURLDraft() }
                        }

                    HStack {
                        Text("Status")
                        Spacer()
                        discordStatus
                    }
                }
            } header: {
                Text("Discord Integration")
            } footer: {
                Text("Shows what you're reading or watching on your Discord profile. Needs a Rich Presence bridge running at the server address.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            Task { await viewModel.commitDiscordRPCURLDraft(discardingInvalid: true) }
        }
        .alert(item: Binding(
            get: { viewModel.alert },
            set: { alert in
                if alert == nil {
                    viewModel.dismissAlert()
                }
            }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
                }
            )
        }
    }

    @ViewBuilder
    private var discordStatus: some View {
        switch viewModel.discordState {
        case .connected:
            Text("Connected").foregroundColor(.green)
        case .connecting:
            Text("Connecting...").foregroundColor(.yellow)
        case .disconnected:
            Text("Disconnected").foregroundColor(.gray)
        case .error(let message):
            Text("Error: \(message)").foregroundColor(.red).lineLimit(1)
        }
    }
}
