import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    private let routeFactory: SearchRouteFactory
    private let makePluginSettings: (String) -> PluginSettingsRecoverySheet
    private let signInTarget: (String) -> PluginSignInTarget?
    private let makePluginSignIn: (PluginSignInTarget) -> PluginSignInSheet?
    @State private var settingsPlugin: SettingsPlugin?
    @State private var signInPlugin: PluginSignInTarget?

    private struct SettingsPlugin: Identifiable {
        let id: String
    }

    init(
        viewModel: SearchViewModel,
        routeFactory: SearchRouteFactory,
        makePluginSettings: @escaping (String) -> PluginSettingsRecoverySheet,
        signInTarget: @escaping (String) -> PluginSignInTarget? = { _ in nil },
        makePluginSignIn: @escaping (PluginSignInTarget) -> PluginSignInSheet? = { _ in nil }
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.routeFactory = routeFactory
        self.makePluginSettings = makePluginSettings
        self.signInTarget = signInTarget
        self.makePluginSignIn = makePluginSignIn
    }

    var body: some View {
        NavigationView {
            ScrollView {
                scopePicker
                searchContent
            }
            .navigationTitle("Search")
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Manga, Anime, and Novels"
            )
            .disableAutocorrection(true)
        }
        .navigationViewStyle(.stack)
        .sheet(item: $settingsPlugin, onDismiss: {
            viewModel.performSearch(query: viewModel.searchText)
        }) { plugin in
            makePluginSettings(plugin.id)
        }
        .sheet(item: $signInPlugin, onDismiss: {
            viewModel.performSearch(query: viewModel.searchText)
        }) { target in
            makePluginSignIn(target)
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $viewModel.searchScope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idleContent
        } else {
            switch viewModel.state {
            case .idle:
                emptyContent
            case .loading(let results, _):
                if results.isEmpty {
                    loadingContent
                } else {
                    resultsContent(results)
                    loadingMoreContent
                }
            case .content(let results):
                resultsContent(results)
            case .empty:
                emptyContent
            case .partialFailure(let results, _):
                if results.isEmpty {
                    partialFailureContent
                } else {
                    resultsContent(results)
                    partialFailureContent
                }
            case .failure:
                failureContent
            case .cancelled:
                cancelledContent
            }
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if !viewModel.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Searches")
                        .font(.title3)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearRecentSearches()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ForEach(viewModel.recentSearches, id: \.self) { recent in
                    Button {
                        viewModel.searchText = recent
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(recent)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 46)
                }
            }
        } else {
            VStack(spacing: 20) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                    .padding(.top, 100)

                Text("Explore")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Find Manga, Anime, and Novels across all your plugins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Searching plugins...")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 100)
    }

    private func resultsContent(_ results: SearchResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(results.keys.sorted(), id: \.self) { pluginName in
                if let pluginResults = results[pluginName], !pluginResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(pluginName: pluginName)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(pluginResults) { result in
                                    NavigationLink(
                                        destination: routeFactory.destination(
                                            for: result.destination
                                        )
                                    ) {
                                        SearchCardView(result: result)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private var loadingMoreContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading more sources...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var emptyContent: some View {
        statusContent(
            systemImage: "doc.text.magnifyingglass",
            message: "No results found."
        )
    }

    @ViewBuilder
    private var partialFailureContent: some View {
        if viewModel.pluginFailures.isEmpty {
            statusContent(
                systemImage: "exclamationmark.triangle",
                message: "Some sources could not be searched."
            )
        } else {
            pluginFailureRows
        }
    }

    @ViewBuilder
    private var failureContent: some View {
        if viewModel.pluginFailures.isEmpty {
            statusContent(
                systemImage: "exclamationmark.triangle",
                message: "Search could not be completed."
            )
        } else {
            pluginFailureRows
        }
    }

    private var pluginFailureRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(viewModel.pluginFailures) { failure in
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure.pluginName, systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                    if failure.canOpenSettings {
                        Button("Open Settings") {
                            settingsPlugin = SettingsPlugin(id: failure.pluginID)
                        }
                    }
                    if failure.canSignIn, let target = signInTarget(failure.pluginID) {
                        Button("Sign In") {
                            signInPlugin = target
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private var cancelledContent: some View {
        statusContent(
            systemImage: "xmark.circle",
            message: "Search cancelled."
        )
    }

    private func statusContent(systemImage: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 50)
    }

    private func sectionHeader(pluginName: String) -> some View {
        HStack {
            Text(pluginName)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Spacer()

            if viewModel.isPluginActive(named: pluginName) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
    }
}
