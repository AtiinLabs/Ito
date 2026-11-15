import NukeUI
import SwiftUI
import ito_runner

/// A series to open from History, with what to open once its screen has loaded.
private struct HistoryRoute: Identifiable {
    let id = UUID()
    let item: LibraryItem
    let openIntent: MediaDetailOpenIntent?
}

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    let viewFactory: AppViewFactory
    /// The series opened last. It stays set while the screen pops back so the outgoing screen
    /// keeps its content; `isRouteActive` drives the navigation.
    @State private var route: HistoryRoute?
    @State private var isRouteActive = false
    @State private var expandedSeries = Set<HistorySeriesKey>()

    init(viewModel: @autoclosure @escaping () -> HistoryViewModel, viewFactory: AppViewFactory) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.viewFactory = viewFactory
    }

    var body: some View {
        content
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, prompt: Text("Search History"))
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !viewModel.availableKindFilters.isEmpty {
                        filterMenu
                    }
                    if viewModel.isClearVisible {
                        Button(role: .destructive) {
                            viewModel.requestClear()
                        } label: {
                            Text("Clear", comment: "Button: clear all history entries")
                        }
                        .disabled(viewModel.isClearing)
                    }
                }
            }
            .background(routeLink)
            .onAppear { viewModel.refreshDates() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                viewModel.refreshDates()
            }
            .confirmationDialog(
                "Clear All History?",
                isPresented: clearConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    Task { await viewModel.confirmClear() }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelClear()
                }
            } message: {
                Text("This removes all reading and watch history.")
            }
            .alert(
                viewModel.failure?.alertTitle ?? String(localized: "History Change Failed"),
                isPresented: failureBinding
            ) {
                Button("OK", role: .cancel) {
                    viewModel.dismissFailure()
                }
            } message: {
                Text(viewModel.failure?.alertMessage ?? String(localized: "Please try again."))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .empty:
            message(
                systemImage: "clock.arrow.circlepath",
                title: Text("No History"),
                detail: Text("Items you read or watch\nwill appear here.")
            )
        case .noResults:
            message(
                systemImage: "magnifyingglass",
                title: Text("No Results"),
                detail: Text("Nothing in your history matches this search or filter.")
            )
        case .content:
            List {
                ForEach(viewModel.sections) { section in
                    Section(header: Text(section.title)) {
                        ForEach(section.series) { series in
                            seriesRows(series)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func seriesRows(_ series: HistorySeries) -> some View {
        HistorySeriesRow(
            series: series,
            chapterLabel: viewModel.chapterLabel(for: series.latest),
            isFinished: viewModel.isFinished(series.latest),
            position: viewModel.positionLabel(for: series.latest),
            sourceLine: Self.joined([viewModel.sourceName(for: series.latest), viewModel.groupName(for: series.latest)]),
            otherSources: viewModel.otherSourceNames(for: series),
            open: { open(viewModel.libraryItem(for: series), intent: nil) },
            resume: { resume(series) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await viewModel.removeSeries(series) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(viewModel.isRemoving(.series(series.members)))
        }
        .contextMenu {
            Button {
                resume(series)
            } label: {
                Label("Continue", systemImage: series.key.mediaKind == .anime ? "play.fill" : "book.fill")
            }
            Button {
                open(viewModel.libraryItem(for: series), intent: nil)
            } label: {
                Label("Open Series", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                Task { await viewModel.removeSeries(series) }
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }

        if !series.earlierChapters.isEmpty {
            earlierChaptersToggle(series)
            if expandedSeries.contains(series.key) {
                ForEach(series.earlierChapters) { entry in
                    HistoryChapterRow(
                        label: viewModel.chapterLabel(for: entry),
                        detail: Self.joined([
                            series.isOnSeveralSources ? viewModel.sourceName(for: entry) : nil,
                            viewModel.groupName(for: entry)
                        ]),
                        readAt: entry.record.readAt,
                        isFinished: viewModel.isFinished(entry),
                        isEpisode: entry.record.mediaKind == .anime,
                        open: { openChapter(entry) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.removeChapter(entry) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .disabled(viewModel.isRemoving(.chapter(entry.seriesKey, chapterKey: entry.record.chapterKey)))
                    }
                }
            }
        }
    }

    private func earlierChaptersToggle(_ series: HistorySeries) -> some View {
        let isExpanded = expandedSeries.contains(series.key)
        let count = series.earlierChapters.count
        return Button {
            if isExpanded {
                expandedSeries.remove(series.key)
            } else {
                expandedSeries.insert(series.key)
            }
        } label: {
            HStack(spacing: 6) {
                if isExpanded {
                    Text("Hide Earlier", comment: "History: collapse a series' earlier chapters")
                } else if series.key.mediaKind == .anime {
                    Text("\(count) Earlier Episodes", comment: "History: expand a series' earlier episodes")
                } else {
                    Text("\(count) Earlier Chapters", comment: "History: expand a series' earlier chapters")
                }
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, HistorySeriesRow.textInset)
        }
        .buttonStyle(.borderless)
    }

    /// Opens a series where it was left off, preferring the group read last.
    private func resume(_ series: HistorySeries) {
        open(
            viewModel.libraryItem(for: series),
            intent: .resume(
                preferredScanlator: series.latest.record.scanlator,
                preferredScanlatorID: series.latest.record.scanlatorID
            )
        )
    }

    /// Opens one chapter on the source it was read on.
    private func openChapter(_ entry: HistoryEntry) {
        let record = entry.record
        let reference = MediaDetailChapterReference(
            key: record.chapterKey,
            number: record.chapterNumber.map(Float.init),
            volume: record.volume.map(Float.init),
            scanlator: record.scanlator,
            scanlatorID: record.scanlatorID
        )
        open(viewModel.libraryItem(for: entry), intent: .chapter(reference))
    }

    private func open(_ item: LibraryItem?, intent: MediaDetailOpenIntent?) {
        guard let item else { return }
        route = HistoryRoute(item: item, openIntent: intent)
        isRouteActive = true
    }

    /// Joins the parts that are present with " · ".
    private static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private var routeLink: some View {
        NavigationLink(destination: routeDestination, isActive: $isRouteActive) {
            EmptyView()
        }
        .hidden()
    }

    @ViewBuilder
    private var routeDestination: some View {
        if let route {
            viewFactory.makeDeferredPluginView(item: route.item, openIntent: route.openIntent)
                .id(route.id)
        }
    }

    private func message(systemImage: String, title: Text, detail: Text) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            title
                .font(.title3)
                .fontWeight(.semibold)
            detail
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var filterMenu: some View {
        Menu {
            Picker(selection: $viewModel.kindFilter) {
                ForEach(viewModel.availableKindFilters, id: \.self) { filter in
                    Text(filter.localizedTitle).tag(filter)
                }
            } label: {
                Text("Show", comment: "History: which kinds of media to list")
            }
        } label: {
            Image(systemName: viewModel.kindFilter == .all
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .accessibilityLabel(Text("Filter", comment: "History: filter button"))
        }
    }

    private var clearConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isClearConfirmationPresented },
            set: { if !$0 { viewModel.cancelClear() } }
        )
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure != nil },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }
}

/// A series' most recent chapter: tapping it opens the series, Continue resumes reading.
private struct HistorySeriesRow: View {
    static let coverSize = CGSize(width: 50, height: 75)
    static let textInset: CGFloat = coverSize.width + 12

    let series: HistorySeries
    let chapterLabel: String
    let isFinished: Bool
    /// Where an unfinished chapter was left, such as "Page 13".
    let position: String?
    /// The source, and the group when known.
    let sourceLine: String?
    /// Other sources the same series was read on.
    let otherSources: [String]
    let open: () -> Void
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    cover
                    VStack(alignment: .leading, spacing: 3) {
                        Text(series.title)
                            .font(.headline)
                            .lineLimit(2)
                        HistoryChapterLabel(label: chapterLabel, isFinished: isFinished, isEpisode: series.key.mediaKind == .anime)
                            .font(.subheadline)
                        HStack(spacing: 4) {
                            HistoryRelativeTime(date: series.latest.record.readAt)
                            if let position {
                                Text(verbatim: "·")
                                    .accessibilityHidden(true)
                                Text(position)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: series.key.mediaKind.historySymbol)
                                .accessibilityLabel(series.key.mediaKind.historyName)
                            if let sourceLine {
                                Text(sourceLine)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if !otherSources.isEmpty {
                            Text(
                                "Also read on \(otherSources.formatted(.list(type: .and)))",
                                comment: "History: other sources the same series was read on"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the series", comment: "History: accessibility hint of a series row"))

            Button(action: resume) {
                Text("Continue", comment: "History: resume reading or watching a series")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("Continue \(series.title)", comment: "History: resume button, with the series title"))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var cover: some View {
        if let coverURL = series.coverURL, let url = URL(string: coverURL) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else if state.error != nil {
                    Color.itoCardBackground
                        .overlay(Image(systemName: "exclamationmark.triangle").foregroundStyle(.tertiary))
                } else {
                    Color.itoCardBackground
                }
            }
            .frame(width: Self.coverSize.width, height: Self.coverSize.height)
            .cornerRadius(6)
            .clipped()
            .accessibilityHidden(true)
        } else {
            Color.itoCardBackground
                .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                .cornerRadius(6)
                .overlay(Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary))
                .accessibilityHidden(true)
        }
    }
}

/// An earlier chapter of a series; tapping it opens that chapter.
private struct HistoryChapterRow: View {
    let label: String
    /// The group, and the source when the series was read on several.
    let detail: String?
    let readAt: Date
    let isFinished: Bool
    let isEpisode: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HistoryChapterLabel(label: label, isFinished: isFinished, isEpisode: isEpisode)
                        .font(.subheadline)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HistoryRelativeTime(date: readAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, HistorySeriesRow.textInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            isEpisode
                ? Text("Opens this episode", comment: "History: accessibility hint of an earlier episode row")
                : Text("Opens this chapter", comment: "History: accessibility hint of an earlier chapter row")
        )
    }
}

private struct HistoryChapterLabel: View {
    let label: String
    let isFinished: Bool
    let isEpisode: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(
                        isEpisode
                            ? Text("Watched to the End", comment: "History: the episode was watched to the end")
                            : Text("Read to the End", comment: "History: the chapter was read to the end")
                    )
            }
            Text(label)
                .lineLimit(1)
        }
    }
}

/// "5 minutes ago", kept current while the screen is open.
private struct HistoryRelativeTime: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.formatter.localizedString(for: date, relativeTo: context.date))
        }
    }
}

private extension MediaKind {
    var historySymbol: String {
        switch self {
        case .manga: "book"
        case .novel: "text.book.closed"
        case .anime: "play.tv"
        }
    }

    var historyName: Text {
        switch self {
        case .manga: Text("Manga", comment: "History: kind of media")
        case .novel: Text("Novel", comment: "History: kind of media")
        case .anime: Text("Anime", comment: "History: kind of media")
        }
    }
}
