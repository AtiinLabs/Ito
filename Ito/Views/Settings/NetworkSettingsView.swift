import SwiftUI

struct NetworkSettingsView: View {
    @StateObject private var viewModel: NetworkSettingsViewModel
    @State private var showingClearConfirmation = false
    @State private var showingResetConfirmation = false

    init(viewModel: NetworkSettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Download Network", comment: "Configured bulk download network mode"), selection: Binding(
                    get: { viewModel.downloadMode }, set: { value in Task { await viewModel.setDownloadMode(value) } }
                )) {
                    ForEach(NetworkDownloadMode.allCases, id: \.self) { mode in Text(mode.localizedTitle).tag(mode) }
                }
                Text(viewModel.effective.bulkDownloads.localizedReason).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker(String(localized: "Image Preload", comment: "Configured number of speculative reader images"), selection: Binding(
                    get: { viewModel.preloadImageCount }, set: { value in Task { await viewModel.setPreload(value) } }
                )) {
                    ForEach(ImagePreloadCountPreference.allCases, id: \.self) { count in Text(count.localizedTitle).tag(count) }
                }
                Picker(String(localized: "Adjacent Chapters", comment: "Number of neighbor manga chapter manifests to prefetch"), selection: Binding(
                    get: { viewModel.adjacentPrefetch }, set: { value in Task { await viewModel.setAdjacent(value) } }
                )) {
                    ForEach(AdjacentChapterPrefetchPreference.allCases, id: \.self) { count in Text("\(count.rawValue)").tag(count) }
                }
                Toggle(String(localized: "Prefetch Novel Chapters", comment: "Configured speculative novel chapter loading"), isOn: Binding(
                    get: { viewModel.novelPrefetch }, set: { value in Task { await viewModel.setNovelPrefetch(value) } }
                ))
                Text(viewModel.effective.speculative.localizedReason).font(.footnote).foregroundStyle(.secondary)
                if viewModel.effective.adjacentHeldByPreload {
                    Text("Adjacent prefetch is off while Image Preload is off.", comment: "Explains effective restriction without changing configured adjacent amount")
                }
            } header: {
                Text("Reader Prefetch", comment: "Network settings section for speculative reader work")
            }
            Button(String(localized: "Reset Network and Prefetch Settings", comment: "Resets only five network and reader prefetch preferences"), role: .destructive) {
                showingResetConfirmation = true
            }
            Section {
                Toggle("Check on Wi-Fi Only", isOn: Binding(
                    get: { viewModel.wifiOnlyUpdates },
                    set: { value in
                        Task { await viewModel.setWifiOnlyUpdates(value) }
                    }
                ))
                Text(viewModel.effective.automaticChecks.localizedReason).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Automatic Updates")
            } footer: {
                Text("Automatic update checks are skipped on cellular data and personal hotspots. Refreshing the library by hand always checks.")
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
            String(localized: "Reset Network and Prefetch Settings?", comment: "Confirmation of scoped settings reset"),
            isPresented: $showingResetConfirmation, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { Task { await viewModel.resetNetworkPreferences() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores network and prefetch defaults only. Credentials, cookies, site data and reading state are kept.", comment: "Exact scope of network settings reset")
        }
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
