import SwiftUI
import ito_runner

struct ListingView: View {
    @StateObject private var viewModel: ListingViewModel
    private let routeFactory: SearchRouteFactory

    init(viewModel: ListingViewModel, routeFactory: SearchRouteFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.routeFactory = routeFactory
    }

    var body: some View {
        listingContent
            .environment(\.imageSourceID, viewModel.identity.pluginID)
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadInitialIfNeeded()
            }
            .onDisappear {
                viewModel.cancel()
            }
    }

    @ViewBuilder
    private var listingContent: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView("Loading \(viewModel.title)...")
        case .failure(let error):
            failureView(message: error)
        case .cancelled:
            failureView(message: String(localized: "Loading was cancelled."))
        case .empty:
            VStack(spacing: 12) {
                Text("No results found.")
                    .foregroundStyle(.secondary)
                if viewModel.hasNextPage, viewModel.paginationState == .idle {
                    Button("Load Next Page") {
                        Task { await viewModel.loadMore() }
                    }
                    .buttonStyle(.bordered)
                }
                paginationFooter
            }
        case .content:
            resultsList
        }
    }

    private var resultsList: some View {
        GeometryReader { proxy in
            resultsGrid(width: proxy.size.width)
        }
    }

    /// Columns follow the width this list is given; the grid is inset 16 pt on each side.
    private func resultsGrid(width: CGFloat) -> some View {
        let columns = AdaptiveGridMetrics.columns(forWidth: width - 32, spacing: 12)
        let cardWidth = AdaptiveGridMetrics.cellWidth(forWidth: width - 32, columns: columns.count, spacing: 12)
        return ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.entries, id: \.catalogIdentity) { entry in
                        entryCard(entry, width: cardWidth)
                            .onAppear {
                                loadMoreIfNeeded(
                                    lastIdentity: viewModel.entries.last?.catalogIdentity,
                                    identity: entry.catalogIdentity
                                )
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                paginationFooter
            }
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: MediaEntry, width: CGFloat) -> some View {
        switch entry {
        case .manga(let manga):
            MediaCardView(media: manga, width: width) {
                routeFactory.destination(for: viewModel.destination(for: entry))
            }
        case .anime(let anime):
            MediaCardView(media: anime, width: width) {
                routeFactory.destination(for: viewModel.destination(for: entry))
            }
        case .novel(let novel):
            MediaCardView(media: novel, width: width) {
                routeFactory.destination(for: viewModel.destination(for: entry))
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        switch viewModel.paginationState {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding()
        case .failure(_, let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Retry") {
                    Task { await viewModel.retry() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding()
        case .continuationRequired:
            Button("Load Next Page") {
                Task { await viewModel.loadMore() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .padding()
        case .idle, .exhausted:
            EmptyView()
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).foregroundColor(.red)
            Button("Retry") {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func loadMoreIfNeeded(lastIdentity: MediaEntryIdentity?, identity: MediaEntryIdentity) {
        guard identity == lastIdentity else { return }
        Task { await viewModel.loadMore() }
    }
}
