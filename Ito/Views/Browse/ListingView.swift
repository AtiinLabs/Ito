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
            failureView(message: "Loading was cancelled.")
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
        List {
            ForEach(viewModel.entries, id: \.catalogIdentity) { entry in
                entryRow(entry)
                    .onAppear {
                        loadMoreIfNeeded(
                            lastIdentity: viewModel.entries.last?.catalogIdentity,
                            identity: entry.catalogIdentity
                        )
                    }
            }

            paginationFooter
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func entryRow(_ entry: MediaEntry) -> some View {
        switch entry {
        case .manga(let manga):
            MediaRowView(media: manga) {
                routeFactory.destination(for: viewModel.destination(for: entry))
            }
        case .anime(let anime):
            MediaRowView(media: anime) {
                routeFactory.destination(for: viewModel.destination(for: entry))
            }
        case .novel(let novel):
            MediaRowView(media: novel) {
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
