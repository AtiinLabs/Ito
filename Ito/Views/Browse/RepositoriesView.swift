import NukeUI
import SwiftUI
import ito_runner

// MARK: - RepositoriesView

struct RepositoriesView: View {
    @StateObject private var viewModel: RepositoriesViewModel
    @State private var selectedRepositoryURL: String?

    private let makeRepoDetailViewModel: (String) -> RepoDetailViewModel

    init(
        viewModel: RepositoriesViewModel,
        makeRepoDetailViewModel: @escaping (String) -> RepoDetailViewModel
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.makeRepoDetailViewModel = makeRepoDetailViewModel
    }

    var body: some View {
        Group {
            if viewModel.isEmpty {
                emptyStateView
            } else {
                repositoryListView
            }
        }
        .navigationTitle("Repositories")
        .navigationBarItems(
            trailing: Button(action: viewModel.presentAddRepository) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Repository")
        )
        .sheet(isPresented: $viewModel.showingAddRepository) {
            addRepositorySheet
        }
        .confirmationDialog(
            "Remove Repository",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel, action: viewModel.cancelDelete)
        } message: {
            Text("This repository and all its associated data will be removed.")
        }
        .refreshable {
            await viewModel.refreshRepositories()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("No Repositories")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add a repository URL to discover and install plugins.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: viewModel.presentAddRepository) {
                Label("Add Repository", systemImage: "plus")
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

    private var repositoryListView: some View {
        List {
            ForEach(viewModel.repositories) { repository in
                NavigationLink(
                    destination: RepoDetailView(
                        viewModel: makeRepoDetailViewModel(repository.url)
                    ),
                    tag: repository.url,
                    selection: $selectedRepositoryURL
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repository.index?.repoName ?? String(localized: "Unknown Repository"))
                            .font(.headline)
                        Text(repository.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let count = repository.index?.packages.count {
                            Text("\(count) packages")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.requestDelete(repositoryURL: repository.url)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(viewModel.deletingRepositoryURLs.contains(repository.url))
                }
            }
        }
    }

    private var addRepositorySheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField(
                        "https://example.com/repo",
                        text: $viewModel.repositoryURLInput
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(viewModel.isAddingRepository)
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("Enter the full URL to the repository. The app will fetch index.json from this address.")
                }

                if let error = viewModel.addFailureMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel", action: viewModel.cancelAddRepository)
                    .disabled(viewModel.isAddingRepository),
                trailing: Group {
                    if viewModel.isAddingRepository {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Button {
                            Task { await viewModel.addRepository() }
                        } label: {
                            Text("Add")
                                .font(.body.weight(.semibold))
                        }
                        .disabled(!viewModel.canSubmitRepository)
                    }
                }
            )
        }
        .interactiveDismissDisabled(viewModel.isAddingRepository)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showDeleteConfirmation },
            set: { isPresented in
                if !isPresented {
                    viewModel.deleteConfirmationDismissed()
                }
            }
        )
    }
}

// MARK: - RepoDetailView

struct RepoDetailView: View {
    @StateObject private var viewModel: RepoDetailViewModel

    init(viewModel: RepoDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            if viewModel.repository?.index == nil {
                missingIndexView
            } else {
                packageListView
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search packages")
        .navigationTitle(viewModel.repository?.index?.repoName ?? String(localized: "Repository"))
        .navigationBarTitleDisplayMode(.large)
    }

    private var missingIndexView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)

            Text("Index Unavailable")
                .font(.title3)
                .fontWeight(.semibold)

            Text("The repository index could not be loaded. Pull to refresh or check the repository URL.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var packageListView: some View {
        List {
            if let description = viewModel.repository?.index?.description,
               !description.isEmpty {
                Section {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if viewModel.filteredPackages.isEmpty {
                    Text("No packages match your search.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(viewModel.filteredPackages, id: \.id) { package in
                        PackageRowView(
                            pkg: package,
                            repositoryUrl: viewModel.repositoryURL,
                            installState: viewModel.installState(for: package),
                            isInstalling: viewModel.isInstalling(packageID: package.id),
                            isRefreshingSources: viewModel.isRefreshingSources,
                            onAction: { Task { await viewModel.installPackage(package) } },
                            onRefreshSources: { Task { await viewModel.refreshSources() } }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Packages")
                    Spacer()
                    if let total = viewModel.repository?.index?.packages.count {
                        Text("\(total)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - PackageRowView

struct PackageRowView: View {
    let pkg: RepoPackage
    let repositoryUrl: String
    let installState: PackageInstallStatus
    let isInstalling: Bool
    let isRefreshingSources: Bool
    let onAction: () -> Void
    let onRefreshSources: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("v\(pkg.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !pkg.supportedKinds.isEmpty {
                        ForEach(pkg.supportedKinds, id: \.self) { kind in
                            PluginTypeBadge(type: kind)
                        }
                    } else {
                        Text("• \(pkg.pluginType.capitalized)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if pkg.isArchived {
                    Label("Archived", systemImage: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer()

            actionView
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = pkg.iconUrl, let url = URL(string: "\(repositoryUrl)/\(icon)") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
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
    }

    @ViewBuilder
    private var actionView: some View {
        if isInstalling {
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: 72)
        } else {
            switch installState {
            case .archived:
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let reason = pkg.archivedReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !reason.isEmpty {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

            case .requiresNewerApp(let minimumAppVersion):
                Text(Self.newerAppLabel(minimumAppVersion: minimumAppVersion))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)

            case .sourceUpdateRequired:
                Button(action: onAction) {
                    Text(
                        "Update Source",
                        comment: "Button that installs a compatible build of a source this version of Ito can't run, replacing the installed file."
                    )
                }
                .itoProminentButtonStyle()
                .controlSize(.small)

            case .repairUnverified:
                VStack(alignment: .trailing, spacing: 4) {
                    Text(
                        "Compatibility unknown",
                        comment: "Status under a source that can't run here, when its repository listing does not state the ABI it was built for. The app cannot tell whether installing it helps, so it does not claim that it will."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    Button(action: onAction) {
                        Text("Install", comment: "Button that installs a source package.")
                    }
                    .itoProminentButtonStyle()
                    .controlSize(.small)
                }

            case .noCompatibleUpdate:
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.noCompatibleUpdateText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                    if isRefreshingSources {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .accessibilityLabel(
                                Text(
                                    "Refreshing sources",
                                    comment: "VoiceOver label of the progress indicator shown while every repository's source list is being refreshed."
                                )
                            )
                    } else {
                        Button(action: onRefreshSources) {
                            Text(
                                "Refresh Sources",
                                comment: "Button that refreshes every repository's source list, so a source can be checked against newer builds. Not the same as refreshing chapters."
                            )
                        }
                        .controlSize(.small)
                    }
                }

            case .unavailableForThisIto:
                // A status, not an action: the source cannot be installed here, so there is no button to press.
                Text(
                    "Built for an older Ito",
                    comment: "Label under a source that is offered only in a build for an older version of Ito, which this version can't run. It is a status, not a button."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)

            case .updateAvailable:
                Button("Update", action: onAction)
                    .itoProminentButtonStyle()
                    .controlSize(.small)

            case .installed:
                Label("Installed", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())

            case .notInstalled:
                Button("Install", action: onAction)
                    .itoProminentButtonStyle()
                    .controlSize(.small)
            }
        }
    }

    /// The short label for a package whose installed source needs a newer Ito than this one.
    private static func newerAppLabel(minimumAppVersion: String?) -> String {
        if let minimumAppVersion {
            return String(localized: "Requires v\(minimumAppVersion)")
        }
        return String(localized: "Requires a newer Ito")
    }

    /// Shown where a source was built for an older version of Ito and this repository lists no build this version runs.
    /// Other repositories are not consulted here, so the text names this repository only.
    private static let noCompatibleUpdateText = String(
        localized: "No compatible build in this repository yet.",
        comment: "Shown on a source's row when this repository lists no build this version of Ito can run, though the installed file cannot run. Other repositories may list one, so the text names this repository only. Refreshing the sources may bring a build."
    )
}

// MARK: - Preview

struct RepositoriesView_Previews: PreviewProvider {
    static var previews: some View {
        Text("RepositoriesView requires a prepared runtime")
    }
}
