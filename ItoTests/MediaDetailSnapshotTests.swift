import XCTest
import ito_runner
@testable import Ito

/// A detail load that succeeds for a saved series refreshes the Library's saved details, but only from a
/// token read before the load; the screens that show saved details say so when the device is offline.
@MainActor
final class MediaDetailSnapshotTests: XCTestCase {
    private nonisolated static let pluginID = "plugin.test"
    private nonisolated static let media = MediaIdentity(pluginId: pluginID, canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let token = LibrarySnapshotToken(
        itemID: "series-1",
        media: media,
        payloadSHA256: String(repeating: "c", count: 64)
    )

    private final class EventLog {
        var events: [String] = []
    }

    private struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let library: MediaDetailLibraryFake
        let route: MediaRouteHarness<Manga>
        let connectivity: ConnectivityFake
        let relink: MediaDetailRelinkFake
        let log: EventLog
    }

    private func series(
        cover: String? = "https://example.com/cover.jpg",
        chapters: [Chapter]? = [Chapter(key: "c1", chapter: 1), Chapter(key: "c2", chapter: 2)]
    ) -> Manga {
        Manga(key: "series-1", title: "Series", cover: cover, chapters: chapters)
    }

    private func makeSubject(
        saved: Bool = true,
        isOffline: Bool = false,
        savedOnly: Bool = false,
        loads: [MediaRouteHarness<Manga>.LoadResponse] = [],
        snapshotEncoder: any MediaDetailSnapshotEncoding = JSONMediaDetailSnapshotEncoder()
    ) -> Subject {
        let library = MediaDetailLibraryFake(
            state: MediaDetailLibraryState(
                records: saved
                    ? [MediaDetailLibraryRecord(itemID: "series-1", pluginID: Self.pluginID, mediaKind: .manga)]
                    : [],
                hasCustomCategories: false
            )
        )
        let log = EventLog()
        library.onSnapshotTokenRead = { log.events.append("token") }
        let route = MediaRouteHarness<Manga>()
        route.loadResponses = loads
        let connectivity = ConnectivityFake(isOffline: isOffline)
        let relink = MediaDetailRelinkFake()
        var loader: ((Manga, PluginNetworkOperation) async throws -> Manga)?
        if !savedOnly {
            loader = { media, operation in
                log.events.append("load")
                return try await route.load(media, operation: operation)
            }
        }
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: loader,
            searchForRelink: { try await route.search($0, operationID: $1) },
            makeReaderDestination: { parent, selected in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(parent),
                    chapter: selected
                )
            }
        )
        var dependencies = PreparedMediaDetailDependencies(
            library: library,
            progress: MediaDetailProgressFake(),
            tracker: MediaDetailTrackerFake(),
            theme: MediaDetailThemeFake(),
            relink: relink,
            baseline: MediaDetailBaselineFake(),
            settings: MediaDetailSettingsFake(alwaysShowCategoryPicker: false, autoSyncTrackersToLocal: false),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake()
        )
        dependencies.connectivity = connectivity
        let viewModel = MediaDetailViewModel(
            media: series(cover: nil, chapters: [Chapter(key: "old", chapter: 1)]),
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: dependencies,
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy(),
            snapshotEncoder: snapshotEncoder
        )
        return Subject(
            viewModel: viewModel,
            library: library,
            route: route,
            connectivity: connectivity,
            relink: relink,
            log: log
        )
    }

    // MARK: - Refreshing the saved details

    func testTheTokenIsReadBeforeTheSourceIsAsked() async {
        let subject = makeSubject(loads: [.value(series())])
        subject.library.tokenToReturn = Self.token

        await subject.viewModel.refresh()

        XCTAssertEqual(subject.log.events, ["token", "load"])
        XCTAssertEqual(subject.library.snapshotTokenRequests, [Self.media])
    }

    func testASuccessfulLoadOfASavedSeriesReplacesTheSavedDetailsFromTheTokenItRead() async throws {
        let refreshed = series()
        let subject = makeSubject(loads: [.value(refreshed)])
        subject.library.tokenToReturn = Self.token

        await subject.viewModel.refresh()

        let request = try XCTUnwrap(subject.library.replaceRequests.first)
        XCTAssertEqual(subject.library.replaceRequests.count, 1)
        XCTAssertEqual(request.token, Self.token)
        XCTAssertEqual(request.coverURL, "https://example.com/cover.jpg")
        XCTAssertEqual(request.chapterRowCount, 2)
        // This series reports no catalog, so the refresh claims nothing about it.
        XCTAssertEqual(request.catalog, .unknown)
        let payload = try JSONDecoder().decode(Manga.self, from: request.payload)
        XCTAssertEqual(payload.key, "series-1")
        XCTAssertEqual(payload.chapterList?.map(\.key), ["c1", "c2"])
        XCTAssertEqual(subject.viewModel.snapshotRefreshedAt, request.refreshedAt)
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
    }

    func testASeriesThatIsNotSavedReadsNoTokenAndWritesNothing() async {
        let subject = makeSubject(saved: false, loads: [.value(series())])
        subject.library.tokenToReturn = Self.token

        await subject.viewModel.refresh()

        XCTAssertTrue(subject.library.snapshotTokenRequests.isEmpty)
        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
    }

    func testNoTokenMeansNoWrite() async {
        let subject = makeSubject(loads: [.value(series())])
        subject.library.tokenToReturn = nil

        await subject.viewModel.refresh()

        XCTAssertEqual(subject.library.snapshotTokenRequests, [Self.media])
        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
    }

    func testALoadWithoutChaptersNeverReplacesTheSavedDetails() async {
        let empty = makeSubject(loads: [.value(series(chapters: []))])
        empty.library.tokenToReturn = Self.token
        let missing = makeSubject(loads: [.value(series(chapters: nil))])
        missing.library.tokenToReturn = Self.token

        await empty.viewModel.refresh()
        await missing.viewModel.refresh()

        XCTAssertTrue(empty.library.replaceRequests.isEmpty)
        XCTAssertTrue(missing.library.replaceRequests.isEmpty)
        XCTAssertNil(empty.viewModel.snapshotRefreshedAt)
        XCTAssertEqual(empty.viewModel.detailLoadState, .content)
    }

    /// Starts a refresh whose source load stays suspended, and returns once that load is pending.
    private func startSuspendedRefresh(_ subject: Subject) async -> Task<Void, Never> {
        var refresh: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            subject.route.onLoadSuspended = {
                subject.route.onLoadSuspended = nil
                started.resume()
            }
            refresh = Task { await subject.viewModel.refresh() }
        }
        return refresh ?? Task {}
    }

    func testALoadThatIsCancelledBeforeItReturnsNeverReplacesTheSavedDetails() async {
        let subject = makeSubject(loads: [.suspended])
        subject.library.tokenToReturn = Self.token
        let refresh = await startSuspendedRefresh(subject)

        subject.viewModel.cancelScreenOperations()
        subject.route.resolveLoad(at: 0, with: .success(series()))
        await refresh.value

        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
        XCTAssertNil(subject.viewModel.snapshotRefreshedAt)
    }

    func testALoadThatIsSupersededByANewerOneNeverReplacesTheSavedDetails() async {
        let subject = makeSubject(loads: [.suspended, .value(series(chapters: [Chapter(key: "new", chapter: 3)]))])
        subject.library.tokenToReturn = Self.token
        let older = await startSuspendedRefresh(subject)

        await subject.viewModel.refresh()
        XCTAssertEqual(subject.library.replaceRequests.count, 1)
        subject.route.resolveLoad(at: 0, with: .success(series()))
        await older.value

        // Only the newer load wrote; the older one returned later and was ignored.
        XCTAssertEqual(subject.library.replaceRequests.count, 1)
        XCTAssertEqual(subject.viewModel.media.chapterList?.map(\.key), ["new"])
    }

    func testSupersededSnapshotEncodingCannotClearTheNewerTaskOrPublishEitherSnapshot() async {
        let olderStarted = expectation(description: "older snapshot encoder starts")
        let newerStarted = expectation(description: "newer snapshot encoder starts")
        let encoder = SuspendedSnapshotEncoder { request in
            (request == 1 ? olderStarted : newerStarted).fulfill()
        }
        defer { Task { await encoder.releaseAll() } }
        let subject = makeSubject(
            loads: [
                .value(series(chapters: [Chapter(key: "older", chapter: 1)])),
                .value(series(chapters: [Chapter(key: "newer", chapter: 2)]))
            ],
            snapshotEncoder: encoder
        )
        subject.library.tokenToReturn = Self.token
        let older = Task { await subject.viewModel.refresh() }
        await fulfillment(of: [olderStarted], timeout: 5)

        let newer = Task { await subject.viewModel.refresh() }
        await fulfillment(of: [newerStarted], timeout: 5)
        await encoder.release(request: 1)
        await older.value

        // The newer refresh is still in encoding; cancellation must reach its still-owned task handle.
        subject.viewModel.cancelScreenOperations()
        await encoder.release(request: 2)
        await newer.value

        let olderWasCancelled = await encoder.observedCancellationState(for: 1)
        let newerWasCancelled = await encoder.observedCancellationState(for: 2)
        XCTAssertEqual(olderWasCancelled, true)
        XCTAssertEqual(newerWasCancelled, true)
        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
        XCTAssertNil(subject.viewModel.snapshotRefreshedAt)
    }

    func testAFailedLoadNeverWrites() async {
        let subject = makeSubject(loads: [.failure])
        subject.library.tokenToReturn = Self.token

        await subject.viewModel.refresh()

        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
        guard case .failure = subject.viewModel.detailLoadState else {
            return XCTFail("The failed load is shown as a failure")
        }
    }

    func testASavedOnlyRouteNeverWrites() {
        let subject = makeSubject(savedOnly: true)
        subject.library.tokenToReturn = Self.token

        subject.viewModel.start()

        XCTAssertEqual(subject.viewModel.detailLoadState, .savedOnly)
        XCTAssertTrue(subject.library.snapshotTokenRequests.isEmpty)
        XCTAssertTrue(subject.library.replaceRequests.isEmpty)
    }

    func testARefusedRefreshLeavesTheScreenShowingTheLoadedSeriesAndNoDate() async {
        let subject = makeSubject(loads: [.value(series())])
        subject.library.tokenToReturn = Self.token
        subject.library.replaceOutcome = .stale

        await subject.viewModel.refresh()

        XCTAssertEqual(subject.library.replaceRequests.count, 1)
        XCTAssertNil(subject.viewModel.snapshotRefreshedAt)
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertEqual(subject.viewModel.media.chapterList?.map(\.key), ["c1", "c2"])
    }

    func testAFailureToReadTheTokenOrToWriteNeverFailsTheLoad() async {
        let unreadable = makeSubject(loads: [.value(series())])
        unreadable.library.snapshotTokenError = MediaDetailTestFailure.expected
        let unwritable = makeSubject(loads: [.value(series())])
        unwritable.library.tokenToReturn = Self.token
        unwritable.library.replaceError = MediaDetailTestFailure.expected

        await unreadable.viewModel.refresh()
        await unwritable.viewModel.refresh()

        XCTAssertEqual(unreadable.viewModel.detailLoadState, .content)
        XCTAssertTrue(unreadable.library.replaceRequests.isEmpty)
        XCTAssertEqual(unwritable.viewModel.detailLoadState, .content)
        XCTAssertEqual(unwritable.library.replaceRequests.count, 1)
        XCTAssertNil(unwritable.viewModel.snapshotRefreshedAt)
    }

    func testARelinkNeverReadsATokenOrWritesTheSnapshot() async {
        let subject = makeSubject(loads: [.value(series())])
        await subject.viewModel.refresh()
        subject.library.tokenToReturn = Self.token
        let requestsBefore = subject.library.snapshotTokenRequests.count
        let replacesBefore = subject.library.replaceRequests.count
        subject.viewModel.openRelink()
        let target = Manga(key: "series-2", title: "Other", chapters: [Chapter(key: "n1", chapter: 1)])
        subject.route.loadResponses = [.value(target)]

        await subject.viewModel.performRelink(with: target)

        XCTAssertEqual(subject.relink.requests.count, 1)
        XCTAssertEqual(subject.library.snapshotTokenRequests.count, requestsBefore)
        XCTAssertEqual(subject.library.replaceRequests.count, replacesBefore)
    }

    // MARK: - Notices

    func testTheOfflineNoticeShowsOnlyForASavedSeriesWhoseLoadFailedWhileOffline() async {
        let offline = makeSubject(isOffline: true, loads: [.failure])
        offline.library.refreshDate = Date(timeIntervalSince1970: 1_700_000_000)
        let online = makeSubject(isOffline: false, loads: [.failure])
        let unsaved = makeSubject(saved: false, isOffline: true, loads: [.failure])

        await offline.viewModel.refresh()
        await offline.viewModel.waitForSnapshotRefreshDateForTesting()
        await online.viewModel.refresh()
        await unsaved.viewModel.refresh()

        XCTAssertEqual(
            offline.viewModel.offlineNotice,
            MediaDetailOfflineNotice(kind: .offline, refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        XCTAssertNil(online.viewModel.offlineNotice)
        XCTAssertNil(unsaved.viewModel.offlineNotice)
    }

    func testTheNoticeFollowsConnectivityWithoutAnotherLoad() async {
        let subject = makeSubject(isOffline: false, loads: [.failure])
        await subject.viewModel.refresh()
        XCTAssertNil(subject.viewModel.offlineNotice)

        subject.connectivity.set(isOffline: true)
        XCTAssertTrue(subject.viewModel.isOffline)
        XCTAssertEqual(subject.viewModel.offlineNotice?.kind, .offline)

        subject.connectivity.set(isOffline: false)
        XCTAssertFalse(subject.viewModel.isOffline)
        XCTAssertNil(subject.viewModel.offlineNotice)
    }

    func testAnUnknownAgeIsNotShownAsADate() async {
        let subject = makeSubject(isOffline: true, loads: [.failure])
        subject.library.refreshDate = nil

        await subject.viewModel.refresh()
        await subject.viewModel.waitForSnapshotRefreshDateForTesting()

        XCTAssertEqual(subject.viewModel.offlineNotice, MediaDetailOfflineNotice(kind: .offline, refreshedAt: nil))
        XCTAssertNil(subject.viewModel.offlineNotice?.updatedText(relativeTo: Date()))
    }

    func testTheSavedOnlyNoticeCarriesTheRefreshDate() async {
        let subject = makeSubject(savedOnly: true)
        subject.library.refreshDate = Date(timeIntervalSince1970: 1_700_000_000)

        subject.viewModel.start()
        await subject.viewModel.waitForSnapshotRefreshDateForTesting()

        XCTAssertEqual(
            subject.viewModel.offlineNotice,
            MediaDetailOfflineNotice(kind: .savedOnly, refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        XCTAssertEqual(subject.library.refreshDateRequests, [Self.media])
    }

    func testALoadedSeriesHasNoNotice() async {
        let subject = makeSubject(isOffline: true, loads: [.value(series())])

        await subject.viewModel.refresh()

        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertNil(subject.viewModel.offlineNotice)
    }

    func testTheUpdatedLineIsRelativeToNow() {
        let refreshed = Date(timeIntervalSince1970: 1_700_000_000)
        let notice = MediaDetailOfflineNotice(kind: .offline, refreshedAt: refreshed)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full

        let text = notice.updatedText(
            relativeTo: refreshed.addingTimeInterval(3 * 60 * 60),
            formatter: formatter
        )

        XCTAssertTrue(text?.contains("3 hours ago") == true, "\(text ?? "nil")")
    }
}
