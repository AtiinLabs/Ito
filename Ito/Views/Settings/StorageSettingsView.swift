import SwiftUI

struct StorageSettingsView: View {
    @StateObject private var viewModel: StorageSettingsViewModel
    @State private var isConfirmingClearCache = false

    init(viewModel: StorageSettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section(
                header: Text("Image & Network Cache"),
                footer: Text("Set the maximum amount of disk space Ito is allowed to use for caching images and network responses.")
            ) {
                Picker("Cache Limit", selection: Binding(
                    get: { viewModel.diskCacheLimitGB },
                    set: { value in
                        Task { await viewModel.setDiskCacheLimitGB(value) }
                    }
                )) {
                    ForEach(viewModel.cacheLimitChoices, id: \.self) { value in
                        Text("\(Int(value)) GB").tag(value)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Current Usage")
                    Spacer()
                    Text(viewModel.formattedCurrentUsage)
                        .foregroundColor(.secondary)
                }

                Button(role: .destructive) {
                    isConfirmingClearCache = true
                } label: {
                    HStack {
                        Text("Clear Cache")
                        if viewModel.isClearingCache {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isClearingCache)
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refreshCacheUsage() }
        .confirmationDialog(
            "Clear Cache?",
            isPresented: $isConfirmingClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text("Cached images and pages are removed and downloaded again when needed.")
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
