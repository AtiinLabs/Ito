import Foundation
import mal
import Security
import Testing
@testable import Ito

/// Serves MyAnimeList responses from a closure. One handler at a time: the suite is serialized.
final class MALStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, String) -> Response)?
    nonisolated(unsafe) static var log = MALRequestLog()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let bodyString = String(bytes: body, encoding: .utf8) ?? ""
        Self.log.append(request, body: bodyString)
        DispatchQueue.global().async { [self] in
            let response = Self.handler?(request, bodyString) ?? Response(status: 500, body: "")
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

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
        let secondReadArrived = DispatchSemaphore(value: 0)
        MALStubURLProtocol.handler = { request, body in
            if request.httpMethod == "GET" {
                if server.reads() == 2 { secondReadArrived.signal() }
                return .init(status: 200, body: #"{"id": 2, "title": "Book", "status": "currently_publishing", "num_chapters": 0, "my_list_status": {"status": "reading", "num_chapters_read": \#(server.progress)}}"#)
            }
            if server.writes() == 1 {
                // An unserialized second read would arrive while this write is outstanding.
                _ = secondReadArrived.wait(timeout: .now() + 1)
            }
            server.progress = Int(body.replacingOccurrences(of: "num_chapters_read=", with: "")) ?? -1
            return .init(status: 200, body: #"{"status":"reading","num_chapters_read":\#(server.progress)}"#)
        }

        async let first: Void = tracker.updateProgress(mediaId: "manga:2", progress: 10, status: nil)
        async let second: Void = tracker.updateProgress(mediaId: "manga:2", progress: 11, status: nil)
        _ = try await (first, second)

        // Either write may start first; serialization means a read is never followed by
        // another read before its write, and progress only moves forward.
        let log = MALStubURLProtocol.log.snapshot
        let methods = log.map(\.method)
        let writes = log.filter { $0.method == "PATCH" }.map { Int($0.body.replacingOccurrences(of: "num_chapters_read=", with: "")) ?? -1 }
        #expect(Array(methods.prefix(2)) == ["GET", "PATCH"])
        #expect(methods == ["GET", "PATCH", "GET", "PATCH"] || methods == ["GET", "PATCH", "GET"])
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
}

final class MALServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var writeCount = 0
    private var storedProgress = 0

    var progress: Int {
        get { lock.withLock { storedProgress } }
        set { lock.withLock { storedProgress = newValue } }
    }

    func reads() -> Int {
        lock.withLock { readCount += 1; return readCount }
    }

    func writes() -> Int {
        lock.withLock { writeCount += 1; return writeCount }
    }
}
