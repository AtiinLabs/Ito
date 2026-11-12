import XCTest
import ito_runner
@testable import Ito

extension MediaDetailViewModelTests {
    func testResumeDefaultOffPreservesCrossGroupDestination() {
        let a = Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "a-id")
        let b = Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "b-id")
        let subject = makeMangaSubject(media: manga(chapters: [a, b]))
        subject.progress.lastRead[subject.viewModel.mediaIdentity] = "a"
        subject.progress.readChapterIDs[subject.viewModel.mediaIdentity] = ["a"]
        subject.viewModel.resumeReading()
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        guard case .pages(_, _, _, _, let chapter) = subject.viewModel.readerDestination else { return XCTFail("Expected reader") }
        XCTAssertEqual(chapter.key, "b")
    }

    func testEnabledResumeSameGroupRenameDoesNotPrompt() async {
        let a = Chapter(key: "a", chapter: 1, scanlator: "Old", scanlatorID: "same")
        let b = Chapter(key: "b", chapter: 2, scanlator: "Renamed", scanlatorID: "same")
        let subject = makeMangaSubject(media: manga(chapters: [a, b]))
        subject.settings.askBeforeSwitchingGroups = true
        subject.progress.lastRead[subject.viewModel.mediaIdentity] = "a"
        subject.progress.readChapterIDs[subject.viewModel.mediaIdentity] = ["a"]
        subject.viewModel.resumeReading()
        await subject.viewModel.waitForContinuationForTesting()
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        guard case .pages(_, _, _, _, let chapter) = subject.viewModel.readerDestination else { return XCTFail("Expected reader") }
        XCTAssertEqual(chapter.key, "b")
    }

    func testEnabledResumeDifferentGroupCancelThenConfirmLeavesProgressAndLinksUntouched() async throws {
        let a = Chapter(key: "a", chapter: 1, scanlator: "Shared", scanlatorID: "a-id")
        let b = Chapter(key: "b", chapter: 2, scanlator: "Shared", scanlatorID: "b-id")
        let subject = makeMangaSubject(media: manga(chapters: [a, b]))
        subject.settings.askBeforeSwitchingGroups = true
        let identity = subject.viewModel.mediaIdentity
        subject.progress.lastRead[identity] = "a"
        subject.progress.readChapterIDs[identity] = ["a"]
        subject.viewModel.resumeReading()
        await subject.viewModel.waitForContinuationForTesting()
        let stale = try XCTUnwrap(subject.viewModel.groupSwitchConsent)
        XCTAssertNil(subject.viewModel.readerDestination)
        subject.viewModel.cancelGroupSwitch()
        subject.viewModel.confirmGroupSwitch(stale.id)
        XCTAssertNil(subject.viewModel.readerDestination)
        XCTAssertEqual(subject.progress.lastRead[identity], "a")
        XCTAssertEqual(subject.progress.readChapterIDs[identity], ["a"])
        subject.viewModel.resumeReading()
        await subject.viewModel.waitForContinuationForTesting()
        subject.viewModel.confirmGroupSwitch(try XCTUnwrap(subject.viewModel.groupSwitchConsent).id)
        guard case .pages(_, _, _, _, let chapter) = subject.viewModel.readerDestination else { return XCTFail("Expected confirmed reader") }
        XCTAssertEqual(chapter.key, "b")
        XCTAssertEqual(subject.progress.lastRead[identity], "a")
        XCTAssertEqual(subject.progress.readChapterIDs[identity], ["a"])
    }

    func testLateHistoryResponseCannotNavigateOrPromptAnotherSeries() async {
        let history = SuspendedContinuationHistory()
        let b = Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "b-id")
        let subject = makeMangaSubject(media: manga(chapters: [b]), history: history)
        subject.settings.askBeforeSwitchingGroups = true
        let identity = subject.viewModel.mediaIdentity
        subject.progress.lastRead[identity] = "missing-exact-key"
        subject.viewModel.resumeReading()
        await history.waitForRequest()
        let oldResponse = subject.viewModel.continuationTaskForTesting
        XCTAssertEqual(history.request?.0, identity)
        XCTAssertEqual(history.request?.1, "missing-exact-key")
        subject.route.loadResponses = [.value(manga(key: "other-series", chapters: [b]))]
        await subject.viewModel.refresh()
        history.resolve(.init(id: "a-id", name: "A"))
        await oldResponse?.value
        XCTAssertEqual(subject.viewModel.media.key, "other-series")
        XCTAssertNil(subject.viewModel.readerDestination)
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
    }

    func testResumeRecoversOnlyExactHistoricalGroupAndPrefersItsIDAfterRename() async {
        let history = SuspendedContinuationHistory()
        let wrong = Chapter(key: "wrong", chapter: 2, scanlator: "Old", scanlatorID: "other-id")
        let renamed = Chapter(key: "renamed", chapter: 2, scanlator: "New", scanlatorID: "recorded-id")
        let subject = makeMangaSubject(media: manga(chapters: [wrong, renamed]), history: history)
        subject.settings.askBeforeSwitchingGroups = true
        subject.progress.lastRead[subject.viewModel.mediaIdentity] = "old-exact-key"
        subject.viewModel.resumeReading()
        await history.waitForRequest()
        let response = subject.viewModel.continuationTaskForTesting
        history.resolve(.init(id: "recorded-id", name: "Old"))
        await response?.value
        XCTAssertNil(subject.viewModel.groupSwitchConsent)
        guard case .pages(_, _, _, _, let chapter) = subject.viewModel.readerDestination else { return XCTFail("Expected historical group's reader") }
        XCTAssertEqual(chapter.key, "renamed")
    }
}

@MainActor
private final class SuspendedContinuationHistory: MediaDetailHistoryReading {
    private var result: CheckedContinuation<ReaderContinuationGroup?, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private(set) var request: (MediaIdentity, String)?

    func recordedGroup(media: MediaIdentity, chapterKey: String) async throws -> ReaderContinuationGroup? {
        request = (media, chapterKey)
        return await withCheckedContinuation { continuation in
            result = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitForRequest() async {
        if result != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func resolve(_ group: ReaderContinuationGroup?) {
        result?.resume(returning: group)
        result = nil
    }
}
