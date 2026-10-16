import XCTest
@testable import Ito

final class ReaderSessionEffectPlanTests: XCTestCase {
    func testMangaReadInvocationOrderAndRepeatedChapterSuppressionBoundary() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let function = try XCTUnwrap(
            source.slice(from: "func markChapterRead", to: "// MARK: - Image prefetch")
        )

        assertOrdered(
            [
                "dependencies.history.recordManga(",
                "guard !plan.asynchronousEffects.isEmpty else { return }",
                "markedChapterKeys.insert(chapter.key)",
                "let task = Task {",
                "progress.markChapterRead(",
                "tracker.updateMangaProgress("
            ],
            in: function
        )
    }

    func testMangaInitialLoadMarksAfterPublishingPagesAndBeforeAdjacentPrefetch() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let function = try XCTUnwrap(
            source.slice(from: "private func completeMainLoad", to: "private func failMainLoad")
        )

        assertOrdered(
            ["pagedPages = sorted", "loadPhase = .content", "markChapterRead(chapter)", "beginAdjacentChapterPrefetch()"],
            in: function
        )
    }

    func testMangaContinuousAndCachedPagedTransitionsPreserveMutationEffectOrder() throws {
        let source = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let continuous = try XCTUnwrap(
            source.slice(from: "func continuousPageAppeared", to: "private func pagedGoToChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: flatPage.chapter)", "markChapterRead(flatPage.chapter)"],
            in: continuous
        )

        let paged = try XCTUnwrap(
            source.slice(from: "private func pagedGoToChapter", to: "private func continuousGoToChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: chapter)", "pagedPages = cached", "pagedIndex = 0", "markChapterRead(chapter)", "beginAdjacentChapterPrefetch()"],
            in: paged
        )

        let direct = try XCTUnwrap(
            source.slice(from: "private func continuousGoToChapter", to: "private func changeCurrentChapter")
        )
        assertOrdered(
            ["changeCurrentChapter(to: chapter)", "segments = []", "loadPhase = .loading", "beginMainLoad(for: chapter)"],
            in: direct
        )
    }

    func testNovelReadAndTransitionInvocationOrderIsPreserved() throws {
        let source = try sourceFile("Ito/ViewModels/NovelReaderViewModel.swift")
        let tracking = try XCTUnwrap(
            source.slice(from: "func markChapterRead", to: "private func isCurrentEffect")
        )
        assertOrdered(
            [
                "dependencies.history.recordNovel(",
                "let task = Task {",
                "progress.markNovelChapterRead(",
                "tracker.updateNovelProgress("
            ],
            in: tracking
        )

        let scrolling = try XCTUnwrap(
            source.slice(from: "func continuousChapterTitleAppeared", to: "func pagedChapterChanged")
        )
        assertOrdered(
            [
                "changeCurrentChapter(to: loadedChapter.chapter)",
                "markChapterRead(loadedChapter.chapter)"
            ],
            in: scrolling
        )

        let navigation = try XCTUnwrap(
            source.slice(from: "func goToChapter", to: "func retry()")
        )
        assertOrdered(
            [
                "changeCurrentChapter(to: chapter)",
                "loadedChapters = []",
                "loadPhase = .loading",
                "invalidateContentOperations()",
                "beginMainLoad(for: chapter)"
            ],
            in: navigation
        )
    }

    func testDiscordInitialChangeAndDisappearTimerSemanticsAreLocked() throws {
        let manga = try sourceFile("Ito/ViewModels/MangaReaderViewModel.swift")
        let appear = try XCTUnwrap(
            manga.slice(from: "func appear()", to: "func disappear()")
        )
        XCTAssertTrue(appear.contains("resetTimer: true"))
        let change = try XCTUnwrap(
            manga.slice(from: "private func changeCurrentChapter", to: "// MARK: - Main chapter loading")
        )
        XCTAssertTrue(change.contains("resetTimer: false"))
        let disappear = try XCTUnwrap(
            manga.slice(from: "func disappear()", to: "// MARK: - Viewer and settings")
        )
        XCTAssertTrue(disappear.contains("clearMangaReaderPresence()"))

        let novel = try sourceFile("Ito/ViewModels/NovelReaderViewModel.swift")
        let novelAppear = try XCTUnwrap(
            novel.slice(from: "func appear()", to: "func disappear()")
        )
        XCTAssertTrue(novelAppear.contains("resetTimer: true"))
        let novelChange = try XCTUnwrap(
            novel.slice(from: "private func changeCurrentChapter", to: "// MARK: - Main chapter load")
        )
        XCTAssertTrue(novelChange.contains("resetTimer: false"))
        let novelDisappear = try XCTUnwrap(
            novel.slice(from: "func disappear()", to: "// MARK: - Chapter navigation")
        )
        XCTAssertTrue(novelDisappear.contains("clearNovelReaderPresence()"))
    }

    func testNovelPagingChangesChapterBeforePrefetchWithoutMovingTrackingIntoPager() throws {
        let source = try sourceFile("Ito/Views/Reader/NovelPagingReaderView.swift")
        let callback = try XCTUnwrap(
            source.slice(from: "onPageChanged: { newIndex in", to: "onLoadNextChapter()")
        )

        assertOrdered(["currentChapter = newChap", "onLoadNextChapter()"], in: callback)
        XCTAssertFalse(callback.contains("updateTracking"))
        XCTAssertFalse(callback.contains("HistoryManager"))
        XCTAssertFalse(callback.contains("ReadProgressManager"))
    }

    func testMangaNovelAndVideoReadersAdoptScreenOwnedViewModels() throws {
        let manga = try sourceFile("Ito/Views/Reader/ReaderView.swift")
        XCTAssertTrue(manga.contains("@StateObject private var viewModel: MangaReaderViewModel"))
        XCTAssertTrue(manga.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertFalse(manga.contains("ReaderViewModel("))

        let novel = try sourceFile("Ito/Views/Reader/NovelReaderView.swift")
        XCTAssertTrue(novel.contains("@StateObject private var viewModel: NovelReaderViewModel"))
        XCTAssertTrue(novel.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertFalse(novel.contains("ReaderViewModel("))

        let video = try sourceFile("Ito/Views/Reader/VideoPlayerView.swift")
        XCTAssertTrue(video.contains("@StateObject private var viewModel: VideoPlayerViewModel"))
        XCTAssertTrue(video.contains("StateObject(wrappedValue: viewModel)"))
        XCTAssertFalse(video.contains("ReaderViewModel("))

        let paging = try sourceFile("Ito/Views/Reader/NovelPagingReaderView.swift")
        XCTAssertFalse(paging.contains("ReaderViewModel("))
        XCTAssertFalse(paging.contains("@StateObject"))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Ito/ViewModels/ReaderViewModel.swift").path
            )
        )
    }

    func testPureChapterReadPlanLocksHistoryProgressAndTrackerOrder() {
        let plan = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: 12.75,
            titleOrKey: "ignored",
            alreadyMarked: false
        )

        XCTAssertEqual(plan.synchronousEffects, [.recordHistory])
        XCTAssertEqual(
            plan.asynchronousEffects,
            [.markLocalProgress, .updateTracker(progress: 12)]
        )
    }

    func testPureChapterReadPlanLocksFallbackNumberExtraction() {
        let decimalTitle = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: nil,
            titleOrKey: "Chapter 12.5 Extra",
            alreadyMarked: false
        )
        let noNumber = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: nil,
            titleOrKey: "Epilogue",
            alreadyMarked: false
        )

        XCTAssertEqual(
            decimalTitle.asynchronousEffects,
            [.markLocalProgress, .updateTracker(progress: 125)]
        )
        XCTAssertEqual(noNumber.asynchronousEffects, [.markLocalProgress])
    }

    func testPureChapterReadPlanKeepsRepeatedMangaHistoryButSuppressesAsyncEffects() {
        let plan = ReaderSessionEffectPlan.chapterRead(
            chapterNumber: 3,
            titleOrKey: "Chapter 3",
            alreadyMarked: true
        )

        XCTAssertEqual(plan.synchronousEffects, [.recordHistory])
        XCTAssertEqual(plan.asynchronousEffects, [])
    }

    private func assertOrdered(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for fragment in fragments {
            guard let range = source.range(of: fragment, range: lowerBound..<source.endIndex) else {
                return XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
            }
            lowerBound = range.upperBound
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testsFile = URL(fileURLWithPath: #filePath)
        let root = testsFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.lowerBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.upperBound])
    }
}
