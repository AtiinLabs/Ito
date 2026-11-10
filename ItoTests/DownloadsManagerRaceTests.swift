import Combine
import Foundation
import Testing
import UIKit
import ito_runner
@testable import Ito

@MainActor
private final class DownloadReadGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, Error>?
    private let events = AsyncStream<Void>.makeStream()

    func read() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            events.continuation.yield(())
        }
    }
    func arrived() async {
        for await _ in events.stream { return }
    }
    func finish(_ result: Result<Value, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class RacedDownloadsOverview: TestDownloadsOverview {
    let capacityGate = DownloadReadGate<Int64>()
    let inventoryGate = DownloadReadGate<[OfflineInventorySummary]>()
    var gateCapacity = false
    var gateInventory = false
    var failInventoryReads: Set<Int> = []
    private(set) var capacityReads = 0
    private(set) var inventoryReads = 0

    override func availableCapacity() async throws -> Int64 {
        capacityReads += 1
        if gateCapacity && capacityReads == 1 { return try await capacityGate.read() }
        return Int64(capacityReads) * 1_024
    }
    override func inventorySummary() async throws -> [OfflineInventorySummary] {
        inventoryReads += 1
        if failInventoryReads.contains(inventoryReads) { throw Failure.requested }
        if gateInventory && inventoryReads == 1 { return try await inventoryGate.read() }
        return summaries
    }
}

@MainActor
private final class RaceDownloadsLibrary: LibraryRootServing {
    private let subject: CurrentValueSubject<LibraryRootSnapshot, Never>
    var rootSnapshot: LibraryRootSnapshot { subject.value }
    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> { subject.eraseToAnyPublisher() }
    init(_ items: [Ito.LibraryItem]) {
        subject = CurrentValueSubject(LibraryRootSnapshot(items: items, categories: [], links: [], isLoading: false))
    }
    func publish(_ items: [Ito.LibraryItem]) {
        subject.send(LibraryRootSnapshot(items: items, categories: [], links: [], isLoading: false))
    }
    func removeItem(itemID: String, pluginID: String, mediaKind: MediaKind) async throws {
        throw TestDownloadsOverview.Failure.requested
    }
}

/// Thumbnail reads are numbered in the order they are asked. A read can be held until the test releases it.
@MainActor
private final class RaceDownloadsThumbnails: DownloadsThumbnailServing {
    private(set) var calls = 0
    var gatedCalls: Set<Int> = []
    var missing = false
    private var gates: [Int: DownloadReadGate<LibraryDurableCover?>] = [:]
    let events = PassthroughSubject<String, Never>()
    var changes: AnyPublisher<String, Never> { events.eraseToAnyPublisher() }

    func gate(_ call: Int) -> DownloadReadGate<LibraryDurableCover?> {
        if let existing = gates[call] { return existing }
        let created = DownloadReadGate<LibraryDurableCover?>()
        gates[call] = created
        return created
    }

    func thumbnail(for item: Ito.LibraryItem) async -> LibraryDurableCover? {
        calls += 1
        if gatedCalls.contains(calls) { return try? await gate(calls).read() }
        return Self.cover(for: item, missing: missing)
    }

    static func cover(for item: Ito.LibraryItem, missing: Bool = false) -> LibraryDurableCover? {
        guard !missing, let url = item.coverUrl else { return nil }
        return LibraryDurableCover(image: UIImage(), coverURLSHA256: LibraryCoverThumbnailStore.coverHash(url))
    }
}

@MainActor
struct DownloadsManagerRaceTests {
    private func item(_ index: Int, cover: String? = nil) -> Ito.LibraryItem {
        Ito.LibraryItem(id: "series-\(index)", title: "Series", coverUrl: cover ?? "https://cover.test/\(index).jpg",
                    pluginId: "source", isAnime: false, pluginType: .manga, rawPayload: Data(), anilistId: nil)
    }
    private func series(_ item: Ito.LibraryItem) -> DownloadsSeries {
        var row = TestDownloadsOverview.row("one")
        row.edition = OfflineChapterEdition(media: item.mediaIdentity, chapterKey: "one")
        return DownloadsSeries(id: item.mediaIdentity, title: item.title, rows: [row])
    }

    @Test func largeInventoryLoadsOnlyDemandedRowsAndReleasesAllRetainedImages() async {
        let items = (0..<1_000).map { self.item($0) }
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = items.map(series)
        let covers = RaceDownloadsThumbnails()
        let model = DownloadsViewModel(service: service, library: RaceDownloadsLibrary(items), thumbnails: covers)
        await model.start()
        for _ in 0..<50 { service.receive?(.success(service.snapshot)) }
        #expect(covers.calls == 0)
        #expect(model.thumbnails.isEmpty)
        let owners = (0..<4).map { _ in UUID() }
        for index in 0..<4 { await model.loadThumbnail(for: items[index].mediaIdentity, owner: owners[index]) }
        #expect(covers.calls == 4)
        #expect(model.thumbnails.count == 4)
        for index in 0..<4 { model.releaseThumbnail(for: items[index].mediaIdentity, owner: owners[index]) }
        #expect(model.thumbnails.isEmpty)

        await model.loadThumbnail(for: items[4].mediaIdentity, owner: UUID())
        #expect(model.thumbnails.count == 1)
        service.receive?(.success(DownloadsSnapshot()))
        #expect(model.thumbnails.isEmpty)
        service.receive?(.success(DownloadsSnapshot(downloaded: service.snapshot.downloaded)))
        await model.loadThumbnail(for: items[5].mediaIdentity, owner: UUID())
        #expect(model.thumbnails.count == 1)
        model.stop()
        #expect(model.thumbnails.isEmpty)
    }

    @Test func missingCoverIsReadOncePerItemAndCoverUntilCaptureOrCoverChange() async {
        let item = self.item(0)
        let other = self.item(1)
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = [series(item)]
        let covers = RaceDownloadsThumbnails()
        covers.missing = true
        let library = RaceDownloadsLibrary([item])
        let model = DownloadsViewModel(service: service, library: library, thumbnails: covers)
        await model.start()
        defer { model.stop() }
        let owner = UUID()
        await model.loadThumbnail(for: item.mediaIdentity, owner: owner)
        for _ in 0..<100 {
            service.receive?(.success(service.snapshot))
            await model.loadThumbnail(for: item.mediaIdentity, owner: owner)
        }
        library.publish([item, other])
        await model.loadThumbnail(for: item.mediaIdentity, owner: owner)
        #expect(covers.calls == 1)
        #expect(model.thumbnails.isEmpty)

        let changed = self.item(0, cover: "https://cover.test/replacement.jpg")
        library.publish([changed, other])
        await model.loadThumbnail(for: item.mediaIdentity, owner: owner)
        #expect(covers.calls == 2)

        covers.missing = false
        covers.events.send(item.id)
        await model.loadThumbnail(for: item.mediaIdentity, owner: owner)
        #expect(covers.calls == 3)
        #expect(model.thumbnails.count == 1)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func oldSessionThumbnailLoadNeverStrandsOrClearsTheNewSession(oldReleasedFirst: Bool) async {
        let item = self.item(0)
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = [series(item)]
        let covers = RaceDownloadsThumbnails()
        covers.gatedCalls = [1, 2]
        let model = DownloadsViewModel(service: service, library: RaceDownloadsLibrary([item]), thumbnails: covers)
        await model.start()
        let oldOwner = UUID()
        let oldTask = Task { await model.loadThumbnail(for: item.mediaIdentity, owner: oldOwner) }
        await covers.gate(1).arrived()
        model.stop()
        await model.start()
        let newOwner = UUID()
        let newTask = Task { await model.loadThumbnail(for: item.mediaIdentity, owner: newOwner) }
        await covers.gate(2).arrived()
        let cover = RaceDownloadsThumbnails.cover(for: item)
        if oldReleasedFirst {
            covers.gate(1).finish(.success(cover))
            await oldTask.value
            #expect(model.thumbnails.isEmpty)
            covers.gate(2).finish(.success(cover))
            await newTask.value
        } else {
            covers.gate(2).finish(.success(cover))
            await newTask.value
            covers.gate(1).finish(.success(cover))
            await oldTask.value
        }
        #expect(model.thumbnails.count == 1)
        model.releaseThumbnail(for: item.mediaIdentity, owner: oldOwner)
        #expect(model.thumbnails.count == 1)
        model.releaseThumbnail(for: item.mediaIdentity, owner: newOwner)
        #expect(model.thumbnails.isEmpty)
        await model.loadThumbnail(for: item.mediaIdentity, owner: UUID())
        #expect(covers.calls == 3)
        #expect(model.thumbnails.count == 1)
        model.stop()
        #expect(model.thumbnails.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func oldCapacityFailureOrSuccessCannotReplaceRestartedSession(failure: Bool) async {
        let service = RacedDownloadsOverview()
        service.gateCapacity = true
        let model = DownloadsViewModel(service: service, library: PreparedLibraryDependencies.unavailable().library)
        let old = Task { await model.start() }
        await service.capacityGate.arrived()
        model.stop()
        await model.start()
        #expect(model.availableBytes == 2_048)
        service.capacityGate.finish(failure ? .failure(TestDownloadsOverview.Failure.requested) : .success(12))
        await old.value
        #expect(model.availableBytes == 2_048)
        model.stop()
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func completedInventoryRefreshesCapacityButPageProgressDoesNot() async {
        let service = RacedDownloadsOverview()
        let model = DownloadsViewModel(service: service, library: PreparedLibraryDependencies.unavailable().library)
        await model.start()
        defer { model.stop() }
        for _ in 0..<100 { service.receive?(.success(service.snapshot)) }
        #expect(service.capacityReads == 1)
        service.snapshot.downloaded = [series(item(0))]
        service.receive?(.success(service.snapshot))
        for await bytes in model.$availableBytes.values { if bytes == 2_048 { break } }
        #expect(service.capacityReads == 2)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func clearBaselineSurvivesOlderStorageMeasurement(failure: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let service = RacedDownloadsOverview()
        service.gateInventory = true
        let media = TestDownloadsOverview.media("a")
        service.summaries = [OfflineInventorySummary(media: media, state: .verified, count: 1, byteCount: 20)]
        service.failedSeries = [media]
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool),
                                             storageAccess: TestSettingsStorageAccess(), downloads: service)
        let old = Task { await model.refreshDownloadsUsage() }
        await service.inventoryGate.arrived()
        await model.clearDownloads()
        let message = model.downloadsMessage
        #expect(model.downloadBytes == 20)
        #expect(message?.contains("Other deletions were kept") == true)
        service.inventoryGate.finish(failure ? .failure(TestDownloadsOverview.Failure.requested) : .success([]))
        await old.value
        #expect(model.downloadBytes == 20)
        #expect(model.downloadsMessage == message)
        #expect(model.measurementMessage == nil)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func newStorageMeasurementOwnsBothBytesAndMessage(failure: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let service = RacedDownloadsOverview()
        service.gateInventory = true
        service.summaries = [OfflineInventorySummary(media: TestDownloadsOverview.media("a"),
                                                    state: .verified, count: 1, byteCount: 30)]
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool),
                                             storageAccess: TestSettingsStorageAccess(), downloads: service)
        let old = Task { await model.refreshDownloadsUsage() }
        await service.inventoryGate.arrived()
        await model.refreshDownloadsUsage()
        #expect(model.downloadBytes == 30)
        service.inventoryGate.finish(failure ? .failure(TestDownloadsOverview.Failure.requested) : .success([]))
        await old.value
        #expect(model.downloadBytes == 30)
        #expect(model.measurementMessage == nil)
    }

    @Test func deletionOutcomeSurvivesEveryLaterMeasurementAndMeasurementKeepsItsOwnError() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let service = RacedDownloadsOverview()
        let media = TestDownloadsOverview.media("a")
        service.summaries = [OfflineInventorySummary(media: media, state: .verified, count: 1, byteCount: 20)]
        service.failedSeries = [media]
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool),
                                             storageAccess: TestSettingsStorageAccess(), downloads: service)
        await model.clearDownloads()
        let outcome = try #require(model.downloadsMessage)
        #expect(outcome.contains("Other deletions were kept"))
        #expect(model.downloadBytes == 20)

        service.failInventoryReads = [service.inventoryReads + 1]
        await model.refreshDownloadsUsage()
        #expect(model.downloadBytes == nil)
        #expect(model.measurementMessage != nil)
        #expect(model.downloadsMessage == outcome)

        await model.refreshDownloadsUsage()
        #expect(model.downloadBytes == 20)
        #expect(model.measurementMessage == nil)
        #expect(model.downloadsMessage == outcome)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func unreadableInventoryBeforeDeletionIsReportedEvenWhileARefreshRuns() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let service = RacedDownloadsOverview()
        service.gateInventory = true
        let media = TestDownloadsOverview.media("a")
        service.summaries = [OfflineInventorySummary(media: media, state: .verified, count: 1, byteCount: 20)]
        let model = StorageSettingsViewModel(settingsStore: AppSettingsStore(dbPool: database.dbPool),
                                             storageAccess: TestSettingsStorageAccess(), downloads: service)
        let clear = Task { await model.clearDownloads() }
        await service.inventoryGate.arrived()
        await model.refreshDownloadsUsage()
        #expect(model.downloadBytes == 20)
        service.inventoryGate.finish(.failure(TestDownloadsOverview.Failure.requested))
        await clear.value
        #expect(model.downloadsMessage?.contains("couldn't be deleted") == true)
        #expect(model.measurementMessage == nil)
        #expect(model.downloadBytes == 20)
        #expect(service.deletedSeries.isEmpty)
        #expect(!model.isClearingDownloads)
    }

    @Test func laterRowTakesOverTheCoverSoTheEarlierRowsReleaseCannotClearIt() async {
        let item = self.item(0)
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = [series(item)]
        let covers = RaceDownloadsThumbnails()
        let model = DownloadsViewModel(service: service, library: RaceDownloadsLibrary([item]), thumbnails: covers)
        await model.start()
        defer { model.stop() }
        let first = UUID()
        let second = UUID()
        await model.loadThumbnail(for: item.mediaIdentity, owner: first)
        await model.loadThumbnail(for: item.mediaIdentity, owner: second)
        model.releaseThumbnail(for: item.mediaIdentity, owner: first)
        #expect(model.thumbnails.count == 1)
        #expect(covers.calls == 1)
        model.releaseThumbnail(for: item.mediaIdentity, owner: second)
        #expect(model.thumbnails.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func takeoverDuringALoadStillDeliversTheCoverToTheLaterRow() async {
        let item = self.item(0)
        let service = TestDownloadsOverview()
        service.snapshot.downloaded = [series(item)]
        let covers = RaceDownloadsThumbnails()
        covers.gatedCalls = [1]
        let model = DownloadsViewModel(service: service, library: RaceDownloadsLibrary([item]), thumbnails: covers)
        await model.start()
        defer { model.stop() }
        let first = UUID()
        let second = UUID()
        let load = Task { await model.loadThumbnail(for: item.mediaIdentity, owner: first) }
        await covers.gate(1).arrived()
        await model.loadThumbnail(for: item.mediaIdentity, owner: second)
        model.releaseThumbnail(for: item.mediaIdentity, owner: first)
        covers.gate(1).finish(.success(RaceDownloadsThumbnails.cover(for: item)))
        await load.value
        #expect(model.thumbnails.count == 1)
        #expect(covers.calls == 1)
        model.releaseThumbnail(for: item.mediaIdentity, owner: second)
        #expect(model.thumbnails.isEmpty)
    }

    @Test func aScreenThatDisappearsBeforeItsTaskRunsLeavesNoObservationAndKeepsOtherScreens() async {
        let service = RacedDownloadsOverview()
        let model = DownloadsViewModel(service: service, library: PreparedLibraryDependencies.unavailable().library)
        model.attach()
        model.stop()
        await model.refreshAvailableSpace()
        #expect(service.activeSubscriptions == 0)
        #expect(service.capacityReads == 0)

        model.attach()
        model.attach()
        model.stop()
        #expect(service.activeSubscriptions == 1)
        model.stop()
        #expect(service.activeSubscriptions == 0)
    }

    @Test func selectedRestoreApprovalIsSeparateForRestoredOnlyAndMixedSelections() async {
        let service = TestDownloadsOverview()
        let failed = TestDownloadsOverview.row("failed", state: .failed(.network), job: "f")
        let restored = TestDownloadsOverview.row("restore", state: .waiting(.restoredPendingReview), job: "r")
        service.snapshot.inProgress = [DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Queue", rows: [failed, restored])]
        let model = DownloadsViewModel(service: service, library: PreparedLibraryDependencies.unavailable().library)
        await model.start()
        defer { model.stop() }
        model.selectedJobs = [restored.id]
        #expect(model.selectedRetryableJobs.isEmpty)
        #expect(model.selectedPausedJobs.map(\.jobID) == ["r"])
        await model.retry(model.selectedJobRows)
        #expect(service.retriedIDs.isEmpty)
        model.selectedJobs = [failed.id, restored.id]
        #expect(model.selectedRetryableJobs.map(\.jobID) == ["f"])
        #expect(model.selectedPausedJobs.map(\.jobID) == ["r"])
        await model.retry(model.selectedRetryableJobs)
        await model.resumePaused(model.selectedPausedJobs)
        #expect(service.retriedIDs == [["f"], ["r"]])
    }

    @Test func progressBelongsToPersistedJobIDAndCannotCrossReplacementOfSameEdition() {
        let old = TestDownloadsOverview.row("same", state: .downloading(completed: 0, total: nil), job: "old")
        var replacement = old
        replacement.jobID = "new"
        let snapshot = DownloadsSnapshot(inProgress: [DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Queue", rows: [replacement])])
        let oldReport = DownloadProgress(jobID: "old", completedPages: 9, totalPages: 10, bytes: 1)
        #expect(snapshot.applying(progress: ["old": oldReport]).inProgress[0].rows[0].state == replacement.state)
        let report = DownloadProgress(jobID: "new", completedPages: 1, totalPages: 3, bytes: 1)
        #expect(snapshot.applying(progress: ["new": report]).inProgress[0].rows[0].state == .downloading(completed: 1, total: 3))
        replacement.state = .waiting(.noConnection)
        let waiting = DownloadsSnapshot(inProgress: [DownloadsSeries(id: TestDownloadsOverview.media("a"), title: "Queue", rows: [replacement])])
        #expect(waiting.applying(progress: ["new": report]).inProgress[0].rows[0].state == .waiting(.noConnection))
    }
}
