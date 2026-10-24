import Combine
import XCTest
@testable import Ito

@MainActor
final class AppMessageCenterTests: XCTestCase {
    func testInitialStateContainsNoPresentedMessage() {
        let center = AppMessageCenter()

        XCTAssertNil(center.currentMessage)
        XCTAssertEqual(center.queuedMessageCount, 0)
    }

    func testPublishingPresentsOneTypedMessage() throws {
        let center = AppMessageCenter()

        let id = center.publish(.browseUpdateFailed)

        let message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.id, id)
        XCTAssertEqual(message.kind, .browseUpdateFailed)
    }

    func testOneMessageIsDeliveredOnlyOnceAcrossRepeatedReads() throws {
        let center = AppMessageCenter()
        let id = center.publish(.browseDropLoadFailed)

        let first = try XCTUnwrap(center.currentMessage)
        let second = try XCTUnwrap(center.currentMessage)

        XCTAssertEqual(first.id, id)
        XCTAssertEqual(second.id, id)
        XCTAssertEqual(center.queuedMessageCount, 0)
    }

    func testExactIDDismissalRemovesMatchingMessage() {
        let center = AppMessageCenter()
        let id = center.publish(.browseUpdateFailed)

        center.dismiss(messageID: id)

        XCTAssertNil(center.currentMessage)
    }

    func testWrongAndStaleDismissalCannotRemoveCurrentMessage() throws {
        let center = AppMessageCenter()
        let firstID = center.publish(.browseUpdateFailed)
        let secondID = center.publish(.repositoryAddFailed)

        center.dismiss(messageID: UUID())
        XCTAssertEqual(center.currentMessage?.id, firstID)
        center.dismiss(messageID: firstID)
        XCTAssertEqual(center.currentMessage?.id, secondID)
        center.dismiss(messageID: firstID)

        XCTAssertEqual(try XCTUnwrap(center.currentMessage).id, secondID)
    }

    func testMultipleMessagesUseFIFOOrdering() {
        let center = AppMessageCenter()
        let first = center.publish(.browseUpdateFailed)
        let second = center.publish(.browseDeleteFailed)
        let third = center.publish(.repositoryAddFailed)

        XCTAssertEqual(center.currentMessage?.id, first)
        center.dismiss(messageID: first)
        XCTAssertEqual(center.currentMessage?.id, second)
        center.dismiss(messageID: second)
        XCTAssertEqual(center.currentMessage?.id, third)
    }

    func testDismissingOneMessageAdvancesNextExactlyOnce() {
        let center = AppMessageCenter()
        let first = center.publish(.browseUpdateFailed)
        let second = center.publish(.browseDeleteFailed)

        center.dismiss(messageID: first)
        center.dismiss(messageID: first)

        XCTAssertEqual(center.currentMessage?.id, second)
        XCTAssertEqual(center.queuedMessageCount, 0)
    }

    func testRootRecomputationDoesNotDuplicatePresentation() {
        let scope = makeScope()
        let id = scope.messageCenter.publish(.repositoryAddFailed)

        _ = scope.viewFactory.makeBrowseView()
        _ = scope.viewFactory.makeSearchView()

        XCTAssertEqual(scope.messageCenter.currentMessage?.id, id)
        XCTAssertEqual(scope.messageCenter.queuedMessageCount, 0)
    }

    func testNewAppScopeEpochGetsNewEmptyMessageCenter() {
        let first = makeScope()
        first.messageCenter.publish(.browseUpdateFailed)
        let second = makeScope()

        XCTAssertFalse(first.messageCenter === second.messageCenter)
        XCTAssertNil(second.messageCenter.currentMessage)
        XCTAssertEqual(second.messageCenter.queuedMessageCount, 0)
    }

    func testMessageSchemaHasNoArbitrarySensitiveFields() throws {
        let source = try sourceFile("Ito/AppMessageCenter.swift")
        let schemaStart = try XCTUnwrap(source.range(of: "enum AppMessageKind"))
        let presentationStart = try XCTUnwrap(source.range(of: "struct AppMessagePresentation"))
        let schema = String(source[schemaStart.lowerBound..<presentationStart.lowerBound])

        for forbidden in [
            "URL",
            "String",
            "Error",
            "payload",
            "metadata",
            "credential",
            "token",
            "[String:"
        ] {
            XCTAssertFalse(schema.contains(forbidden), "Sensitive message schema field: \(forbidden)")
        }
    }

    func testSensitiveSentinelsNeverReachCapturedOrRenderedMessages() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageBrowseMessagePresenter(messageCenter: center)
        let sentinels = [
            "https://private.example/repository",
            "https://signed.example/index.json?signature=secret",
            "user:password@example.com",
            "token-123456",
            "backup-fragment-private"
        ]
        presenter.present(.importFailed(source: .openURL, reason: sentinels.joined()))

        let message = try XCTUnwrap(center.currentMessage)
        let rendered = [
            String(describing: message),
            message.kind.presentation.title,
            message.kind.presentation.detail ?? ""
        ].joined(separator: " ")

        for sentinel in sentinels {
            XCTAssertFalse(rendered.contains(sentinel))
        }
    }

    func testRepositoryManagementPresenterUsesTypedSanitizedMessages() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageRepositoryManagementPresenter(messageCenter: center)
        let sensitiveReason = "https://user:password@private.example/index.json?token=secret"

        presenter.present(.installFailed(packageName: "Private Package", reason: sensitiveReason))

        var message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .repositoryInstallFailed)
        XCTAssertEqual(
            message.kind.presentation.detail,
            "Failed to install package. Please try again."
        )
        XCTAssertFalse(String(describing: message).contains(sensitiveReason))
        center.dismiss(messageID: message.id)

        presenter.present(.removeFailed(reason: sensitiveReason))
        message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .repositoryRemoveFailed)
        center.dismiss(messageID: message.id)

        presenter.present(.refreshFailed(reason: sensitiveReason))
        message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .repositoryRefreshFailed)
        XCTAssertFalse(String(describing: message).contains(sensitiveReason))
    }

    func testSourcePresenterUsesTypedSanitizedMessages() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageSourcePresenter(messageCenter: center)
        let sensitiveReason = "https://user:password@private.example?token=secret"

        presenter.present(.archivedPluginDeleteFailed(
            pluginName: "Private Plugin",
            reason: sensitiveReason
        ))

        let message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .sourceArchivedPluginDeleteFailed)
        XCTAssertEqual(
            message.kind.presentation.detail,
            "Plugin removal encountered an error. Refresh plugin state before retrying."
        )
        let rendered = String(describing: message) + (message.kind.presentation.detail ?? "")
        XCTAssertFalse(rendered.contains(sensitiveReason))
        XCTAssertFalse(rendered.contains("Private Plugin"))
    }

    func testDiscoverDetailPresenterUsesTypedSanitizedMessage() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageDiscoverDetailPresenter(messageCenter: center)

        presenter.present(.refreshFailed)

        let message = try XCTUnwrap(center.currentMessage)
        XCTAssertEqual(message.kind, .discoverDetailRefreshFailed)
        XCTAssertEqual(message.kind.presentation.title, "Details unavailable")
        XCTAssertEqual(
            message.kind.presentation.detail,
            "Full media details could not be refreshed. The available summary is still shown."
        )
    }

    func testLibraryPresenterUsesOnlyTypedSanitizedMessages() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageLibraryPresenter(messageCenter: center)
        let expected: [(LibraryMessage, AppMessageKind)] = [
            (.layoutPersistenceFailed, .libraryLayoutPersistenceFailed),
            (.itemRemovalFailed, .libraryItemRemovalFailed),
            (.updateFailed, .libraryUpdateFailed),
            (.noUpdateSources, .libraryNoUpdateSources)
        ]

        for (message, kind) in expected {
            presenter.present(message)
            let presented = try XCTUnwrap(center.currentMessage)
            XCTAssertEqual(presented.kind, kind)
            XCTAssertFalse(String(describing: presented).contains("/private/"))
            center.dismiss(messageID: presented.id)
        }
    }

    func testCategoryHistoryPresenterUsesOnlyClosedSanitizedMessages() throws {
        let center = AppMessageCenter()
        let presenter = AppMessageCategoryHistoryPresenter(messageCenter: center)
        let expected: [(CategoryHistoryMessage, AppMessageKind)] = [
            (.categoryCreateFailed, .categoryCreateFailed),
            (.categoryRenameFailed, .categoryRenameFailed),
            (.categoryDeleteFailed, .categoryDeleteFailed),
            (.categoryReorderFailed, .categoryReorderFailed),
            (.categoryAssignmentFailed, .categoryAssignmentFailed),
            (.categoryCreateAndAssignFailed, .categoryCreateAndAssignFailed),
            (.historyDeleteFailed, .historyDeleteFailed),
            (.historyClearFailed, .historyClearFailed)
        ]

        for (message, kind) in expected {
            presenter.present(message)
            let presented = try XCTUnwrap(center.currentMessage)
            XCTAssertEqual(presented.kind, kind)
            let rendered = String(describing: presented)
                + (presented.kind.presentation.detail ?? "")
            XCTAssertFalse(rendered.contains("/private/"))
            XCTAssertFalse(rendered.contains("SQLite"))
            XCTAssertFalse(rendered.contains("token="))
            center.dismiss(messageID: presented.id)
        }
    }

    private func makeScope() -> AppScope {
        AppScope(
            preparedDependencies: PreparedApplicationDependencies(
                settings: makeTestPreparedSettingsDependencies(),
                searchExecutor: MessageSearchExecutor(),
                recentSearchStore: MessageRecentStore(),
                searchDebounceMilliseconds: nil,
                presentationLogger: PresentationEventCaptureSpy(),
                browseRepositoryManager: MessageRepositoryManager(),
                repositoryManagement: makeTestRepositoryManagementDependencies(),
                browsePluginManager: MessagePluginManager(),
                browseFileOperations: MessageFileOperations()
            )
        )
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class MessageSearchExecutor: SearchPluginExecuting {
    let plugins: [SearchPluginDescriptor] = []

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
        _ = plugin
        _ = query
        _ = limit
        return []
    }

    func evictRunner(for pluginID: String) { _ = pluginID }
}

@MainActor
private final class MessageRecentStore: RecentSearchPersisting {
    func load() -> [String] { [] }
    func save(_ searches: [String]) { _ = searches }
    func clear() {}
}

@MainActor
private final class MessageRepositoryManager: BrowseRepositoryManaging {
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
private final class MessagePluginManager: BrowsePluginManaging {
    let installedPlugins: [String: InstalledPlugin] = [:]
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just(installedPlugins).eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func holdCompletionDelivery(for pluginID: String) async throws {}
    func purgeCompletionDelivery(for pluginID: String) async {}
    func removeSecrets(for pluginID: String) {}
}

@MainActor
private final class MessageFileOperations: BrowsePluginFileOperating {
    func supportsPluginFile(at url: URL) -> Bool { _ = url; return false }
    func installPluginFile(from url: URL) throws { _ = url }
    func deletePluginFile(at url: URL) throws { _ = url }
}
