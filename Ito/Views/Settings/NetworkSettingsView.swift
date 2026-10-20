import SwiftUI

struct NetworkSettingsView: View {
    @StateObject private var viewModel: NetworkSettingsViewModel
    @State private var showingClearConfirmation = false

    init(viewModel: NetworkSettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Check on Wi-Fi Only", isOn: Binding(
                    get: { viewModel.wifiOnlyUpdates },
                    set: { value in
                        Task { await viewModel.setWifiOnlyUpdates(value) }
                    }
                ))
            } header: {
                Text("Automatic Updates")
            } footer: {
                Text("Automatic update checks wait for Wi-Fi or another network that isn't cellular. Refreshing the library by hand always checks.")
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    HStack {
                        Text("Clear Cookies and Site Data")
                        if viewModel.isClearingSiteData {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isClearingSiteData)
            } header: {
                Text("Site Data")
            } footer: {
                Text("Use this when a source stays blocked by Cloudflare or a website login stops working.")
            }
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear Cookies and Site Data",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await viewModel.clearSiteData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all cookies, cached website data and Cloudflare clearance. Sources that use a website login will need you to sign in again.")
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
}
