import Combine
import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class TrackerLocalSyncIntegrationTests: XCTestCase {
    private static let pluginID = "test.plugin"

    private struct TestHarness {
        let database: TestDatabase
        let progressManager: ReadProgressManager
        let viewModel: MediaDetailViewModel<Manga>
        let route: MediaRouteHarness<Manga>
        let settings: MediaDetailSettingsFake
        let messages: MediaDetailMessageSpy

        func cleanup() {
            database.cleanup()
        }
    }

    private func makeHarness(
        media: Manga,
        autoSyncTrackersToLocal: Bool = true
    ) throws -> TestHarness {
        let database = try TestDatabase()
        let progressManager = ReadProgressManager(dbPool: database.dbPool)
        let route = MediaRouteHarness<Manga>()
        let runner = ItoRunner()
        let library = MediaDetailLibraryFake()
        let tracker = MediaDetailTrackerFake()
        let theme = MediaDetailThemeFake()
        let relink = MediaDetailRelinkFake()
        let baseline = MediaDetailBaselineFake()
        let settings = MediaDetailSettingsFake(autoSyncTrackersToLocal: autoSyncTrackersToLocal)
        let metadata = MediaDetailPluginMetadataFake()
        let discord = MediaDetailDiscordFake()
        let messages = MediaDetailMessageSpy()

        let routeContext = MediaDetailRouteContext<Manga>(
            loadDetails: { try await route.load($0) },
            searchForRelink: { try await route.search($0) },
            makeReaderDestination: { parent, selected in
                .reading(
                    selected,
                    of: .manga(parent),
                    runner: runner,
                    pluginID: Self.pluginID
                )
            }
        )

        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: routeContext,
            dependencies: PreparedMediaDetailDependencies(
                library: library,
                progress: progressManager,
                tracker: tracker,
                theme: theme,
                relink: relink,
                baseline: baseline,
                settings: settings,
                pluginMetadata: metadata,
                discord: discord
            ),
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )

        return TestHarness(
            database: database,
            progressManager: progressManager,
            viewModel: viewModel,
            route: route,
            settings: settings,
            messages: messages
        )
    }

    private func makeManga(
        key: String = "manga-sync-1",
        title: String = "Tracker Sync Manga",
        chapters: [Manga.Chapter]
    ) -> Manga {
        Manga(key: key, title: title, chapters: chapters)
    }

    private func chapter(_ number: Float?, key: String? = nil, title: String? = nil) -> Manga.Chapter {
        let resolvedKey = key ?? (number.map { "ch-\($0.formatted())" } ?? "ch-unnumbered")
        let resolvedTitle = title ?? (number.map { "Chapter \($0)" } ?? "Unnumbered Chapter")
        return Chapter(key: resolvedKey, title: resolvedTitle, chapter: number)
    }

    // MARK: - Integration Tests

    func testTrackerSyncMarksFractionalAndZeroChaptersAdvancesResumeAndSurvivesReload() async throws {
        // Chapters: 0, 0.5, 1, 1.5, 59, 60, 60.5, and unnumbered
        let chapters = [
            chapter(0),
            chapter(0.5),
            chapter(1),
            chapter(1.5),
            chapter(59),
            chapter(60),
            chapter(60.5),
            chapter(nil, key: "ch-special", title: "Special")
        ]
        let manga = makeManga(chapters: chapters)
        let harness = try makeHarness(media: manga)
        defer { harness.cleanup() }

        let mediaIdentity = harness.viewModel.mediaIdentity

        // Initial state before sync: resumeChapter should be chapter 0 (first unread)
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 0)
        XCTAssertEqual(harness.viewModel.resumeChapter?.key, "ch-0")

        // Trigger tracker sync up to chapter 60
        harness.viewModel.trackerDidSave(progress: 60)
        await harness.viewModel.waitForTrackerProgressForTesting()

        // Chapters <= 60 must be read: 0, 0.5, 1, 1.5, 59, 60
        for number: Float in [0, 0.5, 1, 1.5, 59, 60] {
            XCTAssertTrue(
                harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-\(number.formatted())", chapterNum: number),
                "Chapter \(number) should be marked read"
            )
            XCTAssertTrue(
                harness.viewModel.isRead(chapter(number)),
                "ViewModel should report chapter \(number) as read"
            )
        }

        // Chapters > 60 or unnumbered must remain unread: 60.5 and special
        XCTAssertFalse(
            harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-60.5", chapterNum: 60.5),
            "Chapter 60.5 must remain unread"
        )
        XCTAssertFalse(
            harness.viewModel.isRead(chapter(60.5)),
            "ViewModel should report chapter 60.5 as unread"
        )
        XCTAssertFalse(
            harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-special", chapterNum: nil),
            "Unnumbered chapter must remain unread"
        )
        XCTAssertFalse(
            harness.viewModel.isRead(chapter(nil, key: "ch-special")),
            "ViewModel should report unnumbered chapter as unread"
        )

        // Resume chapter advances past old fractions to chapter 60.5
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 60.5)
        XCTAssertEqual(harness.viewModel.resumeChapter?.key, "ch-60.5")

        // Unread filter displays only unread chapters (60.5 and unnumbered)
        harness.viewModel.filterOption = .unread
        let displayedUnreadKeys = harness.viewModel.displayedChapters.map(\.key)
        XCTAssertTrue(displayedUnreadKeys.contains("ch-60.5"))
        XCTAssertTrue(displayedUnreadKeys.contains("ch-special"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-0"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-0.5"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-1"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-1.5"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-59"))
        XCTAssertFalse(displayedUnreadKeys.contains("ch-60"))

        // Fresh ReadProgressManager reloaded from SQLite database verifies durability
        let reloadedManager = ReadProgressManager(dbPool: harness.database.dbPool)
        try await reloadedManager.reload()

        for number: Float in [0, 0.5, 1, 1.5, 59, 60] {
            XCTAssertTrue(
                reloadedManager.isRead(media: mediaIdentity, chapterId: "ch-\(number.formatted())", chapterNum: number),
                "Reloaded manager should report chapter \(number) as read"
            )
        }
        XCTAssertFalse(
            reloadedManager.isRead(media: mediaIdentity, chapterId: "ch-60.5", chapterNum: 60.5),
            "Reloaded manager should report chapter 60.5 as unread"
        )
        XCTAssertFalse(
            reloadedManager.isRead(media: mediaIdentity, chapterId: "ch-special", chapterNum: nil),
            "Reloaded manager should report unnumbered chapter as unread"
        )
    }

    func testTrackerSyncProgressZeroIsNoOpAndSubsequentPositiveProgressMarksZero() async throws {
        let chapters = [
            chapter(0),
            chapter(0.5),
            chapter(1),
            chapter(2)
        ]
        let manga = makeManga(chapters: chapters)
        let harness = try makeHarness(media: manga)
        defer { harness.cleanup() }

        let mediaIdentity = harness.viewModel.mediaIdentity

        // trackerDidSave with progress 0 is a NOOP (not started)
        harness.viewModel.trackerDidSave(progress: 0)
        await harness.viewModel.waitForTrackerProgressForTesting()

        // None of the chapters should be read
        for ch in chapters {
            XCTAssertFalse(
                harness.viewModel.isRead(ch),
                "Progress 0 must be a NOOP; chapter \(String(describing: ch.chapterNumber)) should not be read"
            )
            XCTAssertFalse(
                harness.progressManager.isRead(media: mediaIdentity, chapterId: ch.key, chapterNum: ch.chapterNumber),
                "Database should not have read marks for chapter \(String(describing: ch.chapterNumber))"
            )
        }
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 0)

        // Now save positive progress: progress 1
        harness.viewModel.trackerDidSave(progress: 1)
        await harness.viewModel.waitForTrackerProgressForTesting()

        // Positive eligible progress union marks whole numbers 1...Int(max) and available <= max (0, 0.5, 1)
        XCTAssertTrue(harness.viewModel.isRead(chapter(0)))
        XCTAssertTrue(harness.viewModel.isRead(chapter(0.5)))
        XCTAssertTrue(harness.viewModel.isRead(chapter(1)))
        XCTAssertFalse(harness.viewModel.isRead(chapter(2)))

        // Verify database directly
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-0", chapterNum: 0))
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-0.5", chapterNum: 0.5))
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-1", chapterNum: 1))
        XCTAssertFalse(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-2", chapterNum: 2))

        // Resume should advance to chapter 2
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 2)
    }

    func testDisabledTrackerAutoSyncLeavesLocalProgressUnchanged() async throws {
        let chapters = [
            chapter(0),
            chapter(0.5),
            chapter(1),
            chapter(2)
        ]
        let manga = makeManga(chapters: chapters)
        let harness = try makeHarness(media: manga, autoSyncTrackersToLocal: false)
        defer { harness.cleanup() }

        let mediaIdentity = harness.viewModel.mediaIdentity

        harness.viewModel.trackerDidSave(progress: 2)
        await harness.viewModel.waitForTrackerProgressForTesting()

        // Because autoSyncTrackersToLocal is false, nothing is synced
        for ch in chapters {
            XCTAssertFalse(
                harness.viewModel.isRead(ch),
                "Disabled autoSync must leave chapter \(String(describing: ch.chapterNumber)) unread"
            )
            XCTAssertFalse(
                harness.progressManager.isRead(media: mediaIdentity, chapterId: ch.key, chapterNum: ch.chapterNumber),
                "Database must not contain read record when autoSync is disabled"
            )
        }
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 0)
    }

    func testRepeatingSameProgressAfterRefreshAddsNewFractionalMarkers() async throws {
        // Initial chapters: whole numbers 1 and 2
        let initialChapters = [
            chapter(1),
            chapter(2)
        ]
        let initialManga = makeManga(chapters: initialChapters)
        let harness = try makeHarness(media: initialManga)
        defer { harness.cleanup() }

        let mediaIdentity = harness.viewModel.mediaIdentity

        // First tracker sync at progress 2
        harness.viewModel.trackerDidSave(progress: 2)
        await harness.viewModel.waitForTrackerProgressForTesting()

        XCTAssertTrue(harness.viewModel.isRead(chapter(1)))
        XCTAssertTrue(harness.viewModel.isRead(chapter(2)))

        // Refresh metadata from source: new fractional chapters 0, 0.5, 1.5 and new chapter 3 are introduced
        let updatedChapters = [
            chapter(0),
            chapter(0.5),
            chapter(1),
            chapter(1.5),
            chapter(2),
            chapter(2.5),
            chapter(3)
        ]
        let updatedManga = makeManga(chapters: updatedChapters)
        harness.route.loadResponses = [.value(updatedManga)]

        await harness.viewModel.refresh()
        XCTAssertEqual(harness.viewModel.media.chapterList?.count, updatedChapters.count)

        // Before repeating sync, the newly added fractions 0, 0.5, 1.5, 2.5 are not yet read
        XCTAssertFalse(harness.viewModel.isRead(chapter(0)))
        XCTAssertFalse(harness.viewModel.isRead(chapter(0.5)))
        XCTAssertFalse(harness.viewModel.isRead(chapter(1.5)))
        XCTAssertFalse(harness.viewModel.isRead(chapter(2.5)))

        // Now repeat the SAME progress 2.
        // Because deduplication uses (maximumChapterNumber, availableChapterNumbers) snapshot rather than
        // maximum alone, the new snapshot includes {0, 0.5, 1, 1.5, 2} which differs from initial {1, 2}.
        // The sync MUST run and mark the newly introduced fractional chapters <= 2.
        harness.viewModel.trackerDidSave(progress: 2)
        await harness.viewModel.waitForTrackerProgressForTesting()

        // Chapters <= 2 must now be marked read: 0, 0.5, 1, 1.5, 2
        XCTAssertTrue(harness.viewModel.isRead(chapter(0)), "Chapter 0 should now be read")
        XCTAssertTrue(harness.viewModel.isRead(chapter(0.5)), "Chapter 0.5 should now be read")
        XCTAssertTrue(harness.viewModel.isRead(chapter(1)), "Chapter 1 should remain read")
        XCTAssertTrue(harness.viewModel.isRead(chapter(1.5)), "Chapter 1.5 should now be read")
        XCTAssertTrue(harness.viewModel.isRead(chapter(2)), "Chapter 2 should remain read")

        // Chapters > 2 must remain unread: 2.5 and 3
        XCTAssertFalse(harness.viewModel.isRead(chapter(2.5)), "Chapter 2.5 must remain unread")
        XCTAssertFalse(harness.viewModel.isRead(chapter(3)), "Chapter 3 must remain unread")

        // In database directly
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-0", chapterNum: 0))
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-0.5", chapterNum: 0.5))
        XCTAssertTrue(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-1.5", chapterNum: 1.5))
        XCTAssertFalse(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-2.5", chapterNum: 2.5))
        XCTAssertFalse(harness.progressManager.isRead(media: mediaIdentity, chapterId: "ch-3", chapterNum: 3))

        // Resume chapter should advance to 2.5
        XCTAssertEqual(harness.viewModel.resumeChapter?.chapterNumber, 2.5)
        XCTAssertEqual(harness.viewModel.resumeChapter?.key, "ch-2.5")

        // Reloaded manager verifies durability of newly synced fractions
        let reloaded = ReadProgressManager(dbPool: harness.database.dbPool)
        try await reloaded.reload()
        XCTAssertTrue(reloaded.isRead(media: mediaIdentity, chapterId: "ch-0", chapterNum: 0))
        XCTAssertTrue(reloaded.isRead(media: mediaIdentity, chapterId: "ch-0.5", chapterNum: 0.5))
        XCTAssertTrue(reloaded.isRead(media: mediaIdentity, chapterId: "ch-1.5", chapterNum: 1.5))
        XCTAssertFalse(reloaded.isRead(media: mediaIdentity, chapterId: "ch-2.5", chapterNum: 2.5))
        XCTAssertFalse(reloaded.isRead(media: mediaIdentity, chapterId: "ch-3", chapterNum: 3))
    }
}
