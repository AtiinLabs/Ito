import SwiftUI

/// What the Library shows when the search or the saved-chapter filter matches no series.
struct LibraryNoResultsView: View {
    let searchText: String
    /// Whether a saved-chapter filter is active, so the empty state names the search and the filter together.
    let isFiltered: Bool
    /// The entire-series filter is still judging its series: progress is shown instead of a verdict.
    let isAwaitingOfflineProofs: Bool

    var body: some View {
        Group {
            if isAwaitingOfflineProofs {
                ProgressView()
            } else if searchText.isEmpty {
                filterResult
            } else if isFiltered {
                searchAndFilterResult
            } else {
                searchResult
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var searchResult: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Nothing in your library matches\n\"\(searchText)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var searchAndFilterResult: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.title3)
                .fontWeight(.semibold)
            Text(
                "No series match this search and filter.",
                comment: "Library: shown when the search text and the saved-chapter filter together match no series."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private var filterResult: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(
                "No series match this filter.",
                comment: "Library: shown when the saved-chapter filter matches no series and the search is empty."
            )
            .font(.title3)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
        }
    }
}
