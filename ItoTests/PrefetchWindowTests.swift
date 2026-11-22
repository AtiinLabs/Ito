import Foundation
import GRDB
import Testing
import XCTest
import ito_runner
@testable import Ito

@MainActor
struct PrefetchWindowTests {
    @Test func stationaryPagedAndContinuousWindowsFollowCommittedSettings() async throws {
        for (viewer, isContinuous) in [(Manga.Viewer.Ltr, false), (.Vertical, true)] {
            let fixture = try await Fixture.make(viewer: viewer, preload: .none)
            defer { fixture.database.cleanup() }
            await fixture.load()
            let pageIDs = fixture.viewModel.flatPages.map(\.id)
            if isContinuous {
                fixture.viewModel.continuousViewportChanged([pageIDs[4]])
            }
            for preference in [
                ImagePreloadCountPreference.five, .ten, .twenty, .none
            ] {
                let eventCount = fixture.prefetcher.eventCount
                try await fixture.settingsStore.set(preference, for: AppPreferenceCatalog.preloadImageCount)
                await fixture.prefetcher.waitForEventCount(eventCount + 1)
                if preference == .none {
                    #expect(fixture.prefetcher.currentWindow.isEmpty)
                } else {
                    let start = isContinuous ? 5 : 0
                    let length = preference.rawValue + (isContinuous ? 0 : 1)
                    #expect(fixture.prefetcher.windows.last == Array(start..<(start + length)))
                }
            }
        }
    }

    @Test func unknownAndRestrictedPathsBeginPrefetchWhenTheyBecomeAllowed() async throws {
        for initialPath in [NetworkPathSnapshot.unknown, NetworkPathSnapshot(status: .satisfied, isExpensive: true)] {
            let fixture = try await Fixture.make(viewer: .Vertical, path: initialPath, preload: .five)
            defer { fixture.database.cleanup() }
            await fixture.load()
            fixture.viewModel.continuousViewportChanged([fixture.viewModel.flatPages[4].id])
            #expect(fixture.prefetcher.windows.isEmpty)
            let previousEventCount = fixture.prefetcher.eventCount

            fixture.path.set(NetworkPathSnapshot(status: .satisfied))
            await fixture.prefetcher.waitForEventCount(previousEventCount + 1)

            #expect(fixture.prefetcher.windows.last == Array(5..<10))
        }
    }
    @Test func continuousReaderWaitsForItsFirstValidViewport() async throws {
        let fixture = try await Fixture.make(viewer: .Vertical, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()

        #expect(fixture.prefetcher.windows.isEmpty)
        let eventCount = fixture.prefetcher.eventCount
        fixture.viewModel.continuousViewportChanged([fixture.viewModel.flatPages[3].id])
        await fixture.prefetcher.waitForEventCount(eventCount + 1)
        #expect(fixture.prefetcher.windows.last == Array(4..<9))
    }

    @Test func externalSettingUpdatesTheDisplayedPreferenceAndPrefetchWindow() async throws {
        let fixture = try await Fixture.make(viewer: .Vertical, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()
        fixture.viewModel.continuousViewportChanged([fixture.viewModel.flatPages[2].id])
        let eventCount = fixture.prefetcher.eventCount

        try await fixture.settingsStore.set(.ten, for: AppPreferenceCatalog.preloadImageCount)
        await fixture.prefetcher.waitForEventCount(eventCount + 1)

        #expect(fixture.viewModel.preloadImageCount == 10)
        #expect(fixture.prefetcher.windows.last == Array(3..<13))
    }

    @Test func finalContinuousViewportClearsThePreviousWindow() async throws {
        let fixture = try await Fixture.make(viewer: .Vertical, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()
        let pages = fixture.viewModel.flatPages
        fixture.viewModel.continuousViewportChanged([try #require(pages.first).id])
        #expect(fixture.prefetcher.currentWindow == Array(1..<6))

        fixture.viewModel.continuousViewportChanged([try #require(pages.last).id])

        #expect(fixture.prefetcher.currentWindow.isEmpty)
    }

    @Test func switchingReadingModeStartsFromTheCurrentPageNotAnEarlierViewport() async throws {
        let fixture = try await Fixture.make(viewer: .Vertical, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()
        fixture.viewModel.continuousViewportChanged([fixture.viewModel.flatPages[2].id])
        #expect(fixture.prefetcher.currentWindow == Array(3..<8))

        fixture.viewModel.setViewerOverride(.Ltr)
        #expect(fixture.prefetcher.currentWindow == Array(2..<8))
        fixture.viewModel.setPagedIndex(15)
        #expect(fixture.prefetcher.currentWindow == Array(15..<21))

        // Back to scrolling: the page-2 viewport of the earlier continuous session must not move the window back.
        let eventCount = fixture.prefetcher.eventCount
        fixture.viewModel.setViewerOverride(.Vertical)
        #expect(fixture.prefetcher.eventCount == eventCount)
        #expect(fixture.prefetcher.currentWindow == Array(15..<21))

        fixture.viewModel.continuousViewportChanged([fixture.viewModel.flatPages[15].id])
        #expect(fixture.prefetcher.currentWindow == Array(16..<21))
    }

    @Test func inactiveAndStagedReadersWaitUntilLiveAppearanceToReconcile() async throws {
        let fixture = try await Fixture.make(viewer: .Ltr, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()
        let firstWindow = fixture.prefetcher.windows.last
        #expect(firstWindow == Array(0..<6))

        fixture.viewModel.disappear()
        let eventCount = fixture.prefetcher.eventCount
        try await fixture.settingsStore.set(.ten, for: AppPreferenceCatalog.preloadImageCount)
        fixture.viewModel.networkPolicyDidChange()
        #expect(fixture.prefetcher.eventCount == eventCount)
        fixture.viewModel.appear()
        #expect(fixture.prefetcher.windows.last == Array(0..<11))
        #expect(fixture.viewModel.preloadImageCount == 10)

        fixture.viewModel.setPresentationMode(.staged(requestID: UUID(), visitID: UUID()))
        let stagedEventCount = fixture.prefetcher.eventCount
        try await fixture.settingsStore.set(.five, for: AppPreferenceCatalog.preloadImageCount)
        fixture.viewModel.networkPolicyDidChange()
        #expect(fixture.prefetcher.eventCount == stagedEventCount)
        fixture.viewModel.setPresentationMode(.live)
        fixture.viewModel.appear()
        #expect(fixture.prefetcher.currentWindow == Array(0..<6))
        #expect(fixture.viewModel.preloadImageCount == 5)
    }

    @Test func failedPreloadPersistenceDoesNotApplyAnUncommittedWindow() async throws {
        let fixture = try await Fixture.make(viewer: .Ltr, preload: .five)
        defer { fixture.database.cleanup() }
        await fixture.load()
        let originalWindow = fixture.prefetcher.windows.last
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_preload_insert BEFORE INSERT ON appPreference
                WHEN NEW.key = 'Ito.PreloadImageCount'
                BEGIN SELECT RAISE(ABORT, 'rejected preload write'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER reject_preload_update BEFORE UPDATE ON appPreference
                WHEN OLD.key = 'Ito.PreloadImageCount'
                BEGIN SELECT RAISE(ABORT, 'rejected preload write'); END
                """)
        }

        fixture.viewModel.setPreloadImageCount(10)
        await fixture.viewModel.waitForTestingOperations()

        #expect(fixture.settingsStore.preloadImageCount == .five)
        #expect(fixture.viewModel.preloadImageCount == 5)
        #expect(fixture.prefetcher.windows.last == originalWindow)
    }
}

@MainActor
private final class Fixture {
    let database: TestDatabase
    let path: ManualNetworkPathObserver
    let settingsStore: AppSettingsStore
    let viewModel: MangaReaderViewModel
    let prefetcher: RecordingImagePrefetcher

    private init(
        database: TestDatabase,
        path: ManualNetworkPathObserver,
        settingsStore: AppSettingsStore,
        viewModel: MangaReaderViewModel,
        prefetcher: RecordingImagePrefetcher
    ) {
        self.database = database
        self.path = path
        self.settingsStore = settingsStore
        self.viewModel = viewModel
        self.prefetcher = prefetcher
    }

    static func make(
        viewer: Manga.Viewer = .Ltr,
        path initialPath: NetworkPathSnapshot = NetworkPathSnapshot(status: .satisfied),
        preload: ImagePreloadCountPreference
    ) async throws -> Fixture {
        let database = try TestDatabase()
        let path = ManualNetworkPathObserver(initial: initialPath)
        let policy = NetworkPolicyCenter(path: path)
        let settingsStore = AppSettingsStore(dbPool: database.dbPool, networkPolicy: policy)
        try await settingsStore.reload()
        try await settingsStore.set(preload, for: AppPreferenceCatalog.preloadImageCount)

        let chapter = Chapter(key: "a", chapter: 1)
        let entry = Manga(key: "series", title: "Fixture", viewer: viewer, chapters: [chapter])
        let base = makeMangaReaderSubject(manga: entry, initialChapter: chapter, preloadImageCount: preload.rawValue)
        let prefetcher = RecordingImagePrefetcher(imageSession: base.imagePrefetcher.imageSession)
        let dependencies = PreparedMangaReaderDependencies(
            progress: base.progress,
            history: base.history,
            tracker: base.tracker,
            settings: settingsStore,
            presence: base.presence,
            pluginMetadata: base.metadata,
            makeImagePrefetcher: { _ in prefetcher },
            presentationLogger: base.logger
        )
        let viewModel = MangaReaderViewModel(
            chapterPreparer: base.preparer,
            routeSession: base.session,
            routeVisitID: UUID(),
            presentationMode: .live,
            pluginID: "plugin.test",
            entry: .manga(entry),
            initialChapter: chapter,
            dependencies: dependencies,
            offline: ReaderOfflineContext()
        )
        let fixture = Fixture(
            database: database,
            path: path,
            settingsStore: settingsStore,
            viewModel: viewModel,
            prefetcher: prefetcher
        )
        base.loader.enqueue(
            .pages((0..<30).map { Page(index: Int32($0), content: .url("https://example.com/\($0)")) }),
            for: chapter.key
        )
        return fixture
    }

    func load() async {
        viewModel.start()
        await viewModel.waitForTestingOperations()
    }
}


@MainActor
private final class RecordingImagePrefetcher: MangaReaderImagePrefetching {
    let imageSession: ReaderPageImageSession
    private(set) var windows: [[Int]] = []
    private(set) var currentWindow: [Int] = []
    private(set) var eventCount = 0
    private var waiters: [(Int, XCTestExpectation)] = []

    init(imageSession: ReaderPageImageSession) { self.imageSession = imageSession }

    func prefetch(_ pages: [Page]) {
        windows.append(pages.map { Int($0.index) })
        currentWindow = pages.map { Int($0.index) }
        recordEvent()
    }

    func stopPrefetching() {
        currentWindow = []
        recordEvent()
    }

    func waitForEventCount(_ target: Int) async {
        guard eventCount < target else { return }
        let event = XCTestExpectation(description: "prefetch window event \(target)")
        waiters.append((target, event))
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        #expect(result == .completed, "The current window must be reconciled after the acknowledged change")
    }

    private func recordEvent() {
        eventCount += 1
        let ready = waiters.filter { eventCount >= $0.0 }
        waiters.removeAll { eventCount >= $0.0 }
        ready.forEach { $0.1.fulfill() }
    }
}
