import NukeUI
import SwiftUI

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
                    .foregroundColor(.white)
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
                        Text(repository.index?.repoName ?? "Unknown Repository")
                            .font(.headline)
                        Text(repository.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let count = repository.index?.packages.count {
                            Text("\(count) package\(count == 1 ? "" : "s")")
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
        .navigationTitle(viewModel.repository?.index?.repoName ?? "Repository")
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
                            isInstalling: viewModel.isInstalling(packageID: package.id)
                        ) {
                            Task { await viewModel.installPackage(package) }
                        }
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
    let installState: RepoDetailViewModel.InstallState
    let isInstalling: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name)
                    .font(.headline)
                Text("v\(pkg.version) • \(pkg.pluginType.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.blue)
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
            case .incompatible(let minVersion):
                Text("Requires v\(minVersion)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)

            case .updateAvailable:
                Button("Update", action: onAction)
                    .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Preview

struct RepositoriesView_Previews: PreviewProvider {
    static var previews: some View {
        Text("RepositoriesView requires a prepared runtime")
    }
}
