import Combine
import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

private enum IndicatorFailure: Error { case requested }

@MainActor
private final class RemovalLog {
    var events: [String] = []
}

@MainActor
private final class EmissionCount {
    var value = 0
}

@MainActor
private final class IndicatorRoot: LibraryRootServing {
    private let subject: CurrentValueSubject<LibraryRootSnapshot, Never>
    private let log: RemovalLog
    var failing: Set<String> = []

    init(items: [Ito.LibraryItem], log: RemovalLog) {
        subject = CurrentValueSubject(LibraryRootSnapshot(items: items, categories: [], links: [], isLoading: false))
        self.log = log
    }

    var rootSnapshot: LibraryRootSnapshot { subject.value }
    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> { subject.eraseToAnyPublisher() }
    var itemIDs: [String] { subject.value.items.map(\.id) }

    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws {
        log.events.append("library:\(itemID)")
        if failing.contains(itemID) { throw IndicatorFailure.requested }
        let current = subject.value
        subject.send(LibraryRootSnapshot(
            items: current.items.filter { $0.id != itemID },
            categories: current.categories, links: current.links, isLoading: false
        ))
    }
}

@MainActor
private final class ScriptedDownloads: LibraryDownloadServing {
    private let subject: CurrentValueSubject<LibraryDownloadSummary, Never>
    private let log: RemovalLog
    var failing: Set<MediaIdentity> = []

    init(summary: LibraryDownloadSummary, log: RemovalLog) {
        subject = CurrentValueSubject(summary)
        self.log = log
    }

    var downloadSummary: LibraryDownloadSummary { subject.value }
    var downloadSummaryPublisher: AnyPublisher<LibraryDownloadSummary, Never> { subject.eraseToAnyPublisher() }
    func publish(_ summary: LibraryDownloadSummary) { subject.send(summary) }
    var isInventoryAvailable: Bool { true }

    func deleteDownloads(of media: MediaIdentity) async throws {
        log.events.append("downloads:\(media.canonicalMediaId)")
        if failing.contains(media) { throw IndicatorFailure.requested }
    }
}

@MainActor
private final class IndicatorMessages: LibraryMessagePresenting {
    private(set) var messages: [LibraryMessage] = []
    func present(_ message: LibraryMessage) { messages.append(message) }
}

@MainActor
private struct Harness {
    let viewModel: LibraryViewModel
    let root: IndicatorRoot
    let messages: IndicatorMessages
    let log: RemovalLog

    init(
        items: [Ito.LibraryItem],
        log: RemovalLog = RemovalLog(),
        downloads: (any LibraryDownloadServing)? = nil
    ) {
        let root = IndicatorRoot(items: items, log: log)
        let base = PreparedLibraryDependencies.unavailable()
        let dependencies = PreparedLibraryDependencies(
            library: root,
            layout: base.layout,
            updates: base.updates,
            export: base.export,
            discord: base.discord,
            plugins: base.plugins,
            installer: base.installer,
            payloadDecoder: base.payloadDecoder,
            downloads: downloads ?? UnavailableLibraryDownloads()
        )
        let messages = IndicatorMessages()
        self.viewModel = LibraryViewModel(
            dependencies: dependencies,
            tabRouter: AppRouter(),
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
        self.root = root
        self.messages = messages
        self.log = log
    }

    /// Requests, then confirms what the dialog presented, and returns when the removal, and its downloads,
    /// are done.
    @discardableResult
    func remove(_ item: Ito.LibraryItem, includingDownloads: Bool) async throws -> LibraryRemovalRequest {
        viewModel.requestRemoval(item)
        let request = try #require(viewModel.pendingRemoval)
        viewModel.confirmRemoval(request, includingDownloads: includingDownloads)
        for await ids in viewModel.$removingItemIDs.values where ids.isEmpty { break }
        return request
    }
}

private func libraryItem(_ id: String, title: String? = nil) -> Ito.LibraryItem {
    Ito.LibraryItem(
        id: id, title: title ?? id, coverUrl: nil, pluginId: "plugin.test",
        isAnime: false, pluginType: .manga, rawPayload: Data(), anilistId: nil
    )
}

private func summary(saved: [String: Int] = [:], held: [String] = []) -> LibraryDownloadSummary {
    let media = { (id: String) in libraryItem(id).mediaIdentity }
    return LibraryDownloadSummary(
        savedCounts: Dictionary(uniqueKeysWithValues: saved.map { (media($0.key), $0.value) }),
        mediaWithDownloads: Set((held + Array(saved.keys)).map(media)),
        chapterStates: [:]
    )
}

private func inventoryCopy(_ key: String) throws -> DownloadedChapterRecord {
    DownloadedChapterRecord(
        pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: key,
        authorityScope: .publicUnscoped, versionId: UUID().uuidString, state: .verified, damageReason: nil,
        contentKind: .images, pageCount: 1, byteCount: 1, manifestFormatVersion: 1,
        manifestSHA256: String(repeating: "a", count: 64),
        chapterSnapshot: try JSONEncoder().encode(Chapter(key: key, chapter: 1)),
        seriesTitle: "Series", sourceEpoch: nil, verifiedAt: Date(timeIntervalSince1970: 0)
    )
}

private func queuedJob(_ key: String) -> DownloadJobRecord {
    DownloadJobRecord(
        id: UUID().uuidString, batchId: "batch", sequence: 0, pluginId: "plugin.test", mediaKind: .manga,
        canonicalMediaId: "series-1", chapterKey: key, authorityScope: .publicUnscoped, chapterSnapshot: Data(),
        seriesTitle: "Series", sourceEpoch: nil, state: .queued, waitingReason: nil, failureReason: nil,
        stagingVersionId: nil, attemptCount: 0, createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
struct LibraryDownloadIndicatorTests {
    // MARK: Card count

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func savedCountsCountOnlyVerifiedEditionsFromOneSummaryOfTheWholeLibrary() async throws {
        let fixture = try DownloadWorkerFixture()
        let store = fixture.store
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "a1", canonicalMediaId: "series-1")
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "a2", canonicalMediaId: "series-1")
        _ = try await fixture.offline.enqueue(store, chapterKey: "a3", canonicalMediaId: "series-1")
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "b1", canonicalMediaId: "series-2")
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(sql: "UPDATE downloadedChapter SET state = 'damaged', damageReason = 'pageMismatch' WHERE canonicalMediaId = 'series-2'")
        }
        _ = try await fixture.offline.enqueue(store, chapterKey: "c1", canonicalMediaId: "series-3")
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())

        var observed = LibraryDownloadSummary.empty
        for await value in fixture.center.downloadSummaryPublisher.values where value.mediaWithDownloads.count == 3 {
            observed = value
            break
        }

        #expect(observed.savedCounts == [libraryItem("series-1").mediaIdentity: 2])
        // A damaged copy and a queued chapter hold something to decide about, but are not saved.
        #expect(observed.mediaWithDownloads == Set(["series-1", "series-2", "series-3"].map { libraryItem($0).mediaIdentity }))
        let harness = Harness(items: ["series-1", "series-2", "series-3", "series-4"].map { libraryItem($0) }, downloads: fixture.center)
        #expect(harness.viewModel.savedCount(for: libraryItem("series-1")) == 2)
        #expect(harness.viewModel.savedCount(for: libraryItem("series-2")) == 0)
        #expect(harness.viewModel.savedCount(for: libraryItem("series-3")) == 0)
        #expect(harness.viewModel.savedCount(for: libraryItem("series-4")) == 0)
    }

    @Test func cardCountTracksTheObservedSummaryAndHidesAtZero() {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let harness = Harness(items: [libraryItem("one"), libraryItem("two")], log: log, downloads: downloads)
        #expect(harness.viewModel.savedCount(for: libraryItem("one")) == 3)
        #expect(harness.viewModel.savedCount(for: libraryItem("two")) == 0)

        downloads.publish(summary(saved: ["one": 1, "two": 7]))
        #expect(harness.viewModel.savedCount(for: libraryItem("one")) == 1)
        #expect(harness.viewModel.savedCount(for: libraryItem("two")) == 7)

        downloads.publish(summary(held: ["one"]))
        #expect(harness.viewModel.savedCount(for: libraryItem("one")) == 0)
    }

    @Test func noCountIsShownWhenTheOfflineStoreIsUnavailable() {
        let harness = Harness(items: [libraryItem("one")])
        #expect(harness.viewModel.savedCount(for: libraryItem("one")) == 0)
        harness.viewModel.requestRemoval(libraryItem("one"))
        #expect(harness.viewModel.pendingRemoval?.hasDownloads == false)
    }

    @Test func theInventoryIsOfferedOnlyWhereItCanBeRead() {
        #expect(!UnavailableLibraryDownloads().isInventoryAvailable)
    }

    @Test func chapterStatesFollowTheInventoryAndQueueAndAVerifiedCopyWinsOverAJob() throws {
        let copies = [try inventoryCopy("a1"), try inventoryCopy("a2")]
        let jobs = [queuedJob("a1"), queuedJob("a3")]
        let states = LibraryDownloadSummary(copies: copies, jobs: jobs)
            .chapterStates(for: libraryItem("series-1").mediaIdentity)

        #expect(states == ["a1": .downloaded, "a2": .downloaded, "a3": .queued])
    }

    // MARK: Dialog variants

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aSeriesWithoutDownloadsKeepsTheSingleRemove() async throws {
        let harness = Harness(items: [libraryItem("one")])
        let request = try await harness.remove(libraryItem("one"), includingDownloads: false)
        #expect(!request.hasDownloads)
        #expect(harness.log.events == ["library:one"])
        #expect(harness.root.itemIDs.isEmpty)
        #expect(harness.messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func askingToDeleteDownloadsOfASeriesWithoutAnyDeletesNothing() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["other": 3]), log: log)
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)

        try await harness.remove(libraryItem("one"), includingDownloads: true)

        #expect(log.events == ["library:one"])
    }

    @Test func aSeriesWithSavedDownloadsOffersBothRemovalsAndCountsTheKeptChapters() throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let harness = Harness(items: [libraryItem("one", title: "Series One")], log: log, downloads: downloads)

        harness.viewModel.requestRemoval(libraryItem("one", title: "Series One"))
        let request = try #require(harness.viewModel.pendingRemoval)
        #expect(request.hasDownloads)
        #expect(request.savedChapterCount == 3)
        #expect(request.message.contains("Series One"))
        #expect(request.message.contains("3"))
        // Offering the choice removes nothing.
        #expect(log.events.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func removeFromLibraryKeepsTheDownloadsOfASeriesThatHasThem() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)

        try await harness.remove(libraryItem("one"), includingDownloads: false)

        #expect(log.events == ["library:one"])
        #expect(harness.messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func removeLibraryAndDownloadsDeletesTheDownloadsAfterTheLibraryRemoval() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)

        try await harness.remove(libraryItem("one"), includingDownloads: true)

        #expect(log.events == ["library:one", "downloads:one"])
        #expect(harness.messages.messages.isEmpty)
    }

    @Test func theDialogMessageTiesTheKeepingToTheRemoveFromLibraryButton() {
        let item = libraryItem("one", title: "Series One")
        let saved = LibraryRemovalRequest(item: item, hasDownloads: true, savedChapterCount: 3)
        #expect(saved.message == "Series One is also removed from your lists. Reading history and progress are kept. Remove from Library keeps its 3 downloaded chapters.")
        let unfinished = LibraryRemovalRequest(item: item, hasDownloads: true, savedChapterCount: 0)
        #expect(unfinished.message == "Series One is also removed from your lists. Reading history and progress are kept. Remove from Library keeps its downloads.")
        let plain = LibraryRemovalRequest(item: item, hasDownloads: false, savedChapterCount: 0)
        #expect(plain.message == "Series One is also removed from your lists. Reading history and progress are kept.")
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func pageProgressDoesNotRepublishTheLibrarySummary() async throws {
        let fixture = try DownloadWorkerFixture()
        let id = try await fixture.offline.enqueue(fixture.store)
        _ = try await fixture.store.beginAttempt(jobID: id)
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        for await value in fixture.center.downloadSummaryPublisher.values where !value.mediaWithDownloads.isEmpty { break }
        let emissions = EmissionCount()
        let token = fixture.center.downloadSummaryPublisher.sink { @MainActor _ in emissions.value += 1 }
        defer { token.cancel() }
        #expect(emissions.value == 1)

        for pages in 1...3 {
            fixture.progress.update(DownloadProgress(jobID: id, completedPages: pages, totalPages: 3, bytes: Int64(pages)))
        }

        #expect(emissions.value == 1)
        #expect(fixture.center.states.values.first?.values.first == .downloading(completed: 3, total: 3))
    }

    @Test func aSeriesWhoseOnlyDownloadsAreDamagedOrQueuedStillOffersTheChoice() throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(held: ["one"]), log: log)
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)

        harness.viewModel.requestRemoval(libraryItem("one"))
        let request = try #require(harness.viewModel.pendingRemoval)
        #expect(request.hasDownloads)
        #expect(request.savedChapterCount == 0)
    }

    // MARK: Ordering and failures

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aLibraryRemovalThatFailsDeletesNoDownloadsAndSaysSo() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)
        harness.root.failing = ["one"]

        try await harness.remove(libraryItem("one"), includingDownloads: true)

        #expect(harness.messages.messages == [.itemRemovalFailed])
        #expect(log.events == ["library:one"])
        #expect(harness.root.itemIDs == ["one"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func downloadsAreNotDeletedUntilTheLibraryRemovalHasCommitted() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        let gated = GatedRoot(items: [libraryItem("one")], log: log)
        let base = PreparedLibraryDependencies.unavailable()
        let viewModel = LibraryViewModel(
            dependencies: PreparedLibraryDependencies(
                library: gated, layout: base.layout, updates: base.updates, export: base.export,
                discord: base.discord, plugins: base.plugins, installer: base.installer,
                payloadDecoder: base.payloadDecoder, downloads: downloads
            ),
            tabRouter: AppRouter(), messagePresenter: IndicatorMessages(), presentationLogger: PresentationEventCaptureSpy()
        )
        viewModel.requestRemoval(libraryItem("one"))
        let request = try #require(viewModel.pendingRemoval)
        viewModel.confirmRemoval(request, includingDownloads: true)

        await gated.removalStarted()
        #expect(log.events == ["library:one"])

        gated.commit()
        for await ids in viewModel.$removingItemIDs.values where ids.isEmpty { break }
        #expect(log.events == ["library:one", "downloads:one"])
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aDownloadDeletionThatFailsLeavesTheLibraryRemovalInPlaceAndSaysSo() async throws {
        let log = RemovalLog()
        let downloads = ScriptedDownloads(summary: summary(saved: ["one": 3]), log: log)
        downloads.failing = [libraryItem("one").mediaIdentity]
        let harness = Harness(items: [libraryItem("one")], log: log, downloads: downloads)

        try await harness.remove(libraryItem("one"), includingDownloads: true)

        // The series left the Library and stays out; the message names the downloads that remain.
        #expect(harness.root.itemIDs.isEmpty)
        #expect(harness.messages.messages == [.downloadsNotDeleted])
        #expect(log.events == ["library:one", "downloads:one"])
    }

    @Test func theNotDeletedMessageIsTypedAndNeverClaimsARollback() throws {
        let center = AppMessageCenter()
        AppMessageLibraryPresenter(messageCenter: center).present(.downloadsNotDeleted)
        let message = try #require(center.currentMessage)
        #expect(message.kind == .libraryDownloadsNotDeleted)
        let text = (message.kind.presentation.detail ?? "").lowercased()
        #expect(text.contains("removed from library"))
        #expect(!text.contains("restored"))
        #expect(!text.contains("undone"))
        #expect(!text.contains("rolled back"))
    }

    // MARK: Real store

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func removeLibraryAndDownloadsDeletesTheStoredCopiesAndWritesSuppressionRows() async throws {
        let fixture = try DownloadWorkerFixture()
        let store = fixture.store
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "a1", canonicalMediaId: "series-1")
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "a2", canonicalMediaId: "series-1")
        _ = try await fixture.offline.enqueue(store, chapterKey: "a3", canonicalMediaId: "series-1")
        _ = try await fixture.offline.publishedEdition(store, chapterKey: "b1", canonicalMediaId: "series-2")
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        for await value in fixture.center.downloadSummaryPublisher.values where value.mediaWithDownloads.count == 2 { break }
        let items = [libraryItem("series-1"), libraryItem("series-2")]
        let harness = Harness(items: items, downloads: fixture.center)

        let request = try await harness.remove(items[0], includingDownloads: true)

        #expect(request.savedChapterCount == 2)
        #expect(harness.root.itemIDs == ["series-2"])
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 1)
        #expect(try await fixture.offline.rowCount("downloadJob") == 0)
        #expect(try await fixture.offline.rowCount("downloadSuppression") == 2)
        let remaining = try await store.verifiedEdition(for: OfflineChapterEdition(
            pluginId: DownloadWorkerFixture.plugin, mediaKind: .manga, canonicalMediaId: "series-2", chapterKey: "b1"
        ))
        #expect(remaining != nil)
        try await fixture.offline.assertInvariants(store)
        #expect(harness.messages.messages.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func removeFromLibraryLeavesStoredCopiesAndWritesNoSuppression() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store, chapterKey: "a1", canonicalMediaId: "series-1")
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        for await value in fixture.center.downloadSummaryPublisher.values where !value.mediaWithDownloads.isEmpty { break }
        let harness = Harness(items: [libraryItem("series-1")], downloads: fixture.center)

        try await harness.remove(libraryItem("series-1"), includingDownloads: false)

        #expect(harness.root.itemIDs.isEmpty)
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 1)
        #expect(try await fixture.offline.rowCount("downloadSuppression") == 0)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aLibraryRemovalFailureLeavesTheStoredCopiesAndWritesNoSuppression() async throws {
        let fixture = try DownloadWorkerFixture()
        _ = try await fixture.offline.publishedEdition(fixture.store, chapterKey: "a1", canonicalMediaId: "series-1")
        fixture.center.startObserving(scheduling: ImmediateValueObservationScheduler())
        for await value in fixture.center.downloadSummaryPublisher.values where !value.mediaWithDownloads.isEmpty { break }
        let harness = Harness(items: [libraryItem("series-1")], downloads: fixture.center)
        harness.root.failing = ["series-1"]

        try await harness.remove(libraryItem("series-1"), includingDownloads: true)

        #expect(harness.messages.messages == [.itemRemovalFailed])
        #expect(try await fixture.offline.rowCount("downloadedChapter") == 1)
        #expect(try await fixture.offline.rowCount("downloadSuppression") == 0)
    }
}

/// A Library whose removal waits for the test to commit it.
@MainActor
private final class GatedRoot: LibraryRootServing {
    private let subject: CurrentValueSubject<LibraryRootSnapshot, Never>
    private let log: RemovalLog
    private var pending: CheckedContinuation<Void, Error>?
    private let started = AsyncStream<Void>.makeStream()

    init(items: [Ito.LibraryItem], log: RemovalLog) {
        subject = CurrentValueSubject(LibraryRootSnapshot(items: items, categories: [], links: [], isLoading: false))
        self.log = log
    }

    var rootSnapshot: LibraryRootSnapshot { subject.value }
    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> { subject.eraseToAnyPublisher() }

    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws {
        log.events.append("library:\(itemID)")
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started.continuation.yield(())
        }
    }

    func removalStarted() async {
        for await _ in started.stream { return }
    }

    func commit() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}
