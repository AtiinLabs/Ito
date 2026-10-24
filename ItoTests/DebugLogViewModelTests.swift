import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class DebugLogViewModelTests: XCTestCase {
    func testInitialStateIsEmptyAndIdle() {
        let dependencies = makeDependencies()
        let viewModel = makeViewModel(dependencies: dependencies)

        XCTAssertTrue(viewModel.logs.isEmpty)
        XCTAssertTrue(viewModel.filteredLogs.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertNil(viewModel.alert)
    }

    func testFetchUsesExactRequestAndReversesReaderSequence() async throws {
        let first = entry(id: 1, seconds: 1, category: "first", message: "oldest")
        let second = entry(id: 2, seconds: 2, category: "second", message: "newest")
        let reader = ImmediateDebugLogReader(responses: [.success([first, second])])
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)

        await viewModel.fetchLogs()

        let requests = await reader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.lookback, 86_400)
        XCTAssertEqual(
            requests.first?.allowedSubsystems,
            ["moe.itoapp.ito", "moe.itoapp.runner"]
        )
        XCTAssertEqual(viewModel.logs, [second, first])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.alert)
    }

    func testFetchPublishesLoadingWhileControlledReaderIsPending() async {
        let reader = ControlledDebugLogReader()
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)

        let fetch = Task { await viewModel.fetchLogs() }
        let requestStarted = await boundedTaskYieldWait {
            await reader.requests.count == 1
        }
        XCTAssertTrue(requestStarted)
        guard requestStarted else {
            fetch.cancel()
            await reader.failAllPendingRequests()
            await fetch.value
            return
        }

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.logs.isEmpty)

        await reader.succeedRequest(at: 0, entries: [])
        await fetch.value
        XCTAssertFalse(viewModel.isLoading)
    }

    func testFetchFailureRetainsLogsAndSuccessfulRetryClearsAlert() async {
        let existing = entry(id: 1, seconds: 1, category: "existing", message: "keep")
        let replacement = entry(id: 2, seconds: 2, category: "new", message: "replace")
        let reader = ImmediateDebugLogReader(
            responses: [.success([existing]), .failure, .success([replacement])]
        )
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()

        await viewModel.fetchLogs()

        XCTAssertEqual(viewModel.logs, [existing])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.alert, .fetchFailed)

        await viewModel.fetchLogs()

        XCTAssertEqual(viewModel.logs, [replacement])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.alert)
    }

    func testFilteringMatchesEmptyMessageAndCategoryButNotSubsystem() async {
        let entries = [
            entry(id: 1, category: "network", message: "Loaded chapter"),
            entry(id: 2, subsystem: "match-only-subsystem", category: "ui", message: "Saved"),
            entry(id: 3, category: "LibraryMatch", message: "Updated")
        ]
        let reader = ImmediateDebugLogReader(responses: [.success(Array(entries.reversed()))])
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()

        XCTAssertEqual(viewModel.filteredLogs, entries)

        viewModel.searchText = "cHaPtEr"
        XCTAssertEqual(viewModel.filteredLogs, [entries[0]])

        viewModel.searchText = "librarymatch"
        XCTAssertEqual(viewModel.filteredLogs, [entries[2]])

        viewModel.searchText = "match-only-subsystem"
        XCTAssertTrue(viewModel.filteredLogs.isEmpty)
    }

    func testCopyFormatsAllLogsExactlyAndWritesOnce() async {
        let first = entry(id: 1, seconds: 10, category: "ui", message: "first")
        let second = entry(id: 2, seconds: 20, category: "network", message: "second")
        let reader = ImmediateDebugLogReader(responses: [.success([second, first])])
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()

        viewModel.copyLogs()

        XCTAssertEqual(
            dependencies.writer.writtenTexts,
            ["[\(first.date)] [ui] first\n[\(second.date)] [network] second"]
        )
        XCTAssertEqual(dependencies.presenter.messages, [.copied])
        XCTAssertNil(viewModel.alert)
    }

    func testCopyUsesOnlyLogsMatchingActiveSearch() async {
        let first = entry(id: 1, category: "ui", message: "visible")
        let second = entry(id: 2, category: "network", message: "hidden")
        let reader = ImmediateDebugLogReader(responses: [.success([second, first])])
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()
        viewModel.searchText = "visible"
        XCTAssertEqual(viewModel.filteredLogs, [first])

        viewModel.copyLogs()

        XCTAssertEqual(
            dependencies.writer.writtenTexts,
            ["[\(first.date)] [ui] visible"]
        )
    }

    func testCopyPresentsSuccessOnlyAfterClipboardWrite() async {
        let log = entry(id: 1, category: "ui", message: "fixture")
        let reader = ImmediateDebugLogReader(responses: [.success([log])])
        let recorder = DebugLogEventRecorder()
        let dependencies = makeDependencies(reader: reader, recorder: recorder)
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()

        viewModel.copyLogs()

        XCTAssertEqual(
            recorder.events,
            [.write("[\(log.date)] [ui] fixture"), .presentCopied]
        )
    }

    func testClipboardFailureShowsTypedAlertAndSuccessfulRetryClearsIt() async {
        let log = entry(id: 1, category: "ui", message: "fixture")
        let reader = ImmediateDebugLogReader(responses: [.success([log])])
        let recorder = DebugLogEventRecorder()
        let dependencies = makeDependencies(reader: reader, recorder: recorder)
        dependencies.writer.shouldFail = true
        let viewModel = makeViewModel(dependencies: dependencies)
        await viewModel.fetchLogs()

        viewModel.copyLogs()

        XCTAssertEqual(dependencies.writer.writeCallCount, 1)
        XCTAssertTrue(dependencies.writer.writtenTexts.isEmpty)
        XCTAssertTrue(dependencies.presenter.messages.isEmpty)
        XCTAssertEqual(recorder.events, [.write("[\(log.date)] [ui] fixture")])
        XCTAssertEqual(viewModel.alert, .copyFailed)

        dependencies.writer.shouldFail = false
        viewModel.copyLogs()

        XCTAssertEqual(dependencies.writer.writeCallCount, 2)
        XCTAssertEqual(dependencies.presenter.messages, [.copied])
        XCTAssertNil(viewModel.alert)
    }

    func testOlderOverlappingFetchCannotOverwriteNewerCompletion() async {
        let older = entry(id: 1, category: "older", message: "stale")
        let newer = entry(id: 2, category: "newer", message: "current")
        let reader = ControlledDebugLogReader()
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)

        let firstFetch = Task { await viewModel.fetchLogs() }
        let firstRequestStarted = await boundedTaskYieldWait {
            await reader.requests.count == 1
        }
        XCTAssertTrue(firstRequestStarted)
        guard firstRequestStarted else {
            firstFetch.cancel()
            await reader.failAllPendingRequests()
            await firstFetch.value
            return
        }
        let secondFetch = Task { await viewModel.fetchLogs() }
        let secondRequestStarted = await boundedTaskYieldWait {
            await reader.requests.count == 2
        }
        XCTAssertTrue(secondRequestStarted)
        guard secondRequestStarted else {
            firstFetch.cancel()
            secondFetch.cancel()
            await reader.failAllPendingRequests()
            await firstFetch.value
            await secondFetch.value
            return
        }

        await reader.succeedRequest(at: 1, entries: [newer])
        await secondFetch.value
        XCTAssertEqual(viewModel.logs, [newer])

        await reader.succeedRequest(at: 0, entries: [older])
        await firstFetch.value
        XCTAssertEqual(viewModel.logs, [newer])
        XCTAssertNil(viewModel.alert)
    }

    func testStaleCompletionCannotClearCurrentLoading() async {
        let current = entry(id: 2, category: "newer", message: "current")
        let reader = ControlledDebugLogReader()
        let dependencies = makeDependencies(reader: reader)
        let viewModel = makeViewModel(dependencies: dependencies)

        let firstFetch = Task { await viewModel.fetchLogs() }
        let firstRequestStarted = await boundedTaskYieldWait {
            await reader.requests.count == 1
        }
        XCTAssertTrue(firstRequestStarted)
        guard firstRequestStarted else {
            firstFetch.cancel()
            await reader.failAllPendingRequests()
            await firstFetch.value
            return
        }
        let secondFetch = Task { await viewModel.fetchLogs() }
        let secondRequestStarted = await boundedTaskYieldWait {
            await reader.requests.count == 2
        }
        XCTAssertTrue(secondRequestStarted)
        guard secondRequestStarted else {
            firstFetch.cancel()
            secondFetch.cancel()
            await reader.failAllPendingRequests()
            await firstFetch.value
            await secondFetch.value
            return
        }

        await reader.failRequest(at: 0)
        await firstFetch.value
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.alert)

        await reader.succeedRequest(at: 1, entries: [current])
        await secondFetch.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.logs, [current])
        XCTAssertNil(viewModel.alert)
    }

    func testDebugLogModelIdentityIsStableWithinScopeAndNewAcrossScopes() {
        let firstScope = makeScope()
        let secondScope = makeScope()

        XCTAssertFalse(firstScope.rootModels.hasLoadedDebugLogViewModel)
        _ = firstScope.viewFactory.makeDebugLogView()
        let first = firstScope.rootModels.debugLogViewModel
        let repeated = firstScope.rootModels.debugLogViewModel
        let second = secondScope.rootModels.debugLogViewModel

        XCTAssertTrue(firstScope.rootModels.hasLoadedDebugLogViewModel)
        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === second)
    }

    func testMigratedViewAndModelHaveNoForbiddenAccess() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try [
            "Ito/ViewModels/Settings/DebugLogViewModel.swift",
            "Ito/Views/Settings/DebugLogView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "import OSLog",
            "OSLogStore",
            "OSLogEntryLog",
            "Task.detached",
            "AppLogger",
            "UIPasteboard",
            "SnackBarManager",
            "UserDefaults.standard",
            "UIApplication.shared",
            "UNUserNotificationCenter.current()",
            "FileManager.default",
            "URLSession.shared",
            "@Environment",
            "configure("
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden Debug Log access: \(forbidden)")
        }
        XCTAssertTrue(source.contains("@StateObject private var viewModel"))
    }

    func testDebugLogRouteUsesAppViewFactory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Ito/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let factorySource = try String(
            contentsOf: root.appendingPathComponent("Ito/Views/Search/SearchRouteFactory.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("makeSettingsDestination(for: .debugLogs)"))
        XCTAssertTrue(factorySource.contains("case .debugLogs:\n            makeDebugLogView()"))
        XCTAssertFalse(settingsSource.contains("destination: DebugLogView()"))
    }

    private func makeViewModel(
        dependencies: DebugLogTestDependencies
    ) -> DebugLogViewModel {
        DebugLogViewModel(
            logReader: dependencies.reader,
            clipboardWriter: dependencies.writer,
            messagePresenter: dependencies.presenter
        )
    }

    private func makeDependencies(
        reader: any DebugLogReading = ImmediateDebugLogReader(responses: []),
        recorder: DebugLogEventRecorder? = nil
    ) -> DebugLogTestDependencies {
        DebugLogTestDependencies(
            reader: reader,
            writer: DebugLogClipboardWriter(recorder: recorder),
            presenter: DebugLogMessagePresenter(recorder: recorder)
        )
    }

    private func entry(
        id: UInt8,
        seconds: TimeInterval = 0,
        subsystem: String = "moe.itoapp.ito",
        category: String,
        message: String
    ) -> DebugLogEntry {
        DebugLogEntry(
            id: UUID(uuid: (id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            date: Date(timeIntervalSince1970: seconds),
            subsystem: subsystem,
            category: category,
            message: message,
            level: .notice
        )
    }

    private func makeScope() -> AppScope {
        let bundle = TestPreparedSettingsDependencyBundle()
        return AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: bundle.dependencies,
                searchExecutor: DebugLogSearchExecutor(),
                recentSearchStore: DebugLogRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: DebugLogRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: DebugLogPluginManager(),
                browseFileOperations: DebugLogFileOperations()
            )
        )
    }
}

private struct DebugLogTestDependencies {
    let reader: any DebugLogReading
    let writer: DebugLogClipboardWriter
    let presenter: DebugLogMessagePresenter
}

@MainActor
private final class DebugLogEventRecorder {
    enum Event: Equatable {
        case write(String)
        case presentCopied
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

@MainActor
private final class DebugLogClipboardWriter: ClipboardWriting {
    var shouldFail = false
    private(set) var writeCallCount = 0
    private(set) var writtenTexts: [String] = []
    private let recorder: DebugLogEventRecorder?

    init(recorder: DebugLogEventRecorder?) {
        self.recorder = recorder
    }

    func write(_ text: String) throws {
        writeCallCount += 1
        recorder?.record(.write(text))
        if shouldFail {
            throw DebugLogReaderError.failed
        }
        writtenTexts.append(text)
    }
}

@MainActor
private final class DebugLogMessagePresenter: DebugLogMessagePresenting {
    private(set) var messages: [DebugLogMessage] = []
    private let recorder: DebugLogEventRecorder?

    init(recorder: DebugLogEventRecorder?) {
        self.recorder = recorder
    }

    func present(_ message: DebugLogMessage) {
        messages.append(message)
        switch message {
        case .copied:
            recorder?.record(.presentCopied)
        }
    }
}

@MainActor
private final class DebugLogSearchExecutor: SearchPluginExecuting {
    let plugins: [SearchPluginDescriptor] = []

    func search(
        plugin: SearchPluginDescriptor,
        kind: MediaKind?,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = query
        _ = limit
        return []
    }

    func evictRunner(for pluginID: String) {
        _ = pluginID
    }
}

@MainActor
private final class DebugLogRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class DebugLogRepositoryManager: BrowseRepositoryManaging {
    let repositories: [Repository] = []
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just(repositories).eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        _ = url
        return .added
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        _ = package
        _ = repositoryURL
    }

    func refreshAll() async {}
}

@MainActor
private final class DebugLogPluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func holdCompletionDelivery(for pluginID: String) async throws {}
    func purgeCompletionDelivery(for pluginID: String) async {}
    func revokeTrust(for pluginID: String) throws {}
    func removeSecrets(for pluginID: String) {}
}

@MainActor
private final class DebugLogFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool { _ = url; return false }
    func installPluginFile(from url: URL) throws { _ = url }
    func deletePluginFile(at url: URL) throws { _ = url }
}
