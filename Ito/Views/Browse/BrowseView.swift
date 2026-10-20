import NukeUI
import SwiftUI
import UniformTypeIdentifiers
import ito_runner

extension UTType {
    static var ito: UTType {
        UTType(exportedAs: "moe.itoapp.ito", conformingTo: .zip)
    }
}

// MARK: - BrowseView

// This wrapper deliberately does not observe the model. AppScope owns the stable
// model while the child content view observes it, preserving NavigationView identity.
struct BrowseView: View {
    let viewModel: BrowseViewModel
    let makeRepositoriesView: () -> RepositoriesView
    let makeSourceView: (InstalledPlugin) -> SourceView

    var body: some View {
        NavigationView {
            BrowseContentView(
                viewModel: viewModel,
                makeRepositoriesView: makeRepositoriesView,
                makeSourceView: makeSourceView
            )
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - BrowseContentView

private struct BrowseContentView: View {
    @ObservedObject var viewModel: BrowseViewModel
    let makeRepositoriesView: () -> RepositoriesView
    let makeSourceView: (InstalledPlugin) -> SourceView

    var body: some View {
        ZStack {
            NavigationLink(
                destination: makeRepositoriesView(),
                isActive: $viewModel.showRepositories
            ) {
                EmptyView()
            }
            .hidden()

            if viewModel.sortedPlugins.isEmpty {
                emptyStateView
            } else {
                pluginListView
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.item, .fileURL, .ito], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .task {
            await viewModel.refreshStaleRepositories()
        }
        .navigationTitle("Browse")
        .navigationBarItems(trailing: repositoriesButton)
        .confirmationDialog(
            "Remove Plugin",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: {
            Text("This plugin will be permanently removed from your device.")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("No Plugins Installed")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Drop a .ito plugin file here, or browse repositories to find and install plugins.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: viewModel.openRepositories) {
                Label("Browse Repositories", systemImage: "globe")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.itoOnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pluginListView: some View {
        List {
            if !viewModel.availableUpdates.isEmpty {
                Section {
                    ForEach(viewModel.availableUpdates) { updateItem in
                        UpdateRowView(
                            updateItem: updateItem,
                            isInstalling: viewModel.isInstallingUpdate == updateItem.id
                        ) {
                            Task { await viewModel.installUpdate(updateItem) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Updates Available")
                        Spacer()
                        Text("\(viewModel.availableUpdates.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.itoOnAccent)
                            .clipShape(Capsule())
                    }
                }
            }

            Section {
                ForEach(viewModel.sortedPlugins, id: \.id) { plugin in
                    NavigationLink(destination: makeSourceView(plugin)) {
                        PluginRowView(plugin: plugin)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.requestDelete(plugin)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Installed")
                    Spacer()
                    Text("\(viewModel.sortedPlugins.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable {
            await viewModel.refreshRepositories()
        }
    }

    private var repositoriesButton: some View {
        Button(action: viewModel.openRepositories) {
            Image(systemName: "globe")
        }
        .accessibilityLabel("Repositories")
        .accessibilityHint("Manage plugin repositories")
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              let typeIdentifier = supportedTypeIdentifier(for: provider) else {
            return false
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            Task { @MainActor in
                guard let url else {
                    viewModel.reportDropLoadingFailure(error)
                    return
                }
                _ = await viewModel.importPluginFile(at: url, source: .drop)
            }
        }
        return true
    }

    private func supportedTypeIdentifier(for provider: NSItemProvider) -> String? {
        [
            UTType.ito.identifier,
            UTType.archive.identifier,
            UTType.zip.identifier,
            UTType.fileURL.identifier
        ].first(where: provider.hasItemConformingToTypeIdentifier)
    }

    private func handleOpenURL(_ url: URL) {
        guard url.isFileURL || url.pathExtension.lowercased() == "ito" else { return }

        Task { @MainActor in
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            _ = await viewModel.importPluginFile(at: url, source: .openURL)
        }
    }
}

// MARK: - UpdateRowView

private struct UpdateRowView: View {
    let updateItem: BrowseViewModel.UpdateItem
    let isInstalling: Bool
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = updateItem.pkg.iconUrl,
               let url = URL(string: "\(updateItem.repoURL)/\(icon)") {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.large)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(updateItem.pkg.name)
                    .font(.headline)
                Text("v\(updateItem.pkg.version) available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalling {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 70)
            } else {
                Button("Update", action: onUpdate)
                    .itoProminentButtonStyle()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - PluginRowView

struct PluginRowView: View {
    let plugin: InstalledPlugin

    var body: some View {
        HStack(spacing: 12) {
            if let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.large)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.info.name)
                    .font(.headline)
                Text("v\(plugin.info.version) • \(plugin.info.author ?? "Unknown")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if plugin.info.archived ?? false {
                    Label("Archived", systemImage: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer()

            PluginTypeBadge(type: plugin.info.type)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PluginTypeBadge

struct PluginTypeBadge: View {
    let type: PluginType

    private var style: (title: String, icon: String, color: Color) {
        switch type {
        case .anime: return ("Anime", "play.tv", .purple)
        case .manga: return ("Manga", "book.closed", .orange)
        case .novel: return ("Novel", "text.book.closed", .green)
        }
    }

    var body: some View {
        Label(style.title, systemImage: style.icon)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.15))
            .foregroundStyle(style.color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Preview

struct BrowseView_Previews: PreviewProvider {
    static var previews: some View {
        Text("BrowseView requires a prepared runtime")
    }
}
