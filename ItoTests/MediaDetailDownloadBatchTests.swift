import XCTest
import ito_runner
@testable import Ito

/// The series details' batch downloads: presets that queue at once or show a preview first, the scanlator
/// choice and what it remembers, the saved-only rows, the entire-series summary and the offline tap.
@MainActor
final class MediaDetailDownloadBatchTests: XCTestCase {
    private static let pluginID = "plugin.test"
    private static let identity = MediaIdentity(pluginId: pluginID, canonicalMediaId: "series-1", mediaKind: .manga)

    /// The chapter list the route's loader returns, so a test can change what the next refresh brings.
    final class Catalog {
        var chapters: [Chapter]
        init(_ chapters: [Chapter]) { self.chapters = chapters }
    }

    struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let downloads: MediaDetailDownloadsFake
        let messages: MediaDetailMessageSpy
        let progress: MediaDetailProgressFake
        let library: MediaDetailLibraryFake
        let connectivity: ConnectivityFake
        let catalog: Catalog
        let relink: MediaDetailRelinkFake
    }

    // MARK: - One tap or a preview

    func testAPlanWithNothingToConfirmQueuesAtOnceAndSaysSo() async {
        let subject = await makeSubject(chapters: Self.numbered(1...5))

        await subject.viewModel.downloadBatch.startDownload(.next).value

        XCTAssertNil(subject.viewModel.downloadSheet)
        let request = subject.downloads.batchRequests.first
        XCTAssertEqual(subject.downloads.batchRequests.count, 1)
        XCTAssertEqual(request?.chapters.map(\.key), ["c1"])
        XCTAssertEqual(request?.preset, .next)
        XCTAssertEqual(request?.catalogDigest, subject.viewModel.catalogDigest)
        XCTAssertEqual(request?.canonicalMediaId, "series-1")
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 1, alreadyStored: 0)])
    }

    func testAlreadySavedChaptersCountTowardTheRangeAndAreNotQueuedAgain() async {
        let subject = await makeSubject(chapters: Self.numbered(21...25))
        for key in ["c21", "c22", "c23", "c24"] { subject.downloads.set(.downloaded, chapterKey: key) }

        await subject.viewModel.downloadBatch.startDownload(.next5).value

        XCTAssertEqual(subject.downloads.batchRequests.first?.chapters.map(\.key), ["c25"])
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 1, alreadyStored: 4)])
    }

    func testAPresetWithNothingNewTellsTheUserInsteadOfQueueing() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2))
        for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }

        await subject.viewModel.downloadBatch.startDownload(.next5).value

        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertNil(subject.viewModel.downloadSheet)
        XCTAssertEqual(subject.messages.messages, [.nothingToDownload])
    }

    func testALargeBatchWaitsInAPreviewAndQueuesOnlyWhenConfirmed() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...12).reversed())

        await subject.viewModel.downloadBatch.startDownload(.all).value

        let preview = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty, "A large batch is never queued before the user confirms")
        XCTAssertEqual(preview.toQueue.count, 12)
        XCTAssertEqual(preview.catalogDigest, subject.viewModel.catalogDigest)

        await subject.viewModel.downloadBatch.confirmDownloadPreview().value

        XCTAssertNil(subject.viewModel.downloadSheet)
        let request = try XCTUnwrap(subject.downloads.batchRequests.first)
        XCTAssertEqual(request.preset, .all)
        // Reading order, whatever order the source listed the chapters in.
        XCTAssertEqual(request.chapters.map(\.key), (1...12).map { "c\($0)" })
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 12, alreadyStored: 0)])
    }

    func testAPlanWithAnIssueShowsAPreviewEvenWhenSmall() async throws {
        let chapters = [
            Chapter(key: "c1", chapter: 1),
            Chapter(key: "c2", chapter: 2, paywalled: true),
            Chapter(key: "c3", chapter: 3)
        ]
        let subject = await makeSubject(chapters: chapters)

        await subject.viewModel.downloadBatch.startDownload(.next5).value

        let preview = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertEqual(preview.toQueue.map(\.key), ["c1", "c3"])
        XCTAssertEqual(preview.locked.map(\.key), ["c2"])
        XCTAssertTrue(preview.issues.contains(.lockedGap))
    }

    func testThePreviewNamesFreeSpaceWhenTheDeviceReportsIt() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.capacity = 5_000_000
        let subject = await makeSubject(chapters: Self.numbered(1...12), downloads: downloads)

        await subject.viewModel.downloadBatch.startDownload(.all).value
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.downloadBatch.availableBytes, 5_000_000)
    }

    func testDismissingThePreviewQueuesNothing() async {
        let subject = await makeSubject(chapters: Self.numbered(1...12))
        await subject.viewModel.downloadBatch.startDownload(.all).value

        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.confirmDownloadPreview().value

        XCTAssertNil(subject.viewModel.downloadSheet)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
    }

    // MARK: - The chapter list changes under a preview

    func testAChangedChapterListReplacesAnOpenPreviewAndQueuesTheNewPlan() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...12))
        await subject.viewModel.downloadBatch.startDownload(.all).value
        let before = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertFalse(before.listChanged)

        subject.catalog.chapters = Self.numbered(1...13)
        await subject.viewModel.refresh()

        let after = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertNotEqual(after.id, before.id)
        XCTAssertNotEqual(after.catalogDigest, before.catalogDigest)
        XCTAssertEqual(after.catalogDigest, subject.viewModel.catalogDigest)
        XCTAssertTrue(after.listChanged, "The user is told the list changed")
        XCTAssertEqual(after.toQueue.count, 13)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)

        await subject.viewModel.downloadBatch.confirmDownloadPreview().value

        let request = try XCTUnwrap(subject.downloads.batchRequests.first)
        XCTAssertEqual(request.chapters.count, 13)
        XCTAssertEqual(request.catalogDigest, after.catalogDigest)
    }

    func testARefreshThatLeavesTheChaptersAloneKeepsThePreview() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...12))
        await subject.viewModel.downloadBatch.startDownload(.all).value
        let before = try XCTUnwrap(Self.preview(of: subject.viewModel))

        await subject.viewModel.refresh()

        XCTAssertEqual(Self.preview(of: subject.viewModel), before)
    }

    // MARK: - Scanlators

    func testACatalogWithSeveralScanlatorsAsksWhichToFollowBeforeAnyPlan() async throws {
        let subject = await makeSubject(chapters: Self.twoScanlators())

        await subject.viewModel.downloadBatch.startDownload(.next).value

        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            return XCTFail("The chooser comes first")
        }
        XCTAssertEqual(presentation.preset, .next)
        XCTAssertTrue(presentation.remember)
        XCTAssertEqual(Set(presentation.options.map(\.ref.name)), ["A", "B"])
        XCTAssertEqual(presentation.options.first { $0.ref.name == "A" }?.chapterCount, 3)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
    }

    func testAChosenScanlatorFiltersThePlanAndOtherUploadsInRangeAreOfferedNotQueued() async throws {
        let subject = await makeSubject(chapters: Self.twoScanlators())
        subject.progress.lastRead[Self.identity] = "a3"
        subject.progress.readChapterIDs[Self.identity] = ["a3"]
        let choice = EditionSelection.scanlators([ScanlatorRef(name: "A", binding: .exactIDless)])

        await subject.viewModel.downloadBatch.applyEditionChoice(choice, remember: false, then: .next5).value

        let preview = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertTrue(preview.toQueue.isEmpty)
        XCTAssertTrue(preview.issues.contains(.selectionExhausted))
        XCTAssertEqual(preview.alternatives.map(\.key), ["b4", "b5"])

        await subject.viewModel.downloadBatch.confirmDownloadPreview(including: ["b4"]).value

        let request = try XCTUnwrap(subject.downloads.batchRequests.first)
        XCTAssertEqual(request.chapters.map(\.key), ["b4"], "A ticked upload is queued; an unticked one never is")
        XCTAssertEqual(request.selection, try choice.storageData())
    }

    func testRememberStoresTheChoiceAndALaterVisitFollowsItWithoutAsking() async throws {
        let downloads = MediaDetailDownloadsFake()
        let first = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        let choice = EditionSelection.scanlators([ScanlatorRef(name: "B", binding: .exactIDless)])

        await first.viewModel.downloadBatch.applyEditionChoice(choice, remember: true, then: nil).value

        XCTAssertEqual(downloads.storedPreferences[Self.identity], choice)
        XCTAssertNil(first.viewModel.downloadSheet)

        let second = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        await second.viewModel.downloadBatch.startDownload(.next).value

        XCTAssertFalse(Self.isChooser(second.viewModel.downloadSheet), "A remembered choice is not asked for again")
        let request = try XCTUnwrap(downloads.batchRequests.first)
        XCTAssertEqual(request.selection, try choice.storageData())
        XCTAssertEqual(request.chapters.map(\.key), ["b1"])
    }

    func testAChoiceMadeWithRememberOffAppliesToThatBatchOnlyAndLeavesTheSessionAlone() async throws {
        let downloads = MediaDetailDownloadsFake()
        let first = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        await first.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertTrue(Self.isChooser(first.viewModel.downloadSheet))

        await first.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: false, then: .next).value

        // This batch follows the choice; several uploads share a number, so it waits in a preview.
        XCTAssertEqual(Self.preview(of: first.viewModel)?.selection, .allUploads)
        // Nothing else changed: no stored choice, no remembered choice, and the summary still follows the list.
        XCTAssertTrue(downloads.storedPreferences.isEmpty)
        XCTAssertEqual(first.viewModel.downloadBatch.remembered, .none)
        XCTAssertEqual(first.viewModel.downloadBatch.rememberedSelection, .sourceList)

        // The next preset asks again, here and on the next visit.
        first.viewModel.downloadBatch.dismissDownloadSheet()
        await first.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertTrue(Self.isChooser(first.viewModel.downloadSheet))
        let second = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        await second.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertTrue(Self.isChooser(second.viewModel.downloadSheet))
    }

    func testAChoiceThatCannotBeRememberedWaitsForExplicitBatchOnlyConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.preferenceWriteFailure = MediaDetailTestFailure.expected
        let subject = await makeSubject(chapters: Self.numbered(1...3), downloads: downloads)

        await subject.viewModel.downloadBatch.applyEditionChoice(.sourceList, remember: true, then: .next).value

        XCTAssertEqual(subject.messages.messages.first, .editionChoiceNotRemembered)
        XCTAssertTrue(downloads.batchRequests.isEmpty, "A failed durable approval never becomes batch-only consent")
        XCTAssertEqual(subject.viewModel.downloadBatch.remembered, .none, "A choice that was not stored is not remembered")
        XCTAssertTrue(Self.isChooser(subject.viewModel.downloadSheet))
        await subject.viewModel.downloadBatch.applyEditionChoice(.sourceList, remember: false, then: .next).value
        XCTAssertEqual(downloads.batchRequests.count, 1)
    }

    func testAChoiceFromTheScanlatorsEntryIsAlwaysRememberedAndFailureIsReportedAsNotSaved() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertFalse(presentation.offersRemember, "There is no batch to apply an unremembered choice to")

        // Even asked not to remember, a choice with no batch behind it is stored.
        await subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: false, then: nil).value
        XCTAssertEqual(downloads.storedPreferences[Self.identity], .allUploads)

        downloads.preferenceWriteFailure = MediaDetailTestFailure.expected
        await subject.viewModel.downloadBatch.applyEditionChoice(.sourceList, remember: true, then: nil).value

        XCTAssertEqual(subject.messages.messages, [.editionChoiceNotSaved])
        XCTAssertTrue(Self.isChooser(subject.viewModel.downloadSheet))
        XCTAssertEqual(subject.viewModel.downloadBatch.rememberedSelection, .allUploads, "The stored choice stands")
    }

    func testAChoiceTheWriteOfWhichOutlivesAnIdentityChangeSaysNothingAboutTheNewSeries() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.preferenceWriteFailure = MediaDetailTestFailure.expected
        downloads.holdsPreferenceWrites = true
        let target = Manga(key: "series-2", title: "Series Two", chapters: Self.numbered(1...2))
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads, relinkTargets: [target])
        let write = subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: true, then: nil)
        await waitUntil { downloads.pendingPreferenceWriteCount == 1 }

        subject.viewModel.openRelink()
        await subject.viewModel.performRelink(with: target)
        downloads.releasePreferenceWrites()
        await write.value

        XCTAssertEqual(subject.viewModel.mediaIdentity.canonicalMediaId, "series-2")
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertNil(subject.viewModel.downloadSheet)
    }

    func testAnUnreadableStoredChoiceNeverSwitchesEditionsSilently() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.preferenceReadFailure = SeriesEditionPreferenceError.unreadable
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        XCTAssertEqual(subject.viewModel.downloadBatch.remembered, .unreadable)

        await subject.viewModel.downloadBatch.startDownload(.next).value

        // Nothing is planned from the source's list: the chooser opens with the warning and nothing is queued.
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertEqual(presentation.storedChoiceProblem, .unreadable)
        XCTAssertEqual(presentation.preset, .next)
        XCTAssertTrue(presentation.remember, "A choice that cannot be read is replaced by default")
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertTrue(downloads.storedPreferences.isEmpty)
        XCTAssertTrue(subject.messages.messages.isEmpty, "The sheet carries the warning")
    }

    func testATransientReadErrorIsNotCorruptionAndNeverSwitchesEditionsSilentlyEither() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.preferenceReadFailure = MediaDetailTestFailure.expected
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        XCTAssertEqual(subject.viewModel.downloadBatch.remembered, .unknown, "A read that failed leaves the state unknown")

        await subject.viewModel.downloadBatch.startDownload(.next).value

        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertEqual(presentation.storedChoiceProblem, .readFailed)
        XCTAssertFalse(presentation.remember, "What is stored may be fine, so it is not replaced unless asked")
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertTrue(downloads.storedPreferences.isEmpty)
        XCTAssertEqual(downloads.preferenceReadCount, 2, "The next preset reads again")

        // Once the store answers, the stored choice is used and nothing is asked.
        downloads.preferenceReadFailure = nil
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.startDownload(.next).value
        guard case .chooser(let afterRecovery)? = subject.viewModel.downloadSheet else { return XCTFail("No choice is stored, so it asks") }
        XCTAssertNil(afterRecovery.storedChoiceProblem)
    }

    func testWithOneScanlatorAnUnknownChoiceAlwaysOpensAPreviewAndSaysWhy() async throws {
        for (failure, expected) in [
            (SeriesEditionPreferenceError.unreadable as Error, MediaDetailMessage.editionChoiceUnreadable),
            (MediaDetailTestFailure.expected as Error, MediaDetailMessage.editionChoiceReadFailed(reviewing: true))
        ] {
            let downloads = MediaDetailDownloadsFake()
            downloads.preferenceReadFailure = failure
            let subject = await makeSubject(chapters: Self.numbered(1...3), downloads: downloads)

            await subject.viewModel.downloadBatch.startDownload(.next).value

            let preview = try XCTUnwrap(Self.preview(of: subject.viewModel), "A plan that would queue at once is previewed instead")
            XCTAssertEqual(preview.selection, .sourceList)
            XCTAssertEqual(preview.toQueue.map(\.key), ["c1"])
            XCTAssertTrue(downloads.batchRequests.isEmpty)
            XCTAssertEqual(subject.messages.messages, [expected])
        }
    }

    func testTheScanlatorsEntryOpensWithTheWarningForAnUnreadableChoiceAndDoesNotOpenOnAFailedRead() async throws {
        let unreadable = MediaDetailDownloadsFake()
        unreadable.preferenceReadFailure = SeriesEditionPreferenceError.unreadable
        let first = await makeSubject(chapters: Self.twoScanlators(), downloads: unreadable)
        await first.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = first.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertEqual(presentation.storedChoiceProblem, .unreadable)
        XCTAssertEqual(presentation.initialSelection, .sourceList)

        // A transient failure cannot be told from a fine stored choice, and this entry always stores.
        let transient = MediaDetailDownloadsFake()
        transient.preferenceReadFailure = MediaDetailTestFailure.expected
        let second = await makeSubject(chapters: Self.twoScanlators(), downloads: transient)
        await second.viewModel.downloadBatch.openEditionChooser().value
        XCTAssertNil(second.viewModel.downloadSheet)
        XCTAssertEqual(second.messages.messages, [.editionChoiceReadFailed(reviewing: false)])

        // The read is tried again, so a recovered store opens normally.
        transient.preferenceReadFailure = nil
        await second.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let retried)? = second.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertNil(retried.storedChoiceProblem)
    }

    func testASecondConfirmOnTheSameChoiceSheetIsNotActedOn() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)

        let first = subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: true, then: nil)
        XCTAssertTrue(subject.viewModel.downloadBatch.isApplyingChoice, "Set before anything is awaited")
        let second = subject.viewModel.downloadBatch.applyEditionChoice(.sourceList, remember: true, then: nil)
        await second.value
        await waitUntil { downloads.pendingPreferenceWriteCount == 1 }
        downloads.holdsPreferenceWrites = false
        downloads.releasePreferenceWrites()
        await first.value

        XCTAssertEqual(downloads.preferenceWriteCount, 1)
        XCTAssertEqual(downloads.storedPreferences[Self.identity], .allUploads, "The first choice stands")
        XCTAssertFalse(subject.viewModel.downloadBatch.isApplyingChoice)
    }

    func testAChoiceIsNotWrittenForASeriesThatLeftTheLibraryMeanwhile() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)

        let apply = subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: true, then: nil)
        subject.library.publish(records: [], hasCustomCategories: false)
        await apply.value

        XCTAssertEqual(downloads.preferenceWriteCount, 0)
        XCTAssertTrue(downloads.storedPreferences.isEmpty)
        XCTAssertFalse(subject.viewModel.downloadBatch.isApplyingChoice)
    }

    func testTheScanlatorsEntryWaitsForTheStoredChoiceBeforeBuildingTheChooser() async throws {
        let downloads = MediaDetailDownloadsFake()
        let stored = EditionSelection.scanlators([ScanlatorRef(name: "B", binding: .exactIDless)])
        let seeded = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads)
        await seeded.viewModel.downloadBatch.applyEditionChoice(stored, remember: true, then: nil).value
        downloads.holdsPreferenceReads = true
        let subject = await makeSubject(chapters: Self.twoScanlators(), downloads: downloads, awaitsLoads: false)
        await waitUntil { downloads.pendingPreferenceReadCount == 1 }

        let opening = subject.viewModel.downloadBatch.openEditionChooser()
        await Task.yield()

        XCTAssertNil(subject.viewModel.downloadSheet, "The chooser does not open on the default while the choice is read")
        downloads.holdsPreferenceReads = false; downloads.releasePreferenceReads()
        await opening.value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else { return XCTFail("The chooser opens") }
        XCTAssertEqual(presentation.initialSelection, stored)
    }

    func testAnEmptyScanlatorSetIsNotAChoice() async {
        let subject = await makeSubject(chapters: Self.twoScanlators())

        await subject.viewModel.downloadBatch.applyEditionChoice(.scanlators([]), remember: true, then: .all).value

        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertTrue(subject.downloads.storedPreferences.isEmpty)
    }

    func testTheScanlatorsMenuItemOpensTheChooserWithoutAPreset() async throws {
        let subject = await makeSubject(chapters: Self.twoScanlators())

        await subject.viewModel.downloadBatch.openEditionChooser().value

        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            return XCTFail("Scanlators… opens the chooser")
        }
        XCTAssertNil(presentation.preset)
    }

    // MARK: - Failed jobs

    func testAFailedJobHoldsItsPositionButOpensAPreviewAndIsNotCountedAsQueued() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...3))
        subject.downloads.set(.failed(.network), chapterKey: "c1")

        await subject.viewModel.downloadBatch.startDownload(.next5).value

        let preview = try XCTUnwrap(Self.preview(of: subject.viewModel))
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty, "A failed row is never queued without the user looking")
        XCTAssertEqual(preview.failedCount, 1)
        XCTAssertEqual(preview.queuedCount, 0)
        XCTAssertEqual(preview.storedCount, 0)
        XCTAssertEqual(preview.toQueue.map(\.key), ["c2", "c3"])

        await subject.viewModel.downloadBatch.confirmDownloadPreview().value

        XCTAssertEqual(subject.downloads.batchRequests.first?.chapters.map(\.key), ["c2", "c3"])
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 2, alreadyStored: 0)])
    }

    func testQueuedAndSavedRowsStillCountAndDoNotForceAPreview() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...3))
        subject.downloads.set(.queued, chapterKey: "c1")
        subject.downloads.set(.downloaded, chapterKey: "c2")

        await subject.viewModel.downloadBatch.startDownload(.next5).value

        XCTAssertNil(subject.viewModel.downloadSheet)
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 1, alreadyStored: 2)])
    }

    // MARK: - One batch at a time

    func testASecondBatchWaitsWhileOneIsBeingQueuedAndThePreviewStaysOpen() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsBatches = true
        let subject = await makeSubject(chapters: Self.numbered(1...12), downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        let confirming = subject.viewModel.downloadBatch.confirmDownloadPreview()
        await waitUntil { downloads.pendingBatchCount == 1 }
        XCTAssertTrue(subject.viewModel.downloadBatch.isEnqueuing)

        // Another preset and another confirm do nothing while the first is queued.
        await subject.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertEqual(downloads.batchRequests.count, 1)

        downloads.holdsBatches = false
        downloads.releaseBatches()
        await confirming.value
        XCTAssertFalse(subject.viewModel.downloadBatch.isEnqueuing)

        await subject.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertEqual(downloads.batchRequests.count, 2, "The menu works again once the batch is queued")
    }

    // MARK: - Titles and names

    func testPreviewRowsAreNamedLikeTheReaderNamesChapters() async throws {
        let chapters = (1...12).map { Chapter(key: "c\($0)", title: $0 == 1 ? "Opening" : nil, chapter: Double($0) + ($0 == 2 ? 0.5 : 0)) }
        let subject = await makeSubject(chapters: chapters)

        await subject.viewModel.downloadBatch.startDownload(.all).value

        let rows = try XCTUnwrap(Self.preview(of: subject.viewModel)).toQueue
        XCTAssertEqual(rows.first { $0.key == "c1" }?.title, "Opening")
        XCTAssertEqual(rows.first { $0.key == "c2" }?.title, ReaderChapterTitle.text(title: nil, number: 2.5))
        XCTAssertEqual(rows.first { $0.key == "c3" }?.title, ReaderChapterTitle.text(title: nil, number: 3))
    }

    func testAnEmptyScanlatorNameIsShownAsNoGroup() {
        XCTAssertNil(ScanlatorOption(ref: ScanlatorRef(name: ""), chapterCount: 2).displayName)
        XCTAssertNil(ScanlatorOption(ref: ScanlatorRef(name: nil), chapterCount: 2).displayName)
        XCTAssertEqual(ScanlatorOption(ref: ScanlatorRef(name: "A"), chapterCount: 2).displayName, "A")
    }

    // MARK: - Preset mapping

    func testEveryPresetMapsToItsStoredBatchPresetAndFreezesTheSelectionBytes() async throws {
        let selection = EditionSelection.scanlators([ScanlatorRef(name: "A", binding: .exactIDless)])
        for preset in DownloadPreset.allCases {
            let subject = await makeSubject(chapters: Self.numbered(1...3, scanlator: "A"))
            await subject.viewModel.downloadBatch.applyEditionChoice(selection, remember: false, then: nil).value

            await subject.viewModel.downloadBatch.startDownload(preset).value

            let request = try XCTUnwrap(subject.downloads.batchRequests.first, "\(preset) queues a batch")
            XCTAssertEqual(request.preset, DownloadBatchPreset(rawValue: preset.rawValue), "\(preset)")
            XCTAssertEqual(DownloadBatchPreset(preset), request.preset)
            XCTAssertEqual(request.selection, try selection.storageData(), "\(preset)")
            let stored = try JSONDecoder().decode(EditionSelection.self, from: request.selection)
            XCTAssertEqual(stored, selection)
        }
    }

    func testTheSourceListSelectionIsStoredAsItsExactBytes() async throws {
        let subject = await makeSubject(chapters: Self.numbered(1...3))

        await subject.viewModel.downloadBatch.startDownload(.all).value

        XCTAssertEqual(subject.downloads.batchRequests.first?.selection, try EditionSelection.sourceList.storageData())
        XCTAssertEqual(DownloadBatchRecord.sourceListSelection, Data(#"{"formatVersion":1,"kind":"sourceList"}"#.utf8))
    }

    func testARefusedBatchIsReportedAndNothingElseIsClaimed() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.batchOutcome = .refused(.unavailable)
        let subject = await makeSubject(chapters: Self.numbered(1...3), downloads: downloads)

        await subject.viewModel.downloadBatch.startDownload(.next).value

        XCTAssertEqual(subject.messages.messages, [.downloadActionFailed])
    }

    func testABatchTheStoreFoundAlreadySavedCountsThemAsSaved() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.batchOutcome = DownloadBatchOutcome(queued: 2, alreadySaved: 1, alreadyQueued: 1)
        let subject = await makeSubject(chapters: Self.numbered(1...3), downloads: downloads)

        await subject.viewModel.downloadBatch.startDownload(.all).value

        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 2, alreadyStored: 2)])
    }

    // MARK: - Offline tap

    func testTappingAChapterThatIsNotDownloadedWhileOfflineSaysSoInsteadOfLoading() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2), offline: true)
        subject.downloads.set(.downloaded, chapterKey: "c1")

        subject.viewModel.selectChapter(Chapter(key: "c2", chapter: 2))

        XCTAssertEqual(subject.messages.messages, [.chapterNotDownloaded])
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testADamagedOrQueuedChapterIsNotDownloadedEither() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2), offline: true)
        subject.downloads.set(.damaged, chapterKey: "c1")
        subject.downloads.set(.queued, chapterKey: "c2")

        subject.viewModel.selectChapter(Chapter(key: "c1", chapter: 1))
        subject.viewModel.selectChapter(Chapter(key: "c2", chapter: 2))

        XCTAssertEqual(subject.messages.messages, [.chapterNotDownloaded, .chapterNotDownloaded])
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testADownloadedChapterOpensWhileOffline() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2), offline: true)
        subject.downloads.set(.downloaded, chapterKey: "c1")

        subject.viewModel.selectChapter(Chapter(key: "c1", chapter: 1))

        XCTAssertNotNil(subject.viewModel.readerDestination)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testAChapterOpensWhileOnlineWhetherOrNotItIsDownloaded() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2))

        subject.viewModel.selectChapter(Chapter(key: "c2", chapter: 2))

        XCTAssertNotNil(subject.viewModel.readerDestination)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testGoingOnlineAgainOpensChaptersAgain() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2), offline: true)
        subject.connectivity.set(isOffline: false)

        subject.viewModel.selectChapter(Chapter(key: "c2", chapter: 2))

        XCTAssertNotNil(subject.viewModel.readerDestination)
    }

    // MARK: - Saved-only rows in a runner route

    func testSavedEditionsTheListNoLongerHasAppearAfterTheListedChaptersWithTheirOwnMarker() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7), try Self.inventoryRow("c1", number: 1)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)

        subject.downloads.set(.downloaded, chapterKey: "c1")
        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1", "gone"])
        let gone = try XCTUnwrap(subject.viewModel.displayedChapters.last)
        XCTAssertTrue(subject.viewModel.isSavedOnlyRow(gone))
        XCTAssertFalse(subject.viewModel.isSavedOnlyRow(Chapter(key: "c1", chapter: 1)))
        // It can be read from this device and deleted, but there is no online copy to read.
        XCTAssertEqual(subject.viewModel.downloadActions(for: gone), [.delete])
        XCTAssertEqual(subject.viewModel.downloadActions(for: Chapter(key: "c1", chapter: 1)), [.readOnlineThisTime, .delete])
        // The list itself is untouched: absence from it is not deletion.
        XCTAssertEqual(subject.viewModel.media.chapterList?.map(\.key), ["c1", "c2"])
    }

    func testASavedOnlyRowFollowsTheReadFilterLikeAnyRow() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)
        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()
        subject.progress.readChapterIDs[Self.identity] = ["gone"]

        subject.viewModel.filterOption = .unread
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1"])
        subject.viewModel.filterOption = .read
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["gone"])
    }

    func testADeletedSavedOnlyEditionLeavesTheListAtOnce() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)
        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()
        XCTAssertEqual(subject.viewModel.displayedChapters.count, 3)

        subject.downloads.set(nil, chapterKey: "gone")

        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1"])
    }

    func testAnEditionTheSourceListsAgainStopsBeingSavedOnly() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)
        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()

        subject.catalog.chapters = Self.numbered(1...2) + [Chapter(key: "gone", chapter: 7)]
        await subject.viewModel.refresh()

        XCTAssertEqual(subject.viewModel.displayedChapters.filter { subject.viewModel.isSavedOnlyRow($0) }.count, 0)
        XCTAssertEqual(subject.viewModel.displayedChapters.filter { $0.key == "gone" }.count, 1)
    }

    func testDamagedOrQueuedCopiesAndListedCopiesAddNoRows() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)

        subject.downloads.set(.damaged, chapterKey: "gone")
        subject.downloads.set(.downloaded, chapterKey: "c1")

        XCTAssertEqual(inventory.readCount, 0, "Nothing is asked of the inventory unless a verified copy is unlisted")
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1"])
    }

    func testTheSavedOnlyRouteNeverMergesAgainBecauseItsListAlreadyHoldsThem() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), runnerRoute: false, inventory: inventory)

        subject.downloads.set(.downloaded, chapterKey: "gone")

        XCTAssertEqual(inventory.readCount, 0)
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1"])
    }

    func testARelinkedSeriesShowsItsOwnSavedOnlyRowsAndNoneOfTheOldOne() async throws {
        let inventory = InventoryBox(rows: [
            try Self.inventoryRow("gone-old", number: 7, series: "series-1"),
            try Self.inventoryRow("gone-new", number: 8, series: "series-2")
        ])
        let target = Manga(key: "series-2", title: "Series Two", chapters: [Chapter(key: "n1", chapter: 1), Chapter(key: "n2", chapter: 2)])
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory, relinkTargets: [target])
        subject.downloads.set(.downloaded, chapterKey: "gone-old")
        await subject.viewModel.downloadBatch.settleForTesting()
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1", "gone-old"])
        let newIdentity = MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-2", mediaKind: .manga)
        subject.downloads.set(.downloaded, chapterKey: "gone-new", media: newIdentity)

        subject.viewModel.openRelink()
        await subject.viewModel.performRelink(with: target)
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.mediaIdentity, newIdentity)
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["n2", "n1", "gone-new"])
        XCTAssertEqual(inventory.requested.last, newIdentity, "The inventory is asked for the series shown now")
        XCTAssertFalse(subject.viewModel.displayedChapters.contains { $0.key == "gone-old" })
    }

    func testSavedOnlyRowsShowEvenWhenTheListIsEmptyAndCountBesideTheListedChapters() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(chapters: [], inventory: inventory)

        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertTrue(subject.viewModel.media.chapterList?.isEmpty ?? true)
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["gone"])
        XCTAssertEqual(subject.viewModel.savedOnlyChapterCount, 1)

        let withList = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory)
        withList.downloads.set(.downloaded, chapterKey: "gone")
        await withList.viewModel.downloadBatch.settleForTesting()
        XCTAssertEqual(withList.viewModel.savedOnlyChapterCount, 1)
        XCTAssertEqual(withList.viewModel.displayedChapters.count, 3)
    }

    func testARelinkToASeriesWithTheSameChapterListStillLoadsItsSavedOnlyRows() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone-new", number: 8, series: "series-2")])
        // The same chapters under another key: the catalog digest does not change across the relink.
        let target = Manga(key: "series-2", title: "Series", chapters: Self.numbered(1...2))
        let subject = await makeSubject(chapters: Self.numbered(1...2), inventory: inventory, relinkTargets: [target])
        let before = subject.viewModel.catalogDigest
        let newIdentity = MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-2", mediaKind: .manga)
        subject.downloads.set(.downloaded, chapterKey: "gone-new", media: newIdentity)

        subject.viewModel.openRelink()
        await subject.viewModel.performRelink(with: target)
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.catalogDigest, before)
        XCTAssertEqual(subject.viewModel.mediaIdentity, newIdentity)
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["c2", "c1", "gone-new"])
    }

    func testAnEmptyListWithASavedOnlyRowStillOffersTheRelinkEntry() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let target = Manga(key: "series-2", title: "Series Two", chapters: Self.numbered(1...2))
        let subject = await makeSubject(chapters: [], inventory: inventory, relinkTargets: [target])

        subject.downloads.set(.downloaded, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["gone"])
        XCTAssertTrue(subject.viewModel.offersRelinkBanner, "The saved-only list does not hide the way to link a source")

        // With chapters listed, or a series that is not saved or cannot search, there is no offer.
        let listed = await makeSubject(chapters: Self.numbered(1...2), relinkTargets: [target])
        let unsaved = await makeSubject(chapters: [], saved: false, relinkTargets: [target])
        let noSearch = await makeSubject(chapters: [])
        XCTAssertFalse(listed.viewModel.offersRelinkBanner)
        XCTAssertFalse(unsaved.viewModel.offersRelinkBanner)
        XCTAssertFalse(noSearch.viewModel.offersRelinkBanner)
    }

    // MARK: - Header summary

    func testTheSummaryCountsSavedChaptersWhenTheCatalogIsNotKnownToBeComplete() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = await makeSubject(chapters: Self.numbered(1...3), basis: Self.basis(
            scope: .unknown, completeness: .unknown, refreshedAt: now
        ))
        subject.downloads.set(.downloaded, chapterKey: "c1")
        subject.downloads.set(.downloaded, chapterKey: "c2")
        subject.downloads.set(.downloaded, chapterKey: "c3")

        // Every chapter is saved, but nobody confirmed the catalog: a count, never "entire series".
        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(3))
    }

    func testTheSummaryClaimsTheEntireSeriesOnlyForACompleteFreshMatchingCatalogWithEveryRowSaved() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chapters = Self.numbered(1...3) + [Chapter(key: "locked", chapter: 4, paywalled: true)]
        let saved = Self.facts(1...3) + [ChapterFacts(key: "locked", number: 4, isLocked: true)]
        let subject = await makeSubject(chapters: chapters, basis: Self.basis(
            scope: .allEligible, completeness: .complete, refreshedAt: now.addingTimeInterval(-3600), catalog: saved
        ))
        for key in ["c1", "c2", "c3"] { subject.downloads.set(.downloaded, chapterKey: key) }

        // The locked row cannot be saved and does not count against the claim.
        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .entireSeries)

        subject.downloads.set(nil, chapterKey: "c3")
        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(2))
    }

    func testTheSummaryNeedsTheCatalogToCoverEverythingNotJustWhatTheSourceShows() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .visible, completeness: .complete, refreshedAt: now
        ))
        for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }

        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(2))
    }

    func testTheSummaryNeedsAChapterRowEvenForACompleteCatalog() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .allEligible, completeness: .complete, rowCount: 0, refreshedAt: now
        ))
        for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }

        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(2))
    }

    func testTheSummaryExpiresAfterSevenDaysAndWhenThePayloadIsNotTheOneSaved() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week: TimeInterval = 7 * 24 * 60 * 60
        let stale = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .allEligible, completeness: .complete, refreshedAt: now.addingTimeInterval(-week - 1)
        ))
        let edge = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .allEligible, completeness: .complete, refreshedAt: now.addingTimeInterval(-week)
        ))
        let replaced = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .allEligible, completeness: .complete, refreshedAt: now, currentPayload: String(repeating: "b", count: 64)
        ))
        for subject in [stale, edge, replaced] {
            for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }
        }

        XCTAssertEqual(stale.viewModel.offlineCoverage(now: now), .saved(2))
        XCTAssertEqual(edge.viewModel.offlineCoverage(now: now), .entireSeries)
        XCTAssertEqual(replaced.viewModel.offlineCoverage(now: now), .saved(2))
    }

    func testTheSummaryCountsEditionsTheListNoLongerHas() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2))
        subject.downloads.set(.downloaded, chapterKey: "c1")
        subject.downloads.set(.downloaded, chapterKey: "gone")

        XCTAssertEqual(subject.viewModel.offlineCoverage(), .saved(2))
    }

    func testAFreshRefreshRereadsWhatTheSavedDetailsSay() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = await makeSubject(chapters: Self.numbered(1...2))
        for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }
        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(2))

        subject.library.snapshotBasis = Self.basis(scope: .allEligible, completeness: .complete, refreshedAt: now)
        subject.viewModel.downloadBatch.loadCoverageBasis()
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .entireSeries)
    }

    func testTheClaimComesFromTheSavedCatalogNotFromTheShorterListALaterLoadReturned() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The saved catalog has three chapters and is complete; a later load returned only two and its
        // replacement was rejected, so the saved payload is still the longer one.
        let subject = await makeSubject(chapters: Self.numbered(1...2), basis: Self.basis(
            scope: .allEligible, completeness: .complete, refreshedAt: now, catalog: Self.facts(1...3)
        ))
        for key in ["c1", "c2"] { subject.downloads.set(.downloaded, chapterKey: key) }

        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .saved(2))

        subject.downloads.set(.downloaded, chapterKey: "c3")
        XCTAssertEqual(subject.viewModel.offlineCoverage(now: now), .entireSeries)
    }

    func testTheHeaderSummaryCountsSavedQueuedFailedAndDamagedEditionsAndTheirSize() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.storedBytes = 340_000_000
        let subject = await makeSubject(chapters: Self.numbered(1...6), downloads: downloads)

        subject.downloads.set(.downloaded, chapterKey: "c1")
        subject.downloads.set(.downloaded, chapterKey: "c2")
        subject.downloads.set(.queued, chapterKey: "c3")
        subject.downloads.set(.downloading(completed: 1, total: 4), chapterKey: "c4")
        subject.downloads.set(.waiting(.meteredNetwork), chapterKey: "c5")
        subject.downloads.set(.failed(.network), chapterKey: "c6")
        subject.downloads.set(.damaged, chapterKey: "gone")
        await subject.viewModel.downloadBatch.settleForTesting()

        XCTAssertEqual(subject.viewModel.downloadBatch.summary, SeriesDownloadSummary(saved: 2, queued: 3, failed: 1, damaged: 1))
        XCTAssertEqual(subject.viewModel.downloadBatch.storedBytes, 340_000_000)
    }

    func testAQueuedOnlyOrFailedOnlySeriesStillHasASummaryButNoEntireSeriesClaim() async {
        let queued = await makeSubject(chapters: Self.numbered(1...2))
        queued.downloads.set(.queued, chapterKey: "c1")
        let failed = await makeSubject(chapters: Self.numbered(1...2))
        failed.downloads.set(.failed(.network), chapterKey: "c1")

        XCTAssertEqual(queued.viewModel.downloadBatch.summary, SeriesDownloadSummary(queued: 1))
        XCTAssertEqual(failed.viewModel.downloadBatch.summary, SeriesDownloadSummary(failed: 1))
        XCTAssertNil(queued.viewModel.downloadBatch.storedBytes, "Nothing stored occupies nothing")
        XCTAssertNil(queued.viewModel.offlineCoverage())
        XCTAssertNil(failed.viewModel.offlineCoverage())
    }

    func testASeriesWithNoStateHasAnEmptySummary() async {
        let subject = await makeSubject(chapters: Self.numbered(1...2))

        XCTAssertTrue(subject.viewModel.downloadBatch.summary.isEmpty)
    }

    func testTheSummaryFollowsTheStoreAndTheSizeIsReadAgainWhenCopiesChange() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.storedBytes = 10
        let subject = await makeSubject(chapters: Self.numbered(1...3), downloads: downloads)
        subject.downloads.set(.downloaded, chapterKey: "c1")
        await subject.viewModel.downloadBatch.settleForTesting()
        XCTAssertEqual(subject.viewModel.downloadBatch.storedBytes, 10)

        downloads.storedBytes = 25
        subject.downloads.set(.downloaded, chapterKey: "c2")
        await subject.viewModel.downloadBatch.settleForTesting()
        XCTAssertEqual(subject.viewModel.downloadBatch.storedBytes, 25)

        subject.downloads.set(nil, chapterKey: "c1")
        subject.downloads.set(nil, chapterKey: "c2")
        await subject.viewModel.downloadBatch.settleForTesting()
        XCTAssertNil(subject.viewModel.downloadBatch.storedBytes)
        XCTAssertTrue(subject.viewModel.downloadBatch.summary.isEmpty)
    }

    // MARK: - Release: downloads unavailable

    func testWithoutDownloadsNothingOfTheBatchSurfaceExists() async throws {
        let inventory = InventoryBox(rows: [try Self.inventoryRow("gone", number: 7)])
        let subject = await makeSubject(
            chapters: Self.twoScanlators(),
            downloads: MediaDetailDownloadsFake(isAvailable: false),
            offline: true,
            inventory: inventory,
            basis: Self.basis(scope: .allEligible, completeness: .complete, refreshedAt: Date())
        )
        subject.downloads.set(.downloaded, chapterKey: "a1")
        subject.downloads.set(.downloaded, chapterKey: "gone")

        XCTAssertFalse(subject.viewModel.showsBatchDownloadControls)
        XCTAssertEqual(subject.viewModel.catalogDigest, "")
        XCTAssertNil(subject.viewModel.offlineCoverage())
        XCTAssertTrue(subject.viewModel.downloadBatch.summary.isEmpty)
        XCTAssertNil(subject.viewModel.downloadBatch.storedBytes)
        XCTAssertFalse(subject.viewModel.showsDownloadControls)
        XCTAssertEqual(subject.viewModel.displayedChapters.count, subject.viewModel.media.chapterList?.count)
        XCTAssertEqual(inventory.readCount, 0)

        await subject.viewModel.downloadBatch.startDownload(.all).value
        await subject.viewModel.downloadBatch.openEditionChooser().value
        await subject.viewModel.downloadBatch.applyEditionChoice(.allUploads, remember: true, then: .all).value
        await subject.viewModel.downloadBatch.confirmDownloadPreview().value

        XCTAssertNil(subject.viewModel.downloadSheet)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
        XCTAssertTrue(subject.downloads.storedPreferences.isEmpty)
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertTrue(subject.library.snapshotBasisRequests.isEmpty, "The details are not read for a summary nobody shows")

        // Offline taps keep behaving as they did before downloads existed: the reader opens.
        subject.viewModel.selectChapter(Chapter(key: "a2", chapter: 2, scanlator: "A"))
        XCTAssertNotNil(subject.viewModel.readerDestination)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testTheUnavailableSeamRefusesEveryBatchOperation() async {
        let downloads = UnavailableMediaDetailDownloads()
        let request = DownloadBatchRequest(
            pluginId: Self.pluginID,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            entry: .manga(Manga(key: "series-1", title: "Series")),
            seriesTitle: "Series",
            preset: .next,
            selection: DownloadBatchRecord.sourceListSelection,
            catalogDigest: nil,
            chapters: [Chapter(key: "c1", chapter: 1)]
        )

        let outcome = await downloads.enqueueBatch(request)
        let preference = try? await downloads.editionPreference(for: Self.identity)
        let capacity = await downloads.availableCapacity()
        let bytes = await downloads.storedByteCount(for: Self.identity)
        var wrote = true
        do { try await downloads.setEditionPreference(.sourceList, for: Self.identity, sourceEpoch: "epoch") } catch { wrote = false }

        XCTAssertEqual(outcome, .refused(.unavailable))
        XCTAssertNil(preference)
        XCTAssertNil(capacity)
        XCTAssertNil(bytes)
        XCTAssertFalse(wrote)
    }

    func testAnUnsavedSeriesAndASavedOnlyRouteOfferNoBatchControls() async {
        let unsaved = await makeSubject(chapters: Self.numbered(1...3), saved: false)
        let savedOnly = await makeSubject(chapters: Self.numbered(1...3), runnerRoute: false)
        let empty = await makeSubject(chapters: [])

        XCTAssertFalse(unsaved.viewModel.showsBatchDownloadControls)
        XCTAssertFalse(savedOnly.viewModel.showsBatchDownloadControls)
        XCTAssertFalse(empty.viewModel.showsBatchDownloadControls)
        await unsaved.viewModel.downloadBatch.startDownload(.all).value
        XCTAssertTrue(unsaved.downloads.batchRequests.isEmpty)
    }

    func testAnAnimeSeriesNeverOffersBatchDownloads() async {
        let anime = Anime(key: "anime-1", title: "Anime", episodes: [Anime.Episode(key: "e1", title: "e1", episode: 1)])
        let context = MediaDetailRouteContext<Anime>(
            loadDetails: { media, _ in media },
            searchForRelink: nil,
            makeReaderDestination: { _, _ in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(Manga(key: "unused", title: "Unused")),
                    chapter: Chapter(key: "unused", chapter: 1)
                )
            }
        )
        var dependencies = Self.dependencies(
            library: MediaDetailLibraryFake(state: MediaDetailLibraryState(
                records: [MediaDetailLibraryRecord(itemID: "anime-1", pluginID: Self.pluginID, mediaKind: .anime)],
                hasCustomCategories: false
            )),
            progress: MediaDetailProgressFake()
        )
        dependencies.downloads = MediaDetailDownloadsFake()
        let viewModel = MediaDetailViewModel(
            media: anime,
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: dependencies,
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        await viewModel.refresh()

        XCTAssertFalse(viewModel.showsBatchDownloadControls)
        XCTAssertEqual(viewModel.catalogDigest, "")
    }

    // MARK: - Messages

    func testTheQueuedMessageNamesWhatWasAlreadyStoredOnlyWhenThereWasSomething() {
        let withStored = AppMessageKind.mediaDetailDownloadsQueued(queued: 3, alreadyStored: 2).presentation
        let without = AppMessageKind.mediaDetailDownloadsQueued(queued: 3, alreadyStored: 0).presentation

        XCTAssertEqual(withStored.style, .success)
        XCTAssertFalse(withStored.title.isEmpty)
        XCTAssertNotNil(withStored.detail)
        XCTAssertNil(without.detail)
    }

    func testTheBatchMessagesReachTheMessageCenterAsTheirOwnKinds() {
        let center = AppMessageCenter()
        let presenter = AppMessageMediaDetailPresenter(messageCenter: center)

        presenter.present(.downloadsQueued(queued: 2, alreadyStored: 1))
        presenter.present(.nothingToDownload)
        presenter.present(.editionChoiceNotRemembered)
        presenter.present(.editionChoiceNotSaved)
        presenter.present(.editionChoiceUnreadable)

        var kinds: [AppMessageKind] = []
        while let message = center.currentMessage {
            kinds.append(message.kind)
            center.dismiss(messageID: message.id)
        }
        XCTAssertEqual(kinds, [
            .mediaDetailDownloadsQueued(queued: 2, alreadyStored: 1),
            .mediaDetailNothingToDownload,
            .mediaDetailEditionChoiceNotRemembered,
            .mediaDetailEditionChoiceNotSaved,
            .mediaDetailEditionChoiceUnreadable
        ])
    }

    // MARK: - Subjects

    private static func numbered(_ range: ClosedRange<Int>, scanlator: String? = nil) -> [Chapter] {
        range.map { Chapter(key: "c\($0)", chapter: Double($0), scanlator: scanlator) }
    }

    /// A1–A3 and B1–B5 under one source: positions 4 and 5 exist only as B uploads.
    private static func twoScanlators() -> [Chapter] {
        (1...3).map { Chapter(key: "a\($0)", chapter: Double($0), scanlator: "A") }
            + (1...5).map { Chapter(key: "b\($0)", chapter: Double($0), scanlator: "B") }
    }

    private static func preview(of viewModel: MediaDetailViewModel<Manga>) -> DownloadPreview? {
        guard case .preview(let preview)? = viewModel.downloadSheet else { return nil }
        return preview
    }

    private static func isChooser(_ sheet: DownloadSheet?) -> Bool {
        if case .chooser? = sheet { return true }
        return false
    }

    private static let payloadDigest = String(repeating: "a", count: 64)

    private static func basis(
        scope: LibraryCatalogScope,
        completeness: LibraryCatalogCompleteness,
        rowCount: Int = 3,
        refreshedAt: Date,
        currentPayload: String = payloadDigest,
        catalog: [ChapterFacts] = facts(1...2)
    ) -> LibrarySnapshotBasis {
        let record = LibrarySnapshotStateRecord(
            pluginId: pluginID,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            payloadSHA256: payloadDigest,
            refreshedAt: refreshedAt,
            catalogScope: scope,
            catalogCompleteness: completeness,
            chapterRowCount: rowCount
        )
        return LibrarySnapshotBasis(snapshot: record.offlineSnapshot, currentPayloadSHA256: currentPayload, catalog: catalog)
    }

    /// The rows of a saved catalog numbered like `numbered(_:)`.
    private static func facts(_ range: ClosedRange<Int>) -> [ChapterFacts] {
        range.map { ChapterFacts(key: "c\($0)", number: Float($0)) }
    }

    private static func inventoryRow(_ key: String, number: Double, series: String = "series-1") throws -> DownloadedChapterRecord {
        DownloadedChapterRecord(
            pluginId: pluginID,
            mediaKind: .manga,
            canonicalMediaId: series,
            chapterKey: key,
            authorityScope: .publicUnscoped,
            versionId: UUID().uuidString,
            state: .verified,
            damageReason: nil,
            contentKind: .images,
            pageCount: 1,
            byteCount: 1,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: try JSONEncoder().encode(Chapter(key: key, chapter: number)),
            seriesTitle: "Series",
            sourceEpoch: nil,
            verifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Serves a fixed inventory by series and records which series it was asked for.
    final class InventoryBox {
        let rows: [DownloadedChapterRecord]
        private(set) var requested: [MediaIdentity] = []
        var readCount: Int { requested.count }
        init(rows: [DownloadedChapterRecord]) { self.rows = rows }
        func read(_ media: MediaIdentity) -> [DownloadedChapterRecord] {
            requested.append(media)
            return rows.filter { $0.canonicalMediaId == media.canonicalMediaId }
        }
    }

    private static func dependencies(
        library: MediaDetailLibraryFake,
        progress: MediaDetailProgressFake,
        relink: MediaDetailRelinkFake = MediaDetailRelinkFake()
    ) -> PreparedMediaDetailDependencies {
        PreparedMediaDetailDependencies(
            library: library,
            progress: progress,
            tracker: MediaDetailTrackerFake(),
            theme: MediaDetailThemeFake(),
            relink: relink,
            baseline: MediaDetailBaselineFake(),
            settings: MediaDetailSettingsFake(alwaysShowCategoryPicker: false, autoSyncTrackersToLocal: true),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake()
        )
    }

    /// Builds a screen and loads it. A runner route has a loader that returns `catalog`'s current chapters, so
    /// a test can change what the next refresh brings; a saved-only route has none.
    func makeSubject(
        chapters: [Chapter],
        saved: Bool = true,
        downloads: MediaDetailDownloadsFake = MediaDetailDownloadsFake(),
        runnerRoute: Bool = true,
        offline: Bool = false,
        inventory: InventoryBox? = nil,
        basis: LibrarySnapshotBasis? = nil,
        relinkTargets: [Manga] = [],
        awaitsLoads: Bool = true,
        downloadService: (any MediaDetailDownloadServing)? = nil
    ) async -> Subject {
        let catalog = Catalog(chapters)
        let library = MediaDetailLibraryFake(state: MediaDetailLibraryState(
            records: saved
                ? [MediaDetailLibraryRecord(itemID: "series-1", pluginID: Self.pluginID, mediaKind: .manga)]
                : [],
            hasCustomCategories: false
        ))
        library.snapshotBasis = basis
        let progress = MediaDetailProgressFake()
        let connectivity = ConnectivityFake(isOffline: offline)
        let messages = MediaDetailMessageSpy()
        let context = MediaDetailRouteContext<Manga>(
            // The series itself answers with the current catalog; a relink target is already hydrated.
            loadDetails: runnerRoute
                ? { requested, _ in
                    requested.key == "series-1"
                        ? Manga(key: "series-1", title: "Series", chapters: catalog.chapters)
                        : requested
                }
                : nil,
            searchForRelink: relinkTargets.isEmpty ? nil : { _, _ in relinkTargets },
            makeReaderDestination: { media, chapter in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(media),
                    chapter: chapter
                )
            },
            inventoryChapters: inventory.map { box in { box.read($0) } }
        )
        let relink = MediaDetailRelinkFake()
        var dependencies = Self.dependencies(library: library, progress: progress, relink: relink)
        dependencies.downloads = downloadService ?? downloads
        dependencies.connectivity = connectivity
        let viewModel = MediaDetailViewModel(
            media: Manga(key: "series-1", title: "Series", chapters: chapters),
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: dependencies,
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
        // A runner route loads its details; a saved-only route reads the saved ones.
        await viewModel.refresh()
        if !runnerRoute { viewModel.start() }
        if awaitsLoads { await viewModel.downloadBatch.settleForTesting() }
        messages.clear()
        return Subject(
            viewModel: viewModel,
            downloads: downloads,
            messages: messages,
            progress: progress,
            library: library,
            connectivity: connectivity,
            catalog: catalog,
            relink: relink
        )
    }
}
