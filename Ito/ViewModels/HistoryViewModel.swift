import Combine
import Foundation
import ito_runner

/// One series in history: its most recent chapters, one per chapter, newest first.
struct HistorySeries: Identifiable, Equatable {
    let key: HistorySeriesKey
    let chapters: [HistoryEntry]

    var id: HistorySeriesKey { key }
    var latest: HistoryEntry { chapters[0] }
    var title: String { latest.record.title }
    var coverURL: String? { latest.record.coverUrl }
    /// Chapters before the most recent one.
    var earlierChapters: ArraySlice<HistoryEntry> { chapters.dropFirst() }
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
    case series(HistorySeriesKey)
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
        sourceNames.displayName(for: entry.record.pluginId)
            ?? String(localized: "Source not installed", comment: "History: the source a series was read on was removed")
    }

    func chapterLabel(for entry: HistoryEntry) -> String {
        Self.chapterLabel(for: entry.record)
    }

    func isFinished(_ entry: HistoryEntry) -> Bool {
        progress.isFinished(
            entry.seriesKey,
            chapterKey: entry.record.chapterKey,
            chapterNumber: entry.record.chapterNumber.map(Float.init)
        )
    }

    /// What opening the series shows; nil only if it cannot be prepared.
    func libraryItem(for series: HistorySeries) -> LibraryItem? {
        libraryLookup.libraryItem(for: series.latest.record)
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
        await remove(.series(series.key))
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
            case .series(let series):
                try await historyService.removeSeries(series)
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
        case .series(let series):
            return history.contains { $0.seriesKey == series }
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
        let series = Self.series(from: history).filter { series in
            kindFilter.includes(series.key.mediaKind)
                && (query.isEmpty || series.title.localizedCaseInsensitiveContains(query))
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

    /// Groups newest-first rows by series, keeping each chapter's newest row. Series are ordered
    /// by their most recent chapter.
    static func series(from history: [HistoryEntry]) -> [HistorySeries] {
        var order: [HistorySeriesKey] = []
        var chapters: [HistorySeriesKey: [HistoryEntry]] = [:]
        var seenChapters = Set<[String]>()
        for entry in history {
            let key = entry.seriesKey
            guard seenChapters.insert([key.pluginId, key.mediaKind.rawValue, key.mediaKey, entry.record.chapterKey]).inserted else {
                continue
            }
            if chapters[key] == nil { order.append(key) }
            chapters[key, default: []].append(entry)
        }
        return order.map { HistorySeries(key: $0, chapters: chapters[$0] ?? []) }
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
