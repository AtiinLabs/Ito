import Combine
import Foundation
import ito_runner
import mal
import Security
import Testing
import XCTest
@testable import Ito

/// Serves MyAnimeList responses from a closure. One handler at a time: the suite is serialized.
final class MALStubURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, String) -> Response)?
    nonisolated(unsafe) static var asyncHandler: (@Sendable (URLRequest, String) async -> Response)?
    nonisolated(unsafe) static var log = MALRequestLog()
    private let responseDelivery = TrackerTestResponseDelivery()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delivery = responseDelivery
        guard delivery.bind(to: self) else { return }
        let request = request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let bodyString = String(bytes: body, encoding: .utf8) ?? ""
        Self.log.append(request, body: bodyString)
        let handler = Self.handler
        let asyncHandler = Self.asyncHandler
        Task { [delivery, request, bodyString, handler, asyncHandler] in
            let response: Response
            if let asyncHandler {
                response = await asyncHandler(request, bodyString)
            } else {
                response = handler?(request, bodyString) ?? Response(status: 500, body: "")
            }
            delivery.finish(status: response.status, body: Data(response.body.utf8))
        }
    }

    override func stopLoading() { responseDelivery.cancel() }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MALStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class MALRequestLog: @unchecked Sendable {
    struct Entry {
        let method: String
        let path: String
        let authorization: String?
        let body: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ request: URLRequest, body: String) {
        let entry = Entry(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        )
        lock.withLock { entries.append(entry) }
    }

    var snapshot: [Entry] {
        lock.withLock { entries }
    }
}

@MainActor
@Suite(.serialized)
struct MALTrackerTests {
    private let defaults: UserDefaults
    private let suiteName = "MALTrackerTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        MALStubURLProtocol.log = MALRequestLog()
        MALStubURLProtocol.handler = nil
        MALStubURLProtocol.asyncHandler = nil
    }

    private func makeTracker(refresher: FakeMALTokenRefresher = FakeMALTokenRefresher(results: [])) async throws -> MALTracker {
        let session = MALStubURLProtocol.session()
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(malTestToken("old")))
        let tracker = MALTracker(
            credentialRepository: MALCredentialRepository(store: store, refresher: refresher),
            oauth: MALOAuth(clientID: "test-client", session: session),
            usernameDefaults: defaults,
            session: session
        )
        #expect(await tracker.bootstrapCredentials() == .ready)
        #expect(tracker.isAuthenticated)
        return tracker
    }

    private nonisolated static func animeJSON(status: String, watched: Int, extra: String = "") -> String {
        """
        {"id": 1, "title": "Show", "status": "currently_airing", "num_episodes": 12,
         "my_list_status": {"status": "\(status)", "num_episodes_watched": \(watched), "score": 9,
                            "tags": ["fav"], "comments": "note"\(extra)}}
        """
    }

    @Test func aFailedPreReadNeverWrites() async throws {
        let tracker = try await makeTracker()
        MALStubURLProtocol.handler = { _, _ in .init(status: 500, body: "") }

        await #expect(throws: MALError.self) {
            try await tracker.updateProgress(mediaId: "anime:1", progress: 5, status: nil)
        }

        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET"])
    }

    @Test func automaticSyncSendsOnlyTheNewProgress() async throws {
        let tracker = try await makeTracker()
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.animeJSON(status: "watching", watched: 3))
                : .init(status: 200, body: #"{"status":"watching","num_episodes_watched":5}"#)
        }

        try await tracker.updateProgress(mediaId: "anime:1", progress: 5, status: nil)

        let log = MALStubURLProtocol.log.snapshot
        #expect(log.map(\.method) == ["GET", "PATCH"])
        #expect(log[1].path == "/v2/anime/1/my_list_status")
        #expect(log[1].body == "num_watched_episodes=5")
        #expect(log.allSatisfy { $0.authorization == "Bearer access-old" })
    }

    @Test func automaticSyncLeavesCompletedEntriesAlone() async throws {
        let tracker = try await makeTracker()
        MALStubURLProtocol.handler = { _, _ in .init(status: 200, body: Self.animeJSON(status: "completed", watched: 12)) }

        try await tracker.updateProgress(mediaId: "anime:1", progress: 1, status: nil)

        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET"])
    }

    @Test func writesToOneEntryRunOneAtATime() async throws {
        let tracker = try await makeTracker()
        let server = MALServerState()
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, body in
            if request.httpMethod == "GET" {
                return .init(status: 200, body: #"{"id": 2, "title": "Book", "status": "currently_publishing", "num_chapters": 0, "my_list_status": {"status": "reading", "num_chapters_read": \#(server.progress)}}"#)
            }
            if server.writes() == 1 { await gate.enter() }
            server.progress = Int(body.replacingOccurrences(of: "num_chapters_read=", with: "")) ?? -1
            return .init(status: 200, body: #"{"status":"reading","num_chapters_read":\#(server.progress)}"#)
        }

        let first = Task { try await tracker.updateProgress(mediaId: "manga:2", progress: 10, status: nil) }
        await gate.waitForAdmissions()
        let second = Task { try await tracker.updateProgress(mediaId: "manga:2", progress: 11, status: nil) }
        await gate.open()
        try await first.value
        try await second.value
        let log = MALStubURLProtocol.log.snapshot
        let methods = log.map(\.method)
        let writes = log.filter { $0.method == "PATCH" }.map { Int($0.body.replacingOccurrences(of: "num_chapters_read=", with: "")) ?? -1 }
        #expect(methods == ["GET", "PATCH", "GET", "PATCH"])
        #expect(writes == writes.sorted() && Set(writes).count == writes.count)
        #expect(server.progress == 11)
    }

    @Test func a401RefreshesOnceAndRetries() async throws {
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("new"))])
        let tracker = try await makeTracker(refresher: refresher)
        MALStubURLProtocol.handler = { request, _ in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access-new"
                ? .init(status: 200, body: Self.animeJSON(status: "watching", watched: 4, extra: #", "is_rewatching": true, "start_date": "2024-01-05""#))
                : .init(status: 401, body: #"{"error":"invalid_token"}"#)
        }

        let entry = try await tracker.getMediaListEntry(mediaId: "anime:1")

        #expect(entry?.status == "REPEATING")
        #expect(entry?.progress == 4)
        #expect(entry?.score == 9)
        #expect(entry?.startDate == Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 5)))
        #expect(await refresher.refreshedTokens == ["refresh-old"])
        #expect(MALStubURLProtocol.log.snapshot.map(\.authorization) == ["Bearer access-old", "Bearer access-new"])
        #expect(tracker.isAuthenticated)
    }

    @Test func malformedIDsAndShortSearchesSendNothing() async throws {
        let tracker = try await makeTracker()

        await #expect(throws: MALTrackerError.invalidMediaID) {
            try await tracker.updateProgress(mediaId: "52991", progress: 3, status: "CURRENT")
        }
        #expect(try await tracker.searchMedia(title: " 86 ", isAnime: true).isEmpty)
        #expect(MALStubURLProtocol.log.snapshot.isEmpty)
    }

    @Test func searchReturnsKindPrefixedIDs() async throws {
        let tracker = try await makeTracker()
        MALStubURLProtocol.handler = { _, _ in
            .init(status: 200, body: #"{"data": [{"node": {"id": 2, "title": "Berserk", "alternative_titles": {"en": "Berserk"}, "media_type": "light_novel", "num_chapters": 0}}], "paging": {}}"#)
        }

        let results = try await tracker.searchMedia(title: "berserk", isAnime: false)

        #expect(results.map(\.id) == ["manga:2"])
        #expect(results.first?.format == "LIGHT_NOVEL")
        #expect(results.first?.chapters == nil)
        #expect(results.first?.isReadingFormat == true)
    }

    @Test func aLockedMALKeychainDoesNotBlockAniList() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(initialToken: "anilist-token"),
            malCredentialStore: FakeTrackerCredentialStore(readResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed))]),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: defaults
        )

        await manager.bootstrapCredentials()

        #expect(manager.credentialBootstrapState == .ready)
        #expect(manager.authenticatedProviders.map(\.identifier) == ["anilist"])
        #expect(manager.credentialBootstrapState(for: "myanimelist") == .retryableProtectedDataFailure)
        #expect(TrackerSettingsCredentialState(manager.credentialBootstrapState(for: "myanimelist")) == .deferred)

        await manager.bootstrapCredentials()
        #expect(manager.credentialBootstrapState(for: "myanimelist") == .ready)
    }

    private func scoreContext(_ tracker: MALTracker) async throws -> TrackerScoreSession {
        let format = try await tracker.getScoreFormat()
        #expect(format == .point10)
        return TrackerScoreSession(format: format, identity: tracker.scoreEditingIdentity)
    }

    private nonisolated static func scoredEntry(
        _ kind: String, score: Int = 9, status: String? = nil, progress: Int = 3, repeating: Bool = false
    ) -> String {
        let state = status ?? (kind == "anime" ? "watching" : "reading")
        let progressKey = kind == "anime" ? "num_episodes_watched" : "num_chapters_read"
        let repeatKey = kind == "anime" ? "is_rewatching" : "is_rereading"
        return """
        {"id":1,"title":"Work","num_episodes":12,"num_chapters":12,
         "my_list_status":{"status":"\(state)","\(progressKey)":\(progress),
         "\(repeatKey)":\(repeating),"score":\(score)}}
        """
    }

    @Test(arguments: ["anime", "manga"])
    func manualNativeScoreAndClear(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind))
                : .init(status: 200, body: #"{"score":8}"#)
        }
        #expect(try await tracker.getMediaListEntry(mediaId: "\(kind):1", scoreSession: context)?.score == 9)
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.last?.body == "score=8")

        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind))
                : .init(status: 200, body: #"{"score":0}"#)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 0, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.last?.body == "score=0")
    }

    @Test(arguments: ["anime", "manga"])
    func alreadyRepeatingDecreaseIsAcknowledgedThroughTheRealEditor(_ kind: String) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(initialToken: try malStoredJSON(malTestToken("old"))),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: defaults,
            malSession: MALStubURLProtocol.session()
        )
        await manager.bootstrapCredentials()
        let service = TrackerProviderService(
            trackerManager: manager, oauthAuthenticator: TrackerOAuthAuthenticatorFake()
        )
        let progressKey = kind == "anime" ? "num_episodes_watched" : "num_chapters_read"
        let requestProgressKey = kind == "anime" ? "num_watched_episodes" : progressKey
        let repeatKey = kind == "anime" ? "is_rewatching" : "is_rereading"
        let patchStarted = XCTestExpectation(description: "Authorized decrease dispatched")
        let patchGate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, _ in
            if request.httpMethod == "GET" {
                return .init(status: 200, body: Self.scoredEntry(kind, score: 7, status: "completed", progress: 8, repeating: true))
            }
            patchStarted.fulfill()
            await patchGate.enter()
            return .init(status: 200, body: """
                {"status":"completed","\(progressKey)":2,"\(repeatKey)":true,"score":7}
                """)
        }
        let model = TrackerDetailsViewModel(
            destination: trackerTestDestination(
                media: trackerTestMedia(
                    id: "\(kind):1", format: kind == "anime" ? "TV" : "MANGA",
                    episodes: kind == "anime" ? 12 : nil, chapters: kind == "manga" ? 12 : nil
                ),
                isLocallyLinked: true, providerID: "myanimelist", providerName: "MyAnimeList",
                mediaIdentity: MediaIdentity(
                    pluginId: "plugin.test", canonicalMediaId: "media.test",
                    mediaKind: kind == "anime" ? .anime : .manga
                )
            ),
            detailsService: service,
            linkStore: service,
            localProgressReader: TrackerLocalProgressReaderFake(),
            externalURLOpener: TrackerExternalURLOpenerFake(),
            messagePresenter: TrackingMessageCaptureSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        defer { model.cancelOwnedWork() }
        let loaded = XCTestExpectation(description: "Repeating entry loaded")
        let loadToken = model.$remoteEntryState.filter { $0 == .existing }.prefix(1).sink { _ in loaded.fulfill() }
        defer { loadToken.cancel() }
        model.start()
        let loadResult = await XCTWaiter.fulfillment(of: [loaded], timeout: 2)
        #expect(loadResult == .completed)
        guard loadResult == .completed else { return }
        #expect(model.status == "REPEATING")
        model.progress = "2"
        let saved = XCTestExpectation(description: "Decrease acknowledged")
        let saveToken = model.$isSaving.dropFirst().filter { !$0 }.prefix(1).sink { _ in saved.fulfill() }
        defer { saveToken.cancel() }
        model.save()
        let dispatchResult = await XCTWaiter.fulfillment(of: [patchStarted], timeout: 2)
        #expect(dispatchResult == .completed)
        #expect(model.output == nil)
        #expect(model.isSaving)
        await patchGate.open()
        guard dispatchResult == .completed else { return }
        let saveResult = await XCTWaiter.fulfillment(of: [saved], timeout: 2)
        #expect(saveResult == .completed)
        #expect(model.failure == nil)
        #expect(model.output?.kind == .saved(progress: 2, status: "REPEATING"))
        #expect(MALStubURLProtocol.log.snapshot.last?.body == "\(requestProgressKey)=2")
    }

    @Test(arguments: ["anime", "manga"])
    func unchangedAndUnsetScoresNeverPatch(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        for score in [9, 0] {
            MALStubURLProtocol.handler = { _, _ in .init(status: 200, body: Self.scoredEntry(kind, score: score)) }
            let entry = try await tracker.getMediaListEntry(mediaId: "\(kind):1", scoreSession: context)
            #expect(entry?.score == (score == 0 ? nil : Double(score)))
            try await tracker.updateEntry(
                mediaId: "\(kind):1", progress: nil, status: nil, score: Double(score), scoreSession: context
            )
            try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: nil, scoreSession: context)
        }
        #expect(MALStubURLProtocol.log.snapshot.allSatisfy { $0.method == "GET" })
    }

    @Test func invalidNativeScoresAndContextsSendNothing() async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        for score in [Double.nan, .infinity, -.infinity, -1, 11, 8.5, 8.000000001] {
            await #expect(throws: TrackerScoreEditingError.invalidScore) {
                try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: score, scoreSession: context)
            }
        }
        await #expect(throws: TrackerScoreEditingError.accountChanged) {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: nil)
        }
        for context in [
            TrackerScoreSession(format: .point100, identity: tracker.scoreEditingIdentity),
            TrackerScoreSession(format: .point10, identity: UUID())
        ] {
            await #expect(throws: TrackerScoreEditingError.self) {
                try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
            }
        }
        #expect(MALStubURLProtocol.log.snapshot.isEmpty)
    }

    @Test(arguments: ["anime", "manga"])
    func incompleteOrFailedReadsNeverMutate(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        let complete = Self.scoredEntry(kind)
        let badBodies = [
            complete.replacingOccurrences(of: #""id":1"#, with: #""id":2"#),
            complete.replacingOccurrences(of: #""score":9"#, with: #""other":9"#),
            complete.replacingOccurrences(of: kind == "anime" ? "watching" : "reading", with: "unknown"),
            complete.replacingOccurrences(of: kind == "anime" ? "num_episodes_watched" : "num_chapters_read", with: "other"),
            complete.replacingOccurrences(of: kind == "anime" ? "is_rewatching" : "is_rereading", with: "other"),
            #"{"id":1,"title":"Work","my_list_status":{"score":9}}"#
        ]
        for body in badBodies {
            MALStubURLProtocol.handler = { _, _ in .init(status: 200, body: body) }
            await #expect(throws: MALTrackerError.self) {
                try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
            }
        }
        MALStubURLProtocol.handler = { _, _ in .init(status: 503, body: "") }
        await #expect(throws: MALError.self) {
            try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        #expect(MALStubURLProtocol.log.snapshot.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["anime", "manga"])
    func everySubmittedFieldRequiresAcknowledgement(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        for response in [
            MALStubURLProtocol.Response(status: 200, body: "{}"),
            .init(status: 200, body: #"{"score":7}"#),
            .init(status: 200, body: #"{"status":"completed"}"#),
            .init(status: 200, body: "invalid"),
            .init(status: 204, body: ""),
            .init(status: 500, body: "")
        ] {
            MALStubURLProtocol.log = MALRequestLog()
            MALStubURLProtocol.handler = { request, _ in
                request.httpMethod == "GET" ? .init(status: 200, body: Self.scoredEntry(kind)) : response
            }
            await #expect(throws: (any Error).self) {
                try await tracker.updateEntry(mediaId: "\(kind):1", progress: 5, status: "COMPLETED", score: 8, scoreSession: context)
            }
            #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET", "PATCH"])
        }
    }

    @Test(arguments: ["anime", "manga"])
    func omittedStateNeverAuthorizesProgressDecrease(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind, progress: 8, repeating: true))
                : .init(status: 200, body: kind == "anime" ? #"{"num_episodes_watched":2}"# : #"{"num_chapters_read":2}"#)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: 2, status: nil, score: nil, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET"])
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: 2, status: "REPEATING", score: nil, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.last?.body == (kind == "anime" ? "num_watched_episodes=2" : "num_chapters_read=2"))
    }

    @Test(arguments: ["anime", "manga"])
    func forwardProgressOmitsScoreAndState(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind, status: "completed"))
                : .init(status: 200, body: kind == "anime" ? #"{"num_episodes_watched":12}"# : #"{"num_chapters_read":12}"#)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: 99, status: nil, score: nil, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.last?.body == (kind == "anime" ? "num_watched_episodes=12" : "num_chapters_read=12"))
    }

    @Test(arguments: ["anime", "manga"])
    func creationRequiresExplicitState(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: #"{"id":1,"title":"Work"}"#)
                : .init(status: 200, body: kind == "anime" ? #"{"status":"watching","score":8}"# : #"{"status":"reading","score":8}"#)
        }
        await #expect(throws: MALTrackerError.missingLibraryState) {
            try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: "CURRENT", score: 8, scoreSession: context)
        let fields = Set((MALStubURLProtocol.log.snapshot.last?.body ?? "").split(separator: "&").map(String.init))
        #expect(fields == ["score=8", kind == "anime" ? "status=watching" : "status=reading"])
    }

    private func makeBoundTracker(
        token: MALToken = malTestToken("old"),
        refresher: FakeMALTokenRefresher = FakeMALTokenRefresher(results: [])
    ) async throws -> (MALTracker, MALCredentialRepository) {
        let session = MALStubURLProtocol.session()
        let repository = MALCredentialRepository(
            store: FakeTrackerCredentialStore(initialToken: try malStoredJSON(token)), refresher: refresher
        )
        let tracker = MALTracker(
            credentialRepository: repository, oauth: MALOAuth(clientID: "test", session: session),
            usernameDefaults: defaults, session: session
        )
        _ = await tracker.bootstrapCredentials()
        return (tracker, repository)
    }

    @Test(arguments: ["anime", "manga"], ["GET", "PATCH"])
    func replacementDuringRequestCannotPublishOrRetry(_ kind: String, _ boundary: String) async throws {
        let (tracker, repository) = try await makeBoundTracker()
        let context = try await scoreContext(tracker)
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, _ in
            if request.httpMethod == boundary { await gate.enter() }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind))
                : .init(status: 200, body: #"{"score":8}"#)
        }
        let caller = Task {
            try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        await repository.persist(malTestToken("replacement"))
        await gate.open()
        await #expect(throws: TrackerScoreEditingError.accountChanged) { try await caller.value }
        #expect(MALStubURLProtocol.log.snapshot.allSatisfy { $0.authorization == "Bearer access-old" })
        #expect(tracker.isAuthenticated)
        #expect(tracker.scoreEditingIdentity != context.identity)
    }

    @Test(arguments: ["GET", "PATCH"])
    func replacementDuringUnauthorizedRefreshNeverRetriesWithNewAccount(_ boundary: String) async throws {
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(
            results: [.failure(MALError.httpError(statusCode: 401, error: "invalid_request", message: nil))], gate: gate
        )
        let (tracker, repository) = try await makeBoundTracker(refresher: refresher)
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == boundary
                ? .init(status: 401, body: #"{"error":"invalid_token"}"#)
                : .init(status: 200, body: Self.scoredEntry("anime"))
        }
        let caller = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        await repository.persist(malTestToken("replacement"))
        await gate.open()
        await #expect(throws: TrackerScoreEditingError.accountChanged) { try await caller.value }
        #expect(tracker.isAuthenticated)
        #expect(try await repository.validAccessToken() == "access-replacement")
        #expect(MALStubURLProtocol.log.snapshot.allSatisfy { $0.authorization == "Bearer access-old" })
        #expect(MALStubURLProtocol.log.snapshot.count == (boundary == "GET" ? 1 : 2))
    }

    @Test func replacementDuringCredentialAcquisitionRejectsDraft() async throws {
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("rotated"))], gate: gate)
        let (tracker, repository) = try await makeBoundTracker(
            token: malTestToken("old", issuedAt: Date(timeIntervalSince1970: 0), expiresIn: 60), refresher: refresher
        )
        let context = try await scoreContext(tracker)
        let caller = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        await repository.persist(malTestToken("replacement"))
        await gate.open()
        await #expect(throws: TrackerScoreEditingError.accountChanged) { try await caller.value }
        #expect(MALStubURLProtocol.log.snapshot.isEmpty)
        #expect(tracker.isAuthenticated)
    }

    @Test(arguments: [false, true])
    func normalRefreshPreservesDraftIdentity(_ expired: Bool) async throws {
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("rotated"))])
        let (tracker, _) = try await makeBoundTracker(
            token: expired ? malTestToken("old", issuedAt: Date(timeIntervalSince1970: 0), expiresIn: 60) : malTestToken("old"),
            refresher: refresher
        )
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            if !expired, request.value(forHTTPHeaderField: "Authorization") == "Bearer access-old" {
                return .init(status: 401, body: #"{"error":"invalid_token"}"#)
            }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry("anime"))
                : .init(status: 200, body: #"{"score":8}"#)
        }
        try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        #expect(tracker.scoreEditingIdentity == context.identity)
        #expect(await refresher.refreshedTokens == ["refresh-old"])
    }

    @Test(arguments: ["GET", "PATCH"])
    func cancelledActiveSaveNeverPublishesSuccess(_ boundary: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, _ in
            if request.httpMethod == boundary { await gate.enter() }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry("anime"))
                : .init(status: 200, body: #"{"score":8}"#)
        }
        let caller = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        caller.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == (boundary == "GET" ? ["GET"] : ["GET", "PATCH"]))
    }

    @Test func cancelledQueuedManualWriteDoesNotDispatchAfterAutomaticWrite() async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, _ in
            if request.httpMethod == "PATCH" { await gate.enter() }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry("anime"))
                : .init(status: 200, body: #"{"num_episodes_watched":5}"#)
        }
        let automatic = Task { try await tracker.updateProgress(mediaId: "anime:1", progress: 5, status: nil) }
        await gate.waitForAdmissions()
        let manual = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        manual.cancel()
        await gate.open()
        try await automatic.value
        await #expect(throws: CancellationError.self) { try await manual.value }
        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET", "PATCH"])
    }

    @Test func manualAndAutomaticWritesShareTheEntryChain() async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, body in
            if body == "score=8" { await gate.enter() }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry("anime"))
                : .init(status: 200, body: body == "score=8" ? #"{"score":8}"# : #"{"num_episodes_watched":5}"#)
        }
        let manual = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        let automatic = Task { try await tracker.updateProgress(mediaId: "anime:1", progress: 5, status: nil) }
        await gate.open()
        try await manual.value
        try await automatic.value
        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET", "PATCH", "GET", "PATCH"])
        #expect(MALStubURLProtocol.log.snapshot.filter { $0.method == "PATCH" }.map(\.body) == ["score=8", "num_watched_episodes=5"])
    }

    @Test(arguments: ["anime", "manga"], ["completed", "on_hold", "dropped"])
    func scoreOnlyPreservesRemoteListMetadata(_ kind: String, _ status: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind, status: status, repeating: true))
                : .init(status: 200, body: #"{"score":8}"#)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: nil, status: nil, score: 8, scoreSession: context)
        #expect(MALStubURLProtocol.log.snapshot.last?.body == "score=8")
    }

    @Test(arguments: ["anime", "manga"])
    func acknowledgementMustConfirmEachExplicitField(_ kind: String) async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        let status = kind == "anime" ? "watching" : "reading"
        let progressKey = kind == "anime" ? "num_episodes_watched" : "num_chapters_read"
        let repeatKey = kind == "anime" ? "is_rewatching" : "is_rereading"
        let acknowledgement = """
        {"status":"\(status)","\(progressKey)":5,"\(repeatKey)":true,"score":8}
        """
        let missingFields = ["status", progressKey, repeatKey, "score"]
        for field in missingFields {
            let object = try #require(JSONSerialization.jsonObject(with: Data(acknowledgement.utf8)) as? [String: Any])
            let partial = object.filter { $0.key != field }
            let body = try #require(String(bytes: JSONSerialization.data(withJSONObject: partial), encoding: .utf8))
            MALStubURLProtocol.handler = { request, _ in
                request.httpMethod == "GET"
                    ? .init(status: 200, body: Self.scoredEntry(kind, status: kind == "anime" ? "plan_to_watch" : "plan_to_read"))
                    : .init(status: 200, body: body)
            }
            await #expect(throws: MALTrackerError.unacknowledgedWrite) {
                try await tracker.updateEntry(
                    mediaId: "\(kind):1", progress: 5, status: "REPEATING", score: 8, scoreSession: context
                )
            }
        }
        MALStubURLProtocol.handler = { request, _ in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry(kind, status: kind == "anime" ? "plan_to_watch" : "plan_to_read"))
                : .init(status: 200, body: acknowledgement)
        }
        try await tracker.updateEntry(mediaId: "\(kind):1", progress: 5, status: "REPEATING", score: 8, scoreSession: context)
    }

    @Test func cancelledCredentialWaitKeepsTheSharedRotation() async throws {
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("rotated"))], gate: gate)
        let (tracker, repository) = try await makeBoundTracker(
            token: malTestToken("old", issuedAt: Date(timeIntervalSince1970: 0), expiresIn: 60), refresher: refresher
        )
        let context = try await scoreContext(tracker)
        let caller = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await gate.waitForAdmissions()
        caller.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(try await repository.validAccessToken() == "access-rotated")
        #expect(await refresher.refreshedTokens == ["refresh-old"])
        #expect(MALStubURLProtocol.log.snapshot.isEmpty)
        #expect(tracker.scoreEditingIdentity == context.identity)
    }

    @Test func replacementWhileAutomaticWriteIsOutstandingRejectsFollowingManualDraft() async throws {
        let (tracker, repository) = try await makeBoundTracker()
        let context = try await scoreContext(tracker)
        let gate = AsyncTestGate()
        MALStubURLProtocol.asyncHandler = { request, _ in
            if request.httpMethod == "PATCH" { await gate.enter() }
            return request.httpMethod == "GET"
                ? .init(status: 200, body: Self.scoredEntry("anime"))
                : .init(status: 200, body: #"{"num_episodes_watched":5}"#)
        }
        let automatic = Task { try await tracker.updateProgress(mediaId: "anime:1", progress: 5, status: nil) }
        await gate.waitForAdmissions()
        let manual = Task {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        await repository.persist(malTestToken("replacement"))
        await gate.open()
        try await automatic.value
        await #expect(throws: TrackerScoreEditingError.accountChanged) { try await manual.value }
        #expect(MALStubURLProtocol.log.snapshot.map(\.method) == ["GET", "PATCH"])
    }

    @Test func logoutImmediatelyInvalidatesManualDraft() async throws {
        let tracker = try await makeTracker()
        let context = try await scoreContext(tracker)
        try await tracker.logout()
        #expect(tracker.scoreEditingIdentity != context.identity)
        await #expect(throws: TrackerScoreEditingError.accountChanged) {
            try await tracker.updateEntry(mediaId: "anime:1", progress: nil, status: nil, score: 8, scoreSession: context)
        }
        #expect(MALStubURLProtocol.log.snapshot.isEmpty)
    }
}

final class MALServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0
    private var storedProgress = 0

    var progress: Int {
        get { lock.withLock { storedProgress } }
        set { lock.withLock { storedProgress = newValue } }
    }

    func writes() -> Int {
        lock.withLock { writeCount += 1; return writeCount }
    }
}
