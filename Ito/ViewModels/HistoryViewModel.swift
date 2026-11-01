import Combine
import Foundation
import ito_runner

/// One series in history: its most recent chapters, one per chapter, newest first. A series read
/// on several sources and linked to the same tracker entry shows once, with every source's
/// chapters.
struct HistorySeries: Identifiable, Equatable {
    /// The source read most recently first, then the same series on other sources.
    let members: [HistorySeriesKey]
    let chapters: [HistoryEntry]

    var key: HistorySeriesKey { members[0] }
    var id: HistorySeriesKey { key }
    var latest: HistoryEntry { chapters[0] }
    var title: String { latest.record.title }
    var coverURL: String? { latest.record.coverUrl }
    /// Chapters before the most recent one.
    var earlierChapters: ArraySlice<HistoryEntry> { chapters.dropFirst() }
    var isOnSeveralSources: Bool { members.count > 1 }
}

/// The series last read on one day, newest first.
struct HistoryDaySection: Identifiable, Equatable {
    let day: Date
    let title: String
    let series: [HistorySeries]

    var id: Date { day }
}

enum HistoryKindFilter: CaseIterable, Equatable {
    case all
    case manga
    case novel
    case anime

    var localizedTitle: String {
        switch self {
        case .all: String(localized: "All", comment: "History filter: every kind of media")
        case .manga: String(localized: "Manga", comment: "History filter")
        case .novel: String(localized: "Novels", comment: "History filter")
        case .anime: String(localized: "Anime", comment: "History filter")
        }
    }

    func includes(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: true
        case .manga: kind == .manga
        case .novel: kind == .novel
        case .anime: kind == .anime
        }
    }
}

enum HistoryRemoval: Hashable {
    case chapter(HistorySeriesKey, chapterKey: String)
    /// A series and the same series on other sources.
    case series([HistorySeriesKey])
}

@MainActor
final class HistoryViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing has been read or watched.
        case empty
        /// History exists but the search or filter matches none of it.
        case noResults
        case content
    }

    @Published private(set) var history: [HistoryEntry] {
        didSet { rebuild() }
    }
    private var trackerLinks: [MediaIdentity: [String: String]] = [:] {
        didSet { rebuild() }
    }
    @Published var searchText = "" {
        didSet { rebuild() }
    }
    @Published var kindFilter: HistoryKindFilter = .all {
        didSet { rebuild() }
    }
    @Published private(set) var sections: [HistoryDaySection] = []
    @Published private(set) var pendingRemovals = Set<HistoryRemoval>()
    @Published private(set) var isClearing = false
    @Published private(set) var isClearConfirmationPresented = false
    @Published private(set) var failure: CategoryHistoryMessage?

    private let historyService: any HistoryServing
    private let sourceNames: any HistorySourceNaming
    private let progress: any HistoryProgressReading
    private let libraryLookup: any HistoryLibraryLookup
    private let messagePresenter: any CategoryHistoryMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private let calendar: Calendar
    private let now: () -> Date
    private var removalOperationIDs: [HistoryRemoval: UUID] = [:]
    private var clearOperationID: UUID?
    private var cancellables = Set<AnyCancellable>()

    init(
        historyService: any HistoryServing,
        sourceNames: any HistorySourceNaming,
        progress: any HistoryProgressReading,
        libraryLookup: any HistoryLibraryLookup,
        links: any HistorySeriesLinking,
        messagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.historyService = historyService
        self.sourceNames = sourceNames
        self.progress = progress
        self.libraryLookup = libraryLookup
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
        self.calendar = calendar
        self.now = now
        history = historyService.historySnapshot
        rebuild()
        historyService.historySnapshotPublisher
            .sink { [weak self] history in
                self?.history = history
            }
            .store(in: &cancellables)
        links.trackerLinksPublisher
            .sink { [weak self] links in
                self?.trackerLinks = links
            }
            .store(in: &cancellables)
        progress.progressWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var phase: Phase {
        if history.isEmpty { return .empty }
        return sections.isEmpty ? .noResults : .content
    }

    var isClearVisible: Bool {
        !history.isEmpty
    }

    /// The kinds of media in history; the filter is offered only when there is more than one.
    var availableKindFilters: [HistoryKindFilter] {
        let kinds = Set(history.map(\.record.mediaKind))
        guard kinds.count > 1 else { return [] }
        return HistoryKindFilter.allCases.filter { filter in
            filter == .all || kinds.contains { filter.includes($0) }
        }
    }

    /// Recomputes day titles, such as "Today", that depend on the current date.
    func refreshDates() {
        rebuild()
    }

    // MARK: - Row content

    /// The installed source's name, or a note that it is no longer installed.
    func sourceName(for entry: HistoryEntry) -> String {
        sourceName(pluginID: entry.record.pluginId)
    }

    /// The other sources a merged series was also read on.
    func otherSourceNames(for series: HistorySeries) -> [String] {
        var names: [String] = []
        for member in series.members.dropFirst() {
            let name = sourceName(pluginID: member.pluginId)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func sourceName(pluginID: String) -> String {
        sourceNames.displayName(for: pluginID)
            ?? String(localized: "Source not installed", comment: "History: the source a series was read on was removed")
    }

    func chapterLabel(for entry: HistoryEntry) -> String {
        Self.chapterLabel(for: entry.record)
    }

    /// The scanlation group, or for an episode its language.
    func groupName(for entry: HistoryEntry) -> String? {
        entry.record.scanlator
    }

    func isFinished(_ entry: HistoryEntry) -> Bool {
        progress.isFinished(
            entry.seriesKey,
            chapterKey: entry.record.chapterKey,
            chapterNumber: entry.record.chapterNumber.map(Float.init)
        )
    }

    /// Where an unfinished chapter was left: a page, elapsed time, or percentage of loaded text.
    func positionLabel(for entry: HistoryEntry) -> String? {
        guard !isFinished(entry),
              let position = progress.savedPosition(entry.seriesKey, chapterKey: entry.record.chapterKey),
              position.isFinite, position >= 0 else { return nil }
        switch entry.record.format {
        case .pages:
            guard position >= 1,
                  let index = Int(exactly: position.rounded(.down)),
                  index < Int.max else { return nil }
            let page = index + 1
            return String(localized: "Page \(page)", comment: "History: the page a chapter was left on")
        case .video:
            guard position >= 1 else { return nil }
            guard let time = Self.playbackTime(seconds: position) else { return nil }
            return String(localized: "Stopped at \(time)", comment: "History: where an episode was left, such as 12:34")
        case .text:
            guard let total = entry.record.textLength, total > 0 else { return nil }
            let percent = Int((min(position, Double(total)) * 100 / Double(total)).rounded(.down))
            return String(localized: "\(percent)%", comment: "History: percentage of a novel chapter read")
        case nil:
            return nil
        }
    }

    private static func playbackTime(seconds: Double) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: seconds.rounded(.down))
    }

    /// What opening the series shows; nil only if it cannot be prepared.
    func libraryItem(for series: HistorySeries) -> LibraryItem? {
        libraryItem(for: series.latest)
    }

    /// The series a chapter was read in, on the source it was read on.
    func libraryItem(for entry: HistoryEntry) -> LibraryItem? {
        libraryLookup.libraryItem(for: entry.record)
    }

    /// A chapter label from a stored row. Rows written before chapter numbers were stored may
    /// hold the chapter key as the title when the chapter had none; such keys are not shown.
    static func chapterLabel(for record: ReadingHistoryRecord) -> String {
        let title = record.chapterTitle.flatMap { title -> String? in
            if title.isEmpty { return nil }
            if title == record.chapterKey, !title.contains(" ") { return nil }
            return title
        }
        let number = record.chapterNumber.map(Float.init)
        switch record.mediaKind {
        case .anime:
            if let title { return title }
            if let number {
                return String(localized: "Episode \(number.formatted())", comment: "History: an episode without a title")
            }
            return String(localized: "Unknown Episode")
        case .manga, .novel:
            if let volume = record.volume, let title {
                return String(
                    localized: "Vol. \(Float(volume).formatted()) · \(title)",
                    comment: "History: volume and chapter title"
                )
            }
            if title == nil, let volume = record.volume, let number {
                return String(
                    localized: "Vol. \(Float(volume).formatted()) Ch. \(number.formatted())",
                    comment: "History: a chapter without a title, by volume and chapter number"
                )
            }
            return ReaderChapterTitle.text(title: title, number: number)
        }
    }

    // MARK: - Removal

    func requestClear() {
        guard !history.isEmpty, !isClearing else { return }
        isClearConfirmationPresented = true
    }

    func cancelClear() {
        isClearConfirmationPresented = false
    }

    func confirmClear() async {
        isClearConfirmationPresented = false
        await clearHistory()
    }

    func removeChapter(_ entry: HistoryEntry) async {
        await remove(.chapter(entry.seriesKey, chapterKey: entry.record.chapterKey))
    }

    func removeSeries(_ series: HistorySeries) async {
        await remove(.series(series.members))
    }

    func isRemoving(_ removal: HistoryRemoval) -> Bool {
        pendingRemovals.contains(removal)
    }

    private func remove(_ removal: HistoryRemoval) async {
        guard removalOperationIDs[removal] == nil, isInHistory(removal) else { return }
        let operationID = UUID()
        removalOperationIDs[removal] = operationID
        pendingRemovals.insert(removal)
        failure = nil
        logStarted(.historyDelete, operationID: operationID)
        do {
            switch removal {
            case .chapter(let series, let chapterKey):
                try await historyService.removeChapter(series, chapterKey: chapterKey)
            case .series(let members):
                try await historyService.removeSeries(members)
            }
            logFinished(.historyDelete, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.historyDelete, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(.historyDelete, operationID: operationID, outcome: .failed(.persistence))
            if removalOperationIDs[removal] == operationID {
                publishFailure(.historyDeleteFailed)
            }
        }
        if removalOperationIDs[removal] == operationID {
            removalOperationIDs[removal] = nil
            pendingRemovals.remove(removal)
        }
    }

    private func isInHistory(_ removal: HistoryRemoval) -> Bool {
        switch removal {
        case .chapter(let series, let chapterKey):
            return history.contains { $0.seriesKey == series && $0.record.chapterKey == chapterKey }
        case .series(let members):
            return history.contains { members.contains($0.seriesKey) }
        }
    }

    func clearHistory() async {
        guard clearOperationID == nil, !history.isEmpty else { return }
        let operationID = UUID()
        clearOperationID = operationID
        isClearing = true
        failure = nil
        logStarted(.historyClear, operationID: operationID)
        do {
            try await historyService.clearHistory()
            logFinished(.historyClear, operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            logFinished(.historyClear, operationID: operationID, outcome: .cancelled)
        } catch {
            logFinished(.historyClear, operationID: operationID, outcome: .failed(.persistence))
            if clearOperationID == operationID {
                publishFailure(.historyClearFailed)
            }
        }
        if clearOperationID == operationID {
            clearOperationID = nil
            isClearing = false
        }
    }

    func dismissFailure() {
        failure = nil
    }

    // MARK: - Grouping

    private func rebuild() {
        // A filter whose menu is no longer offered could otherwise hide everything with no way
        // back, such as after removing the last novel while Novels is selected.
        if kindFilter != .all, !availableKindFilters.contains(kindFilter) {
            kindFilter = .all
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let series = Self.series(from: history, links: trackerLinks).filter { series in
            kindFilter.includes(series.key.mediaKind)
                && (query.isEmpty || series.chapters.contains { $0.record.title.localizedCaseInsensitiveContains(query) })
        }
        var sections: [HistoryDaySection] = []
        for item in series {
            let day = calendar.startOfDay(for: item.latest.record.readAt)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = HistoryDaySection(day: day, title: last.title, series: last.series + [item])
            } else {
                sections.append(HistoryDaySection(day: day, title: dayTitle(for: day), series: [item]))
            }
        }
        self.sections = sections
    }

    /// Groups newest-first rows by series, keeping each chapter's newest row. Series of one kind
    /// linked to the same tracker entry are one series only when every shared provider agrees.
    /// Compatible groups merge newest-first; series are ordered by their most recent chapter.
    static func series(
        from history: [HistoryEntry],
        links: [MediaIdentity: [String: String]] = [:]
    ) -> [HistorySeries] {
        var keyIndex: [HistorySeriesKey: Int] = [:]
        var keys: [HistorySeriesKey] = []
        for entry in history where keyIndex[entry.seriesKey] == nil {
            keyIndex[entry.seriesKey] = keys.count
            keys.append(entry.seriesKey)
        }

        // Each group's root is its newest series, so groups keep the order of their newest read.
        var parent = Array(keys.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var componentLinks = keys.map { links[$0.mediaIdentity] ?? [:] }
        // Conflicting groups can own the same token; keep each available for later matches.
        var owners: [[String]: Set<Int>] = [:]
        for (index, key) in keys.enumerated() {
            let seriesLinks = componentLinks[index]
            var candidates = Set<Int>()
            for (provider, remoteID) in seriesLinks {
                let token = [key.mediaKind.rawValue, provider, remoteID]
                // Collapse stale member indices so a long positive chain stays linear.
                var tokenOwners = Set<Int>()
                for owner in owners[token] ?? [] {
                    tokenOwners.insert(root(owner))
                }
                candidates.formUnion(tokenOwners)
                tokenOwners.insert(index)
                owners[token] = tokenOwners
            }
            // Dictionary iteration must not decide which side of a contradictory bridge wins.
            for candidate in candidates.sorted() {
                let (lhs, rhs) = (root(index), root(candidate))
                guard lhs != rhs,
                      componentLinks[lhs].allSatisfy({ provider, remoteID in
                          componentLinks[rhs][provider].map { $0 == remoteID } ?? true
                      }) else { continue }
                let (newest, oldest) = (min(lhs, rhs), max(lhs, rhs))
                parent[oldest] = newest
                for (provider, remoteID) in componentLinks[oldest] {
                    componentLinks[newest][provider] = remoteID
                }
                componentLinks[oldest].removeAll()
            }
        }

        var order: [Int] = []
        var members: [Int: [HistorySeriesKey]] = [:]
        for (index, key) in keys.enumerated() {
            let group = root(index)
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(key)
        }
        var chapters: [Int: [HistoryEntry]] = [:]
        var seenChapters = Set<[String]>()
        for entry in history {
            let key = entry.seriesKey
            guard let index = keyIndex[key],
                  seenChapters.insert([key.pluginId, key.mediaKind.rawValue, key.mediaKey, entry.record.chapterKey]).inserted
            else { continue }
            chapters[root(index), default: []].append(entry)
        }
        return order.map { HistorySeries(members: members[$0] ?? [], chapters: chapters[$0] ?? []) }
    }

    private func dayTitle(for day: Date) -> String {
        let today = calendar.startOfDay(for: now())
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch daysAgo {
        case 0:
            return String(localized: "Today", comment: "History section")
        case 1:
            return String(localized: "Yesterday", comment: "History section")
        case 2..<7:
            return day.formatted(dayFormat.weekday(.wide))
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
            let style = dayFormat.month(.wide).day()
            return sameYear ? day.formatted(style) : day.formatted(style.year())
        }
    }

    private var dayFormat: Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }

    // MARK: - Messages and logging

    private func publishFailure(_ message: CategoryHistoryMessage) {
        failure = message
        messagePresenter.present(message)
    }

    private func logStarted(_ kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(.started(feature: .history, kind: kind, operationID: operationID))
    }

    private func logFinished(
        _ kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .history,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
