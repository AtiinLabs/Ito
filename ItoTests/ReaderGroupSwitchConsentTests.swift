import XCTest
import ito_runner
@testable import Ito

@MainActor
final class ReaderGroupSwitchConsentTests: XCTestCase {
    private let pages = (0..<3).map { Page(index: Int32($0), content: .text("page")) }

    private func manga(
        _ chapters: [Chapter], enabled: Bool, viewer: Manga.Viewer = .Ltr, initial: Int = 0
    ) -> MangaReaderTestSubject {
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "series", title: "Series", viewer: viewer, chapters: chapters),
            initialChapter: chapters[initial]
        )
        subject.settings.askBeforeSwitchingGroups = enabled
        return subject
    }

    private func novel(_ chapters: [Chapter], enabled: Bool, initial: Int = 0) -> NovelReaderTestSubject {
        let subject = makeNovelReaderSubject(
            novel: Novel(key: "series", title: "Series", chapters: chapters), initialChapter: chapters[initial]
        )
        subject.settings.askBeforeSwitchingGroups = enabled
        return subject
    }

    func testMangaContinuousAppendCannotFetchUnapprovedNextGroup() async {
        let subject = manga([a, b], enabled: true, viewer: .Vertical)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.viewModel.appendNextChapter()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        XCTAssertEqual(subject.viewModel.segments.map(\.chapter.key), ["a"])
        XCTAssertNil(subject.viewModel.groupSwitchConsent, "Speculative append never presents a prompt")
    }

    func testNovelStaleSessionAndEpochRefuseNavigation() throws {
        for closesReader in [false, true] {
            let subject = novel([a, b], enabled: true)
            subject.viewModel.goToNextChapter()
            let pending = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
            if closesReader {
                subject.viewModel.disappear()
            } else {
                subject.progress.originatingEpoch = "another-account"
            }
            subject.viewModel.confirmGroupSwitch(pending.id)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
            XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        }
    }
    private var a: Chapter { Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "id-a") }
    private var b: Chapter { Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "id-b") }

    func testDefaultOffPreservesMangaPrefetchAndNextAcrossGroups() async {
        let subject = manga([a, b], enabled: false)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
        subject.viewModel.goToNextChapter()
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
    }

    func testEnabledSameIDRenamedGroupDoesNotPrompt() async {
        let renamed = Chapter(key: "next", chapter: 2, scanlator: "Renamed", scanlatorID: "id-a")
        let subject = manga([a, renamed], enabled: true)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.loader.enqueue(.pages(pages), for: "next")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        subject.viewModel.goToNextChapter()
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "next")
    }

    func testEnabledDifferentGroupCancelDoesNotMoveOrPrefetchThenConfirmOpensOnlyExactNext() async throws {
        let c = Chapter(key: "c", chapter: 3, scanlator: "C", scanlatorID: "id-c")
        let subject = manga([a, b, c], enabled: true)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        XCTAssertNil(subject.viewModel.chapterAfter(a))
        XCTAssertFalse(subject.viewModel.adjacentNeighborKeys.contains("b"))
        let position = subject.viewModel.pagedIndex
        let progressCount = subject.progress.requests.count
        subject.viewModel.setPagedIndex(pages.count)
        let cancelled = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
        subject.viewModel.cancelGroupSwitch()
        subject.viewModel.confirmGroupSwitch(cancelled.id)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.viewModel.pagedIndex, position)
        XCTAssertEqual(subject.progress.requests.count, progressCount)
        XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        subject.viewModel.goToNextChapter()
        subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
        XCTAssertEqual(subject.loader.callCount(for: "c"), 0)
    }

    func testStaleReaderSessionSettingsAndSourceEpochRefuseConfirmation() async throws {
        for invalidation in 0..<3 {
            let subject = manga([a, b], enabled: true)
            subject.viewModel.goToNextChapter()
            let consent = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
            switch invalidation {
            case 0: subject.viewModel.disappear(); subject.viewModel.appear()
            case 1: subject.settings.askBeforeSwitchingGroups = false; subject.settings.askBeforeSwitchingGroups = true
            default: subject.progress.originatingEpoch = "replaced-account"
            }
            subject.viewModel.confirmGroupSwitch(consent.id)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
            XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        }
    }

    func testUnknownRemoteEpochCannotAuthorizeSwitch() throws {
        let subject = manga([a, b], enabled: true)
        subject.progress.originatingEpoch = nil
        subject.viewModel.goToNextChapter()
        subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
    }

    func testNovelDefaultOffAndEnabledSameGroupKeepExistingContinuation() async {
        for enabled in [false, true] {
            let next = enabled ? Chapter(key: "b", chapter: 2, scanlator: "Rename", scanlatorID: "id-a") : b
            let subject = novel([a, next], enabled: enabled)
            subject.loader.enqueue(.pages(pages), for: "a")
            subject.loader.enqueue(.pages(pages), for: "b")
            subject.viewModel.start()
            await subject.viewModel.waitForAllOperationsForTesting()
            subject.viewModel.goToNextChapter()
            await subject.viewModel.waitForAllOperationsForTesting()
            XCTAssertNil(subject.viewModel.groupSwitchConsent)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        }
    }

    func testNovelSeamlessNeverPrefetchesUnapprovedGroupAndCancelRetainsPosition() async throws {
        let subject = novel([a, b], enabled: true)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        let loaded = try XCTUnwrap(subject.viewModel.loadedChapters.first)
        subject.viewModel.continuousPageAppeared(chapterID: loaded.id, pageIndex: 0)
        subject.viewModel.loadNextChapter(trigger: .seamless)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        let progressCount = subject.progress.requests.count
        subject.viewModel.goToNextChapter()
        let stale = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
        subject.viewModel.cancelGroupSwitch()
        subject.viewModel.confirmGroupSwitch(stale.id)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
        XCTAssertEqual(subject.viewModel.loadedChapters.map(\.chapter.key), ["a"])
        XCTAssertEqual(subject.progress.requests.count, progressCount)
        subject.viewModel.goToNextChapter()
        subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.loader.callCount(for: "b"), 1)
    }

    func testIDComparisonNeverUsesSharedLabelNumberOrTitle() {
        XCTAssertFalse(ReaderContinuationGroup(a).matches(ReaderContinuationGroup(Chapter(
            key: "other", title: a.title, chapter: 1, scanlator: "A", scanlatorID: "different"
        ))))
        XCTAssertFalse(ReaderContinuationGroup(a).matches(ReaderContinuationGroup(Chapter(key: "idless", scanlator: "A"))))
        XCTAssertTrue(ReaderContinuationGroup(id: nil, name: "Legacy").matches(.init(id: nil, name: "Legacy")))
        XCTAssertFalse(ReaderContinuationGroup(id: nil, name: "Legacy").matches(.init(id: nil, name: "Renamed")))
    }

    func testHistoryReferenceExactKeyWinsRenameAndMissingExactKeyRequiresUniqueRecordedID() {
        let reference = MediaDetailChapterReference(key: "old", number: 1, volume: nil, scanlator: "Old", scanlatorID: "id-a")
        let renamed = Chapter(key: "old", chapter: 99, scanlator: "New", scanlatorID: "id-new")
        XCTAssertEqual([renamed].chapter(matching: reference)?.key, "old")
        let sameID = Chapter(key: "new", chapter: 1, scanlator: "Renamed", scanlatorID: "id-a")
        let conflictingID = Chapter(key: "wrong", chapter: 1, scanlator: "Old", scanlatorID: "id-b")
        XCTAssertEqual([conflictingID, sameID].chapter(matching: reference)?.key, "new")
        XCTAssertNil([conflictingID].chapter(matching: reference))
        XCTAssertNil([sameID, Chapter(key: "extra", chapter: 1, scanlatorID: "id-a")].chapter(matching: reference))
    }

    // MARK: - Previous, locked and ID-preferred boundaries

    func testMangaPreviousAcrossGroupsIsGatedNeverPrefetchedAndConfirmOpensOnlyThatChapter() async throws {
        for viewer in [Manga.Viewer.Ltr, .Vertical] {
            let subject = manga([a, b], enabled: true, viewer: viewer, initial: 1)
            subject.loader.enqueue(.pages(pages), for: "b")
            subject.loader.enqueue(.pages(pages), for: "a")
            subject.viewModel.start()
            await subject.viewModel.waitForTestingOperations()
            subject.viewModel.prependPreviousChapter()
            await subject.viewModel.waitForTestingOperations()
            XCTAssertEqual(subject.loader.callCount(for: "a"), 0, "Neither prefetch nor prepend crosses an unapproved group")
            XCTAssertNil(subject.viewModel.chapterBefore(b))
            XCTAssertEqual(boundaryLabel(subject.viewModel.boundaryBefore(b)), "groupConsent:a")
            XCTAssertNil(subject.viewModel.groupSwitchConsent)

            let progressCount = subject.progress.requests.count
            subject.viewModel.goToPreviousChapter()
            let cancelled = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
            XCTAssertEqual(cancelled.direction, .previous)
            subject.viewModel.cancelGroupSwitch()
            subject.viewModel.confirmGroupSwitch(cancelled.id)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
            XCTAssertEqual(subject.progress.requests.count, progressCount)
            XCTAssertEqual(subject.loader.callCount(for: "a"), 0)

            subject.viewModel.goToPreviousChapter()
            subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
            await subject.viewModel.waitForTestingOperations()
            XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
            XCTAssertEqual(subject.loader.callCount(for: "a"), 1)
        }
    }

    func testMangaPagedSwipeBackAcrossGroupsAsksAndLeavesPositionUntilConfirmed() async throws {
        let subject = manga([a, b], enabled: true, initial: 1)
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        let position = subject.viewModel.pagedIndex
        subject.viewModel.setPagedIndex(-1)
        let pending = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
        XCTAssertTrue(pending.opensAtEnd)
        XCTAssertEqual(subject.viewModel.pagedIndex, position)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
    }

    func testNovelPreviousAcrossGroupsAsksAndConfirmOpensOnlyThatChapter() async throws {
        let subject = novel([a, b], enabled: true, initial: 1)
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertNil(subject.viewModel.previousChapter)
        subject.viewModel.goToPreviousChapter()
        let pending = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
        subject.viewModel.cancelGroupSwitch()
        subject.viewModel.confirmGroupSwitch(pending.id)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "b")
        XCTAssertEqual(subject.loader.callCount(for: "a"), 0)
        subject.viewModel.goToPreviousChapter()
        subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
        await subject.viewModel.waitForAllOperationsForTesting()
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
    }

    func testDefaultOffPreviousAcrossGroupsKeepsExistingBehavior() async {
        let subject = manga([a, b], enabled: false, initial: 1)
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.viewModel.chapterBefore(b)?.key, "a")
        subject.viewModel.goToPreviousChapter()
        await subject.viewModel.waitForTestingOperations()
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
    }

    func testLockedBoundaryIsNeverSkippedOrTurnedIntoConsent() {
        var lockedB = b
        lockedB.paywalled = true
        let later = Chapter(key: "later", chapter: 3, scanlator: "A", scanlatorID: "id-a")
        for isAvailable in [false, true] {
            let availability = ReaderAvailabilityFake(isAvailable: isAvailable)
            let subject = makeMangaReaderSubject(
                manga: Manga(key: "series", title: "Series", chapters: [a, lockedB, later]),
                initialChapter: a, offlineAvailability: availability
            )
            subject.settings.askBeforeSwitchingGroups = true
            XCTAssertEqual(boundaryLabel(subject.viewModel.boundaryAfter(a)), "locked:b")
            subject.viewModel.goToNextChapter()
            XCTAssertNil(subject.viewModel.groupSwitchConsent)
            XCTAssertEqual(subject.viewModel.currentChapter.key, "a")
            XCTAssertEqual(subject.loader.callCount(for: "b"), 0)
            XCTAssertEqual(subject.loader.callCount(for: "later"), 0)
        }
    }

    func testEnabledSourcePreferenceUsesGroupIDBeforeNameAndOffKeepsNameOrder() {
        let other = Chapter(key: "x", chapter: 2, scanlator: "X", scanlatorID: "id-x")
        let renamed = Chapter(key: "y", chapter: 2, scanlator: "Renamed", scanlatorID: "id-a")
        XCTAssertEqual(
            boundaryLabel(manga([a, other, renamed], enabled: true).viewModel.boundaryAfter(a)),
            "chapter:y"
        )
        XCTAssertEqual(
            boundaryLabel(manga([a, other, renamed], enabled: false).viewModel.boundaryAfter(a)),
            "chapter:x"
        )
    }
}
