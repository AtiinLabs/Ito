import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// The explicit "Find All Uploads" action: only the user's tap asks the source, what comes back is an
/// ephemeral catalog that nothing persists, and queueing from it is exact, frozen and guarded.
@MainActor
struct EditionEnumerationTests {
    private static let epoch = "0123456789abcdef0123456789abcdef"

    /// A source whose editions export a test controls. Each call is recorded; a held call waits until released,
    /// so a test can act between the request and its answer.
    @MainActor
    final class FakeEditions {
        struct Call {
            let entry: MediaEntry
            let operation: PluginNetworkOperation
            let sourceEpoch: String
        }

        private(set) var calls: [Call] = []
        var outcome: Result<EnumeratedChapterEditions?, any Error> = .success(nil)
        var holds = false
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var arrival: CheckedContinuation<Void, Never>?

        var closure: ChapterEditionEnumeration {
            { [self] entry, operation, epoch in try await enumerate(entry, operation, epoch) }
        }

        private func enumerate(_ entry: MediaEntry, _ operation: PluginNetworkOperation, _ epoch: String) async throws -> EnumeratedChapterEditions? {
            calls.append(Call(entry: entry, operation: operation, sourceEpoch: epoch))
            if holds {
                await withCheckedContinuation { continuation in
                    pending.append(continuation)
                    arrival?.resume()
                    arrival = nil
                }
            }
            return try outcome.get()
        }

        /// Returns once a call is held.
        func waitForHeldCall() async {
            guard pending.isEmpty else { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            holds = false
            let released = pending
            pending = []
            released.forEach { $0.resume() }
        }
    }

    private static func found(
        _ editions: [Chapter],
        scope: CatalogScope = .allEligible,
        completeness: CatalogCompleteness = .complete,
        termination: ChapterEditionsResult.Termination = .exhausted
    ) -> EnumeratedChapterEditions {
        EnumeratedChapterEditions(
            editions: editions, scope: scope, completeness: completeness, termination: termination
        )
    }

    /// The normal list: A uploads of positions 1 and 2.
    private static let normalList = [
        Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "ga", logicalUnitID: "u1"),
        Chapter(key: "a2", chapter: 2, scanlator: "A", scanlatorID: "ga", logicalUnitID: "u2")
    ]

    /// What the source lists in full: the normal list plus two more groups' uploads, one of them locked, and an
    /// upload that declares no position.
    private static let everyUpload = normalList + [
        Chapter(key: "b1", title: "One", chapter: 1, scanlator: "B", scanlatorID: "gb", url: "https://b/1", logicalUnitID: "u1", revision: "r-b1"),
        Chapter(key: "c1", chapter: 1, scanlator: "C", scanlatorID: "gc", logicalUnitID: "u1"),
        Chapter(key: "b2", chapter: 2, scanlator: "B", scanlatorID: "gb", paywalled: true, logicalUnitID: "u2"),
        Chapter(key: "x", chapter: 3, scanlator: "X")
    ]

    private func makeSubject(
        fake: FakeEditions?,
        downloads: MediaDetailDownloadsFake = MediaDetailDownloadsFake(),
        downloadService: (any MediaDetailDownloadServing)? = nil,
        relinkTargets: [Manga] = []
    ) async -> MediaDetailDownloadBatchTests.Subject {
        await MediaDetailDownloadBatchTests().makeSubject(
            chapters: Self.normalList,
            downloads: downloads,
            relinkTargets: relinkTargets,
            downloadService: downloadService,
            enumerateEditions: fake?.closure
        )
    }

    private func openChooser(_ subject: MediaDetailDownloadBatchTests.Subject) async -> EditionChooserPresentation? {
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The scanlator chooser should be open")
            return nil
        }
        return presentation
    }

    private func loadedResult(_ subject: MediaDetailDownloadBatchTests.Subject) -> EditionEnumerationResult? {
        guard case .loaded(let result) = subject.viewModel.downloadBatch.enumeration else {
            Issue.record("The listing should be loaded")
            return nil
        }
        return result
    }

    // MARK: - Nothing asks the source but the explicit action

    @Test func detailLoadRefreshPresetsAndTheChooserNeverAskTheSource() async throws {
        let fake = FakeEditions()
        let subject = await makeSubject(fake: fake)
        #expect(fake.calls.isEmpty, "Opening and loading the detail screen never lists uploads")

        await subject.viewModel.refresh()
        await subject.viewModel.downloadBatch.startDownload(.all).value
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.startDownload(.next).value
        _ = await openChooser(subject)
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: false, then: .all).value

        #expect(fake.calls.isEmpty, "Presets, refreshes and the chooser itself never list uploads")
        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
    }

    @Test func anExplicitTapAsksOnceUnderAnInteractiveOperationAndTheReviewedEpoch() async throws {
        let fake = FakeEditions()
        fake.holds = true
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))

        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()
        // A second tap while one listing is running is not acted on.
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        #expect(subject.viewModel.downloadBatch.enumeration == .loading)
        fake.release()
        await running.value

        #expect(fake.calls.count == 1)
        let call = try #require(fake.calls.first)
        #expect(call.operation.purpose == .manualCatalogRefresh)
        #expect(call.sourceEpoch == chooser.sourceEpoch)
        #expect(call.entry.kind == .manga)
    }

    @Test func aSheetThatIsNotTheOpenChooserCannotStartAListing() async throws {
        let fake = FakeEditions()
        let subject = await makeSubject(fake: fake)
        _ = await openChooser(subject)

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: UUID()).value

        #expect(fake.calls.isEmpty)
        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
    }

    @Test func aSourceRouteWithoutTheExportOffersNoAction() async throws {
        let subject = await makeSubject(fake: nil)
        let chooser = try #require(await openChooser(subject))

        #expect(!subject.viewModel.downloadBatch.canFindAllUploads)
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
    }

    // MARK: - Unsupported

    @Test func aSourceThatTakesNoPartLeavesTheListAndCatalogUnchanged() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(nil)
        let subject = await makeSubject(fake: fake)
        let digest = subject.viewModel.catalogDigest
        let chooser = try #require(await openChooser(subject))

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        #expect(subject.viewModel.downloadBatch.enumeration == .unsupported)
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(subject.viewModel.catalogDigest == digest)
        #expect(subject.viewModel.downloadBatch.host?.batchChapters.map(\.key) == ["a1", "a2"])
        #expect(subject.downloads.batchRequests.isEmpty)
    }

    // MARK: - Results and disclosures

    @Test func aCompleteListingGroupsTheMoreUploadsByLogicalPositionWithExactRows() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        let result = try #require(loadedResult(subject))
        #expect(result.totalCount == 6)
        #expect(result.additionalCount == 4, "The uploads the list already shows are not offered again")
        #expect(result.groups.map(\.id) == ["logical:u1", "logical:u2", "exact:x"])
        #expect(result.groups[0].rows.map(\.key) == ["b1", "c1"], "Two groups' uploads of one position share one group")
        #expect(result.groups[1].rows.map(\.key) == ["b2"])
        #expect(result.groups[0].rows.map(\.scanlator) == ["B", "C"])
        #expect(result.disclosure.lines == [.coversEveryUploadOffered])
        // The locked upload is shown, and blocked.
        #expect(result.groups[1].rows.map(\.isLocked) == [true])
        #expect(result.groups[1].rows.map(\.isSelectable) == [false])
        #expect(result.groups[0].rows.map(\.isSelectable) == [true, true])
    }

    @Test func aPartialListingSaysSomeUploadsMayBeMissing() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload, completeness: .partial))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        #expect(try #require(loadedResult(subject)).disclosure.lines == [.someUploadsMayBeMissing])
    }

    @Test func aBoundedListingNamesTheUploadsItHoldsNotTheCapAndNeverClaimsCoverage() async throws {
        let fake = FakeEditions()
        // The runner leaves out a page that would pass its cap, so a capped listing holds fewer than the cap.
        fake.outcome = .success(Self.found(Self.everyUpload, completeness: .partial, termination: .bounded(.rows)))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        #expect(Self.everyUpload.count < ChapterEditionsLimits.maxRows)
        #expect(try #require(loadedResult(subject)).disclosure.lines == [
            .stoppedAtUploadLimit(Self.everyUpload.count)
        ])
    }

    @Test(arguments: [
        (CatalogScope.allEligible, CatalogCompleteness.complete, ChapterEditionsResult.Termination.exhausted,
         [EditionEnumerationDisclosure.Line.coversEveryUploadOffered]),
        (.visible, .complete, .exhausted, [.visibleUploadsOnly]),
        (.unknown, .complete, .exhausted, [.scopeNotStated]),
        (.allEligible, .partial, .exhausted, [.someUploadsMayBeMissing]),
        (.visible, .partial, .exhausted, [.someUploadsMayBeMissing, .visibleUploadsOnly]),
        (.allEligible, .unknown, .exhausted, [.completenessNotStated]),
        (.unknown, .unknown, .exhausted, [.completenessNotStated, .scopeNotStated]),
        (.allEligible, .partial, .bounded(.pages), [.stoppedAtPageLimit(ChapterEditionsLimits.maxPages)]),
        (.visible, .partial, .bounded(.bytes), [.stoppedAtSizeLimit, .visibleUploadsOnly]),
        // A bounded traversal is never exhaustive, whatever completeness a caller supplies.
        (.allEligible, .complete, .bounded(.rows), [.stoppedAtUploadLimit(6)])
    ])
    func disclosuresSayOnlyWhatTheListingClaims(
        scope: CatalogScope,
        completeness: CatalogCompleteness,
        termination: ChapterEditionsResult.Termination,
        lines: [EditionEnumerationDisclosure.Line]
    ) {
        #expect(EditionEnumerationDisclosure(
            scope: scope, completeness: completeness, termination: termination, listedCount: 6
        ).lines == lines)
    }

    // MARK: - Nothing is persisted

    @Test func aListingChangesNoPersistedStateOrCountBasisOnTheFakes() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let digest = subject.viewModel.catalogDigest
        let chooser = try #require(await openChooser(subject))
        let refreshes = subject.library.refreshCount

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        _ = try #require(loadedResult(subject))
        #expect(subject.library.replaceRequests.isEmpty, "No saved snapshot is written")
        #expect(subject.library.saveKinds.isEmpty)
        #expect(subject.library.refreshCount == refreshes)
        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.catalogDigest == digest, "The normal list's digest, the count basis, is untouched")
        #expect(subject.viewModel.downloadBatch.host?.batchChapters.map(\.key) == ["a1", "a2"])
        #expect(subject.messages.messages.isEmpty)
    }

    @Test func aListingLeavesTheDownloadTablesUnchanged() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        try await fixture.offline.database.dbPool.write { db in
            try LibraryItem(
                id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test",
                isAnime: false, pluginType: .manga, rawPayload: Data("{}".utf8), anilistId: nil
            ).insert(db)
        }
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload, completeness: .partial, termination: .bounded(.bytes)))
        let subject = await makeSubject(fake: fake, downloadService: fixture.center)
        let chooser = try #require(await openChooser(subject))
        let database = fixture.offline.database.dbPool
        func snapshot() async throws -> (Int, Int, Int, Int, Int) {
            try await database.read { db in
                (
                    try DownloadBatchRecord.fetchCount(db),
                    try DownloadJobRecord.fetchCount(db),
                    try DownloadedChapterRecord.fetchCount(db),
                    try LibrarySnapshotStateRecord.fetchCount(db),
                    try LibraryItem.fetchCount(db)
                )
            }
        }
        let before = try await snapshot()

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        _ = try #require(loadedResult(subject))
        let after = try await snapshot()
        #expect(after.0 == 0 && after.1 == 0 && after.2 == 0)
        #expect(after == before)
    }

    // MARK: - Cancellation and no stale publication

    @Test func dismissingTheSheetCancelsAHeldListingAndItsLateAnswerPublishesNothing() async throws {
        let fake = FakeEditions()
        fake.holds = true
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))
        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()

        subject.viewModel.downloadBatch.dismissDownloadSheet()
        fake.release()
        await running.value

        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
    }

    @Test func aChangedChapterListCancelsAHeldListingAndItsLateAnswerPublishesNothing() async throws {
        let fake = FakeEditions()
        fake.holds = true
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))
        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()

        subject.catalog.chapters = Self.normalList + [Chapter(key: "a3", chapter: 3, scanlator: "A", logicalUnitID: "u3")]
        await subject.viewModel.refresh()
        fake.release()
        await running.value

        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
    }

    @Test func relinkingToAnotherSeriesCancelsAHeldListingAndItsLateAnswerPublishesNothing() async throws {
        let fake = FakeEditions()
        fake.holds = true
        fake.outcome = .success(Self.found(Self.everyUpload))
        let target = Manga(
            key: "series-2", title: "Series Two",
            chapters: [Chapter(key: "s2-1", chapter: 1, scanlator: "Z", logicalUnitID: "z1")]
        )
        let subject = await makeSubject(fake: fake, relinkTargets: [target])
        let chooser = try #require(await openChooser(subject))
        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()

        subject.viewModel.openRelink()
        await subject.viewModel.performRelink(with: target)
        fake.release()
        await running.value

        #expect(subject.viewModel.mediaIdentity.canonicalMediaId == "series-2")
        #expect(fake.calls.count == 1, "Relinking asks the source nothing more")
        #expect(subject.viewModel.downloadBatch.enumeration == .idle, "The old series' answer is not published")
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(subject.downloads.batchRequests.isEmpty)
    }

    @Test func aSourceEpochChangeBeforeTheAnswerPublishesNothingAndAsksForReview() async throws {
        let fake = FakeEditions()
        fake.holds = true
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()

        downloads.policyEpoch = "rotated-epoch"
        fake.release()
        await running.value

        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(subject.messages.messages == [.editionChoiceChanged])
    }

    @Test func cancellingARunningListingEndsItWithoutAMessage() async throws {
        let fake = FakeEditions()
        fake.holds = true
        fake.outcome = .failure(CancellationError())
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))
        let running = subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id)
        await fake.waitForHeldCall()

        subject.viewModel.downloadBatch.cancelEnumeration()
        fake.release()
        await running.value

        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.messages.messages.isEmpty)
        #expect(subject.viewModel.downloadSheet?.chooserID == chooser.id, "Only the listing ends; the chooser stays")
    }

    // MARK: - Errors

    @Test func aFailedListingShowsItsReasonKeepsNoRowsAndIsNotRetried() async throws {
        let fake = FakeEditions()
        fake.outcome = .failure(PluginCallError(kind: .incompatible, message: "Update the source."))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))

        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        #expect(subject.viewModel.downloadBatch.enumeration == .failed(message: "Update the source."))
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
        #expect(fake.calls.count == 1, "A failure is never retried on its own")
        #expect(subject.downloads.batchRequests.isEmpty)

        // The user may ask again; that is a new explicit call, and a success replaces the failure.
        fake.outcome = .success(Self.found(Self.everyUpload))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        #expect(fake.calls.count == 2)
        _ = try #require(loadedResult(subject))
    }

    @Test func aFailureAfterRowsWereHeldDiscardsThemAll() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        _ = try #require(loadedResult(subject))

        fake.outcome = .failure(PluginCallError(kind: .host, message: "Timed out."))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        #expect(subject.viewModel.downloadBatch.enumeration == .failed(message: "Timed out."))
        #expect(subject.viewModel.downloadBatch.enumeratedChapters.isEmpty)
    }

    // MARK: - Queueing exact rows

    @Test func tickedUploadsQueueAsFrozenExactChaptersUnderTheReviewedEpochWithoutRemembering() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        // c1 and x are ticked, with the locked b2 and an unlisted key that must not be queued.
        await subject.viewModel.downloadBatch
            .downloadEnumeratedUploads(keys: ["x", "c1", "b2", "ghost"], chooserID: chooser.id).value

        let request = try #require(downloads.batchRequests.first)
        #expect(downloads.batchRequests.count == 1)
        #expect(request.chapters.map(\.key) == ["c1", "x"], "Exactly the ticked unlocked uploads, in reading order")
        #expect(request.chapters.first?.scanlatorID == "gc")
        #expect(request.preset == .single)
        #expect(request.reviewedSourceEpoch == chooser.sourceEpoch)
        #expect(request.catalogDigest == nil, "The batch was not planned from the normal list")
        #expect(request.reviewedPolicy == ReviewedEditionPolicy.none)
        #expect(try JSONDecoder().decode(EditionSelection.self, from: request.selection) == .sourceList)
        #expect(downloads.preferenceWriteCount == 0, "Nothing is remembered")
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.messages.messages == [.downloadsQueued(queued: 2, alreadyStored: 0)])
    }

    @Test func theQueuedSnapshotIsTheListedChapterExactly() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b1"], chooserID: chooser.id).value

        let queued = try #require(downloads.batchRequests.first?.chapters.first)
        #expect(queued.key == "b1")
        #expect(queued.title == "One")
        #expect(queued.url == "https://b/1")
        #expect(queued.revision == "r-b1")
        #expect(queued.logicalUnitID == "u1")
        #expect(queued.scanlator == "B" && queued.scanlatorID == "gb")
    }

    @Test func aLockedUploadIsNeverQueuedAndSaysThereIsNothingToDownload() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b2"], chooserID: chooser.id).value

        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.messages.messages == [.nothingToDownload])
    }

    @Test func anUploadThatAlreadyHasACopyIsNotOfferedAndNotQueuedAgain() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "b1")
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        let result = try #require(loadedResult(subject))
        let row = try #require(result.groups.first?.rows.first { $0.key == "b1" })
        #expect(row.stored == .verified)
        #expect(!row.isSelectable)

        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b1", "c1"], chooserID: chooser.id).value
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["c1"])
    }

    @Test func aFailedUploadIsListedAsFailedAndNeverQueuedAgain() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.failed(.network), chapterKey: "b1")
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        let row = try #require(loadedResult(subject)?.groups.first?.rows.first { $0.key == "b1" })
        #expect(row.isFailed, "A failed job is listed as failed, never as plainly queued")
        #expect(row.stored == .queued, "A failed job still occupies its upload")
        #expect(!row.isSelectable)

        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b1", "c1"], chooserID: chooser.id).value
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["c1"], "Retry is in the Downloads queue")
    }

    @Test func aQueuedUploadThatFinishesOrFailsWhileTheSheetIsOpenIsShownAsItIsNow() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.queued, chapterKey: "b1")
        downloads.set(.queued, chapterKey: "c1")
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        func row(_ key: String) -> EnumeratedEditionRow? {
            guard case .loaded(let result) = subject.viewModel.downloadBatch.enumeration else { return nil }
            return result.groups.flatMap(\.rows).first { $0.key == key }
        }
        let listing = try #require(loadedResult(subject)).id
        #expect(row("b1")?.stored == .queued && row("b1")?.isFailed == false)

        downloads.set(.downloaded, chapterKey: "b1")
        downloads.set(.failed(.sourceError), chapterKey: "c1")

        #expect(row("b1")?.stored == .verified)
        #expect(row("b1")?.isFailed == false)
        #expect(row("c1")?.isFailed == true)
        #expect(row("x")?.stored == StoredEditionState.none, "Rows without a job stay as they were")
        #expect(try #require(loadedResult(subject)).id == listing, "The same listing is refreshed, not replaced")

        downloads.set(nil, chapterKey: "b1")
        #expect(row("b1")?.stored == StoredEditionState.none)
        #expect(row("b1")?.isSelectable == true)
    }

    @Test func queuingAfterASourceEpochChangeIsRefusedAndNothingIsQueued() async throws {
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(fake: fake, downloads: downloads)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        _ = try #require(loadedResult(subject))

        downloads.policyEpoch = "rotated-epoch"
        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b1"], chooserID: chooser.id).value

        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(subject.viewModel.downloadBatch.enumeration == .idle)
        #expect(subject.messages.messages == [.editionChoiceChanged])
    }

    @Test func aRotatedEpochInTheRealDatabaseRefusesATickedBatchBeforeAnythingIsQueued() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        try await fixture.offline.database.dbPool.write { db in
            try LibraryItem(
                id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test",
                isAnime: false, pluginType: .manga, rawPayload: Data("{}".utf8), anilistId: nil
            ).insert(db)
        }
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake, downloadService: fixture.center)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value
        _ = try #require(loadedResult(subject))

        // A different source authorization commits between the review and the queue.
        try await fixture.offline.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE \(PluginCompletionScope.tableName) SET epoch = ? WHERE pluginId = ?",
                arguments: ["ffffffffffffffffffffffffffffffff", "plugin.test"]
            )
        }
        await subject.viewModel.downloadBatch.downloadEnumeratedUploads(keys: ["b1"], chooserID: chooser.id).value

        #expect(try await fixture.store.jobs().isEmpty)
        #expect(subject.messages.messages == [.editionChoiceChanged])
    }

    @Test func theRealStoreQueuesTickedUploadsAsExactJobsAndRefusesLockedOnes() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        try await fixture.offline.database.dbPool.write { db in
            try LibraryItem(
                id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test",
                isAnime: false, pluginType: .manga, rawPayload: Data("{}".utf8), anilistId: nil
            ).insert(db)
        }
        let fake = FakeEditions()
        fake.outcome = .success(Self.found(Self.everyUpload))
        let subject = await makeSubject(fake: fake, downloadService: fixture.center)
        let chooser = try #require(await openChooser(subject))
        await subject.viewModel.downloadBatch.findAllUploads(chooserID: chooser.id).value

        await subject.viewModel.downloadBatch
            .downloadEnumeratedUploads(keys: ["b1", "c1", "b2"], chooserID: chooser.id).value

        #expect(Set(try await fixture.store.jobs().map(\.chapterKey)) == ["b1", "c1"])
        #expect(subject.messages.messages == [.downloadsQueued(queued: 2, alreadyStored: 0)])
    }

    // MARK: - The runner adapter

    @Test func theAdapterRunsTheExportUnderTheFrozenEpochAndTheCallersOperation() async throws {
        let contexts = PluginNetworkContexts()
        var seen: [NetworkOperationContext] = []
        let listing = Self.found(Self.everyUpload)
        let adapter = ChapterEditionsAdapter(pluginID: "plugin.test", contexts: contexts) { _, context in
            seen.append(context)
            return listing
        }
        let operation = PluginNetworkOperation(purpose: .manualCatalogRefresh, operationID: UUID())

        let result = try await adapter.enumerate(
            .manga(Manga(key: "series-1", title: "Series")), operation: operation, sourceEpoch: Self.epoch
        )

        #expect(result?.editions.map(\.key) == Self.everyUpload.map(\.key))
        let context = try #require(seen.first)
        #expect(seen.count == 1)
        #expect(context.purpose == .manualCatalogRefresh)
        #expect(context.sourceID == "plugin.test")
        #expect(context.operationID == operation.operationID)
        #expect(context.authorizationScope == PluginNetworkScopeID.uuid(epoch: Self.epoch))
    }

    @Test func theAdapterKeepsNilAsTheOnlyUnsupportedAndMapsEveryFailureToAPluginCallError() async throws {
        let contexts = PluginNetworkContexts()
        let operation = PluginNetworkOperation(purpose: .manualCatalogRefresh, operationID: UUID())
        let entry = MediaEntry.manga(Manga(key: "series-1", title: "Series"))

        let unsupported = ChapterEditionsAdapter(pluginID: "plugin.test", contexts: contexts) { _, _ in nil }
        #expect(try await unsupported.enumerate(entry, operation: operation, sourceEpoch: Self.epoch) == nil)

        let violation = ChapterEditionsAdapter(pluginID: "plugin.test", contexts: contexts) { _, _ in
            throw ItoError.chapterEditionsViolation(function: "get_chapter_editions", violation: .init(.pageCount))
        }
        let timeout = ChapterEditionsAdapter(pluginID: "plugin.test", contexts: contexts) { _, _ in
            throw ItoError.hostCallTimedOut(.net)
        }
        let cancelled = ChapterEditionsAdapter(pluginID: "plugin.test", contexts: contexts) { _, _ in
            throw CancellationError()
        }

        do {
            _ = try await violation.enumerate(entry, operation: operation, sourceEpoch: Self.epoch)
            Issue.record("A violation is a failure, never an empty result")
        } catch let error as PluginCallError {
            #expect(error.kind == .incompatible)
        }
        do {
            _ = try await timeout.enumerate(entry, operation: operation, sourceEpoch: Self.epoch)
            Issue.record("A timeout is a failure")
        } catch let error as PluginCallError {
            #expect(error.kind == .host)
        }
        do {
            _ = try await cancelled.enumerate(entry, operation: operation, sourceEpoch: Self.epoch)
            Issue.record("Cancellation propagates")
        } catch is CancellationError {
            // Cancellation is not a plugin failure.
        }
    }
}
