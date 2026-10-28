import SwiftUI

/// A settings sheet that doesn't need the source's home to work first.
struct PluginSettingsRecoverySheet: View {
    @StateObject private var viewModel: PluginSettingsLoaderViewModel
    @Environment(\.dismiss) private var dismiss
    private let viewFactory: AppViewFactory

    init(viewModel: PluginSettingsLoaderViewModel, viewFactory: AppViewFactory) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    var body: some View {
        Group {
            if let destination = viewModel.destination {
                viewFactory.makePluginSettingsView(destination: destination)
            } else {
                NavigationView {
                    Form {
                        if let failure = viewModel.failure {
                            Section {
                                Text(failure)
                                Button("Retry") { Task { await viewModel.load() } }
                            }
                        } else {
                            ProgressView("Loading source settings…")
                        }
                    }
                    .navigationTitle("Source Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarItems(trailing: Button("Done") { dismiss() })
                }
            }
        }
        .task { await viewModel.load() }
        .onDisappear { viewModel.settingsClosed() }
    }
}
