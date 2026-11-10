import SwiftUI

struct StorageSettingsView: View {
    @StateObject private var viewModel: StorageSettingsViewModel
    @State private var isConfirmingClearCache = false
    @State private var isConfirmingClearDownloads = false
    private let viewFactory: AppViewFactory?

    init(viewModel: StorageSettingsViewModel, viewFactory: AppViewFactory? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    var body: some View {
        Form {
            if viewModel.hasDownloads {
                Section {
                    HStack {
                        Text("Downloaded Chapters", comment: "Storage settings: offline chapters disk usage")
                        Spacer()
                        Text(viewModel.formattedDownloadUsage).foregroundColor(.secondary)
                    }
                    if let message = viewModel.measurementMessage {
                        Text(message).font(.footnote).foregroundColor(.secondary)
                    }
                    if let viewFactory {
                        NavigationLink(destination: viewFactory.makeDownloadsView()) {
                            Text("Manage Downloads", comment: "Storage settings: open the downloads manager")
                        }
                    }
                    Button(role: .destructive) { isConfirmingClearDownloads = true } label: {
                        Text("Delete Downloaded Chapters", comment: "Storage settings: delete every stored chapter, separate from Clear Cache")
                    }
                    .disabled(viewModel.isClearingDownloads || viewModel.downloadBytes == nil || viewModel.downloadBytes == 0)
                } header: {
                    Text("Downloads", comment: "Storage settings offline downloads section")
                } footer: {
                    Text("Clearing the cache doesn't remove downloaded chapters.",
                         comment: "Offline chapters are durable data, separate from the image and network cache")
                }
            }
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
        .task {
            await viewModel.refreshCacheUsage()
            await viewModel.refreshDownloadsUsage()
        }
        .confirmationDialog(
            "Clear Cache?",
            isPresented: $isConfirmingClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text("Cached images and pages are removed and downloaded again when needed. Downloaded chapters are kept.",
                 comment: "Clear Cache confirmation: offline chapters are not cache data")
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
        .confirmationDialog(
            Text("Delete Downloaded Chapters?", comment: "Storage settings confirm offline data deletion"),
            isPresented: $isConfirmingClearDownloads, titleVisibility: .visible
        ) {
            Button(role: .destructive) { Task { await viewModel.clearDownloads() } } label: {
                Text("Delete Downloaded Chapters", comment: "Confirm deleting offline chapters, not image cache")
            }
        } message: {
            Text("All saved chapters are deleted and all queued downloads are cancelled. Chapters still held by an open reader are removed when the reader closes.",
                 comment: "Storage settings warns that deleting downloads removes saved chapters, cancels the download queue, and waits for open readers")
        }
        .downloadsMessage($viewModel.downloadsMessage)
    }
}
