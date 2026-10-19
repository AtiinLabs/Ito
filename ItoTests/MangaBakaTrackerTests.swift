import Foundation
import MangaBakaSDK
import Testing
@testable import Ito

/// Serves MangaBaka responses from a closure. One handler at a time: the suite is serialized.
final class MangaBakaStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
    }

    struct Entry {
        let method: String
        let path: String
        let apiKey: String?
        let authorization: String?
        let body: String
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    static var log: [Entry] { lock.withLock { entries } }

    static func reset() {
        lock.withLock { entries = [] }
        handler = nil
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.withLock {
            Self.entries.append(Entry(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                apiKey: request.value(forHTTPHeaderField: "x-api-key"),
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: String(bytes: body, encoding: .utf8) ?? ""
            ))
        }
        DispatchQueue.global().async { [self] in
            let response = Self.handler?(request) ?? Response(status: 500, body: "{}")
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MangaBakaStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Reads to the end of the stream. The SDK streams request bodies, so bytes may arrive after
    /// the first read; `read` blocks until data or end of stream.
    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Answers refreshes with queued results and records the refresh tokens it was given. With a
/// gate, each refresh waits for it to open before answering.
final class FakeMangaBakaRefresher: MangaBakaTokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: AsyncTestGate?
    private var results: [Result<MangaBakaToken, any Error>]
    private var recorded: [String] = []

    init(results: [Result<MangaBakaToken, any Error>], gate: AsyncTestGate? = nil) {
        self.results = results
        self.gate = gate
    }

    var refreshedTokens: [String] {
        lock.withLock { recorded }
    }

    func refresh(_ token: MangaBakaToken) async throws -> MangaBakaToken {
        let result: Result<MangaBakaToken, any Error> = lock.withLock {
            recorded.append(token.refreshToken ?? "")
            return results.isEmpty ? .failure(MangaBakaOAuthError.invalidTokenResponse) : results.removeFirst()
        }
        await gate?.enter()
        return try result.get()
    }
}

func mangaBakaToken(_ name: String, expiresAt: Date? = nil) -> MangaBakaToken {
    MangaBakaToken(accessToken: "access-\(name)", refreshToken: "refresh-\(name)", expiresAt: expiresAt, scope: nil)
}

func mangaBakaStoredJSON(_ credential: MangaBakaCredentialRepository.StoredCredential) throws -> String {
    String(bytes: try JSONEncoder().encode(credential), encoding: .utf8) ?? ""
}

/// The stored credential, decoded: the JSON key order is not stable, so tests compare values, not strings.
func mangaBakaStoredCredential(in store: FakeTrackerCredentialStore) async throws -> MangaBakaCredentialRepository.StoredCredential? {
    try await store.token(for: "mangabaka").map {
        try JSONDecoder().decode(MangaBakaCredentialRepository.StoredCredential.self, from: Data($0.utf8))
    }
}

@MainActor
@Suite(.serialized)
struct MangaBakaTrackerTests {
    private let defaults: UserDefaults
    private let suiteName = "MangaBakaTrackerTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        MangaBakaStubURLProtocol.reset()
    }

    private struct Subject {
        let tracker: MangaBakaTracker
        let store: FakeTrackerCredentialStore
        let repository: MangaBakaCredentialRepository
    }

    private func makeTracker(
        _ credential: MangaBakaCredentialRepository.StoredCredential? = .personalAccessToken("mb-saved"),
        refresher: FakeMangaBakaRefresher = FakeMangaBakaRefresher(results: [])
    ) async throws -> Subject {
        let store = FakeTrackerCredentialStore(initialToken: try credential.map(mangaBakaStoredJSON))
        let session = MangaBakaStubURLProtocol.session()
        let repository = MangaBakaCredentialRepository(store: store, refresher: refresher)
        let tracker = MangaBakaTracker(
            credentialRepository: repository,
            oauth: MangaBakaOAuth(clientID: "test-client", redirectURI: "ito://mangabaka-callback", session: session),
            usernameDefaults: defaults,
            session: session
        )
        #expect(await tracker.bootstrapCredentials() == .ready)
        return Subject(tracker: tracker, store: store, repository: repository)
    }

    private nonisolated static func seriesJSON(id: Int = 42, state: String = "active", mergedWith: String = "null", status: String = "releasing") -> String {
        """
        {"status": 200, "data": {"id": \(id), "state": "\(state)", "merged_with": \(mergedWith),
         "canonical_url": "https://mangabaka.org/manga/\(id)", "authors": [], "artists": [], "description": null,
         "status": "\(status)", "is_licensed": false, "content_rating": "safe", "type": "manhwa",
         "original_language": "ko", "rating": 80, "last_updated_at": "2026-10-19T00:26:15.355Z",
         "source": {"anilist": {}, "my_anime_list": {}, "kitsu": {}, "manga_updates": {}, "anime_planet": {},
                    "anime_news_network": {}, "shikimori": {}},
         "publishers": [], "final_volume": null, "total_chapters": 120,
         "cover": {"x250": "https://cdn.mangabaka.dev/x250"}, "anime": {"exists": false},
         "titles": [{"language": "en", "traits": ["official"], "title": "Solo Leveling", "is_primary": true}]}}
        """
    }

    private nonisolated static func entryJSON(state: String, chapter: String) -> String {
        """
        {"status": 200, "data": {"id": 9, "series_id": 42, "user_id": "user-1", "state": "\(state)",
         "progress_chapter": \(chapter), "rating": 85, "start_date": "2024-01-05T00:00:00.000Z",
         "note": "mine", "is_private": true}}
        """
    }

    private nonisolated static let unauthorized = MangaBakaStubURLProtocol.Response(
        status: 401,
        body: #"{"status": 401, "message": "Invalid API key"}"#
    )

    /// A MangaBaka server with one series and the user's entry for it. `accepts` decides which
    /// library requests are authorized.
    private nonisolated static func server(
        entry: (status: Int, body: String),
        series: String = seriesJSON(),
        write: Int = 200,
        accepts: @escaping @Sendable (URLRequest) -> Bool = { _ in true }
    ) -> @Sendable (URLRequest) -> MangaBakaStubURLProtocol.Response {
        { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v2/series/42"?): .init(status: 200, body: series)
            case (_, "/v1/my/library/42"?) where !accepts(request): unauthorized
            case ("GET", "/v1/my/library/42"?): .init(status: entry.status, body: entry.body)
            case (_, "/v1/my/library/42"?): .init(status: write, body: #"{"status": 200, "data": true}"#)
            default: .init(status: 404, body: #"{"status": 404, "message": "NOT_FOUND"}"#)
            }
        }
    }

    private func writes() -> [MangaBakaStubURLProtocol.Entry] {
        MangaBakaStubURLProtocol.log.filter { $0.method != "GET" }
    }

    private func libraryReads() -> [MangaBakaStubURLProtocol.Entry] {
        MangaBakaStubURLProtocol.log.filter { $0.method == "GET" && $0.path == "/v1/my/library/42" }
    }

    private func json(_ body: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    // MARK: Personal Access Tokens

    @Test func signingInWithATokenChecksItAndStoresIt() async throws {
        let subject = try await makeTracker(nil)
        MangaBakaStubURLProtocol.handler = { _ in
            .init(status: 200, body: #"{"status": 200, "data": {"id": "u1", "preferred_username": "reader", "role": "user", "auth_type": "pat", "scopes": []}}"#)
        }

        try await subject.tracker.authenticate(token: "  mb-new \n")

        #expect(subject.tracker.isAuthenticated)
        #expect(subject.tracker.username == "reader")
        #expect(try await mangaBakaStoredCredential(in: subject.store) == .personalAccessToken("mb-new"))
        #expect(MangaBakaStubURLProtocol.log.map(\.path) == ["/v1/my/profile"])
        #expect(MangaBakaStubURLProtocol.log.first?.apiKey == "mb-new")
    }

    @Test func aRejectedTokenIsNotStored() async throws {
        let subject = try await makeTracker(nil)
        MangaBakaStubURLProtocol.handler = { _ in Self.unauthorized }

        await #expect(throws: TrackerTokenError.rejected) {
            try await subject.tracker.authenticate(token: "mb-wrong")
        }

        #expect(!subject.tracker.isAuthenticated)
        #expect(try await subject.store.token(for: "mangabaka") == nil)
    }

    @Test func aRejectedSavedTokenSignsOut() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, ""), accepts: { _ in false })

        await #expect(throws: MangaBakaCredentialRepository.CredentialError.tokenRejected) {
            _ = try await subject.tracker.getMediaListEntry(mediaId: "42")
        }

        #expect(!subject.tracker.isAuthenticated)
        #expect(try await subject.store.token(for: "mangabaka") == nil)
    }

    @Test func a401ForAReplacedTokenRetriesWithTheNewOne() async throws {
        let subject = try await makeTracker(.personalAccessToken("mb-old"))
        let repository = subject.repository
        MangaBakaStubURLProtocol.handler = { request in
            guard request.url?.path == "/v1/my/library/42" else {
                return .init(status: 200, body: Self.seriesJSON())
            }
            guard request.value(forHTTPHeaderField: "x-api-key") == "mb-new" else {
                // The user signs in with a new token while the old token's request is in flight.
                let saved = DispatchSemaphore(value: 0)
                Task {
                    await repository.persist(.personalAccessToken("mb-new"))
                    saved.signal()
                }
                saved.wait()
                return Self.unauthorized
            }
            return .init(status: 200, body: Self.entryJSON(state: "reading", chapter: "3"))
        }

        let entry = try await subject.tracker.getMediaListEntry(mediaId: "42")

        #expect(entry?.progress == 3)
        #expect(libraryReads().map(\.apiKey) == ["mb-old", "mb-new"])
        #expect(subject.tracker.isAuthenticated)
        #expect(try await mangaBakaStoredCredential(in: subject.store) == .personalAccessToken("mb-new"))
    }

    // MARK: OAuth

    @Test func oauthRequestsUseTheBearerTokenAndA401RefreshesOnce() async throws {
        let refresher = FakeMangaBakaRefresher(results: [.success(mangaBakaToken("new"))])
        let subject = try await makeTracker(.oauth(mangaBakaToken("old")), refresher: refresher)
        MangaBakaStubURLProtocol.handler = Self.server(
            entry: (200, Self.entryJSON(state: "reading", chapter: "3")),
            accepts: { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-new" }
        )

        let entry = try await subject.tracker.getMediaListEntry(mediaId: "42")

        #expect(entry?.status == "CURRENT")
        #expect(libraryReads().map(\.authorization) == ["Bearer access-old", "Bearer access-new"])
        #expect(libraryReads().allSatisfy { $0.apiKey == nil })
        #expect(refresher.refreshedTokens == ["refresh-old"])
        #expect(try await mangaBakaStoredCredential(in: subject.store) == .oauth(mangaBakaToken("new")))
        #expect(subject.tracker.isAuthenticated)
    }

    @Test func anExpiredOAuthTokenIsRefreshedBeforeTheRequest() async throws {
        let refresher = FakeMangaBakaRefresher(results: [.success(mangaBakaToken("new"))])
        let subject = try await makeTracker(.oauth(mangaBakaToken("old", expiresAt: Date(timeIntervalSinceNow: -60))), refresher: refresher)
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, Self.entryJSON(state: "reading", chapter: "3")))

        _ = try await subject.tracker.getMediaListEntry(mediaId: "42")

        #expect(libraryReads().map(\.authorization) == ["Bearer access-new"])
        #expect(refresher.refreshedTokens == ["refresh-old"])
    }

    @Test func aRejectedRefreshSignsOut() async throws {
        let refresher = FakeMangaBakaRefresher(results: [
            .failure(MangaBakaOAuthError.tokenRequestFailed(statusCode: 400, error: "invalid_grant", description: nil))
        ])
        let subject = try await makeTracker(.oauth(mangaBakaToken("old")), refresher: refresher)
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, ""), accepts: { _ in false })

        await #expect(throws: MangaBakaCredentialRepository.CredentialError.sessionExpired) {
            _ = try await subject.tracker.getMediaListEntry(mediaId: "42")
        }

        #expect(!subject.tracker.isAuthenticated)
        #expect(try await subject.store.token(for: "mangabaka") == nil)
    }

    @Test func aFailedRefreshKeepsTheSession() async throws {
        let refresher = FakeMangaBakaRefresher(results: [
            .failure(MangaBakaOAuthError.tokenRequestFailed(statusCode: 503, error: nil, description: nil))
        ])
        let subject = try await makeTracker(.oauth(mangaBakaToken("old")), refresher: refresher)
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, ""), accepts: { _ in false })

        await #expect(throws: MangaBakaOAuthError.self) {
            _ = try await subject.tracker.getMediaListEntry(mediaId: "42")
        }

        #expect(subject.tracker.isAuthenticated)
        #expect(try await mangaBakaStoredCredential(in: subject.store) == .oauth(mangaBakaToken("old")))
    }

    @Test func aRefreshFromAnEndedSessionLeavesTheNewSessionSignedIn() async throws {
        let gate = AsyncTestGate()
        let refresher = FakeMangaBakaRefresher(results: [.success(mangaBakaToken("stale"))], gate: gate)
        let subject = try await makeTracker(.oauth(mangaBakaToken("old", expiresAt: Date(timeIntervalSinceNow: -60))), refresher: refresher)
        MangaBakaStubURLProtocol.handler = { _ in
            .init(status: 200, body: #"{"status": 200, "data": {"id": "u1", "preferred_username": "reader", "role": "user", "auth_type": "pat", "scopes": []}}"#)
        }
        let tracker = subject.tracker
        let staleRequest = Task { try await tracker.getMediaListEntry(mediaId: "42") }
        await gate.waitForAdmissions()

        // The user signs out and in again while the old session's refresh is in flight.
        try await tracker.logout()
        try await tracker.authenticate(token: "mb-new")
        await gate.open()

        await #expect(throws: MangaBakaCredentialRepository.CredentialError.notSignedIn) {
            _ = try await staleRequest.value
        }
        #expect(tracker.isAuthenticated)
        #expect(tracker.username == "reader")
        #expect(try await mangaBakaStoredCredential(in: subject.store) == .personalAccessToken("mb-new"))
    }

    @Test func signingOutRemovesTheSessionAndRevokesIt() async throws {
        let subject = try await makeTracker(.oauth(mangaBakaToken("old")))
        MangaBakaStubURLProtocol.handler = { _ in .init(status: 200, body: "") }

        try await subject.tracker.logout()

        #expect(!subject.tracker.isAuthenticated)
        #expect(try await subject.store.token(for: "mangabaka") == nil)
        let revoke = try #require(MangaBakaStubURLProtocol.log.first)
        #expect(revoke.path == "/auth/oauth2/revoke")
        #expect(revoke.body.contains("token=refresh-old"))
    }

    @Test func aFailedRevokeStillSignsOut() async throws {
        let subject = try await makeTracker(.oauth(mangaBakaToken("old")))
        MangaBakaStubURLProtocol.handler = { _ in .init(status: 503, body: "") }

        try await subject.tracker.logout()

        #expect(!subject.tracker.isAuthenticated)
        #expect(try await subject.store.token(for: "mangabaka") == nil)
    }

    // MARK: Library writes

    @Test func automaticSyncSendsOnlyTheNewChapterProgress() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, Self.entryJSON(state: "reading", chapter: "3")))

        try await subject.tracker.updateProgress(mediaId: "42", progress: 5, status: nil)

        let write = try #require(writes().first)
        #expect(writes().count == 1)
        #expect(write.method == "PATCH")
        #expect(write.path == "/v1/my/library/42")
        #expect(try json(write.body) as NSDictionary == ["progress_chapter": 5] as NSDictionary)
        #expect(write.apiKey == "mb-saved")
        // The catalog request never carries the credential.
        let catalog = MangaBakaStubURLProtocol.log.first { $0.path == "/v2/series/42" }
        #expect(catalog?.apiKey == nil && catalog?.authorization == nil)
    }

    @Test func automaticSyncLeavesCompletedEntriesAlone() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, Self.entryJSON(state: "completed", chapter: "120")))

        try await subject.tracker.updateProgress(mediaId: "42", progress: 121, status: nil)

        #expect(writes().isEmpty)
    }

    @Test func aFailedPreReadNeverWrites() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (500, #"{"status": 500}"#))

        await #expect(throws: (any Error).self) {
            try await subject.tracker.updateProgress(mediaId: "42", progress: 5, status: "CURRENT")
        }

        #expect(writes().isEmpty)
    }

    @Test func explicitSaveCreatesAMissingEntry() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (404, #"{"status": 404, "message": "NOT_FOUND"}"#), write: 201)

        try await subject.tracker.updateProgress(mediaId: "42", progress: 3, status: "CURRENT")

        let write = try #require(writes().first)
        #expect(write.method == "POST")
        #expect(try json(write.body) as NSDictionary == ["state": "reading", "progress_chapter": 3] as NSDictionary)
    }

    @Test func aMergedSeriesIsRefused() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(
            entry: (200, Self.entryJSON(state: "reading", chapter: "3")),
            series: Self.seriesJSON(state: "merged", mergedWith: "1995")
        )

        await #expect(throws: MangaBakaTrackerError.seriesMerged(into: 1995)) {
            try await subject.tracker.updateProgress(mediaId: "42", progress: 5, status: nil)
        }
        #expect(writes().isEmpty)
    }

    // MARK: Reads and search

    @Test func entriesMapStatusProgressScoreAndDates() async throws {
        let subject = try await makeTracker()
        MangaBakaStubURLProtocol.handler = Self.server(entry: (200, Self.entryJSON(state: "rereading", chapter: "12.5")))

        let entry = try #require(try await subject.tracker.getMediaListEntry(mediaId: "42"))

        #expect(entry.status == "REPEATING")
        #expect(entry.progress == 12)
        #expect(entry.score == 8.5)
        #expect(entry.startDate == Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 5)))
    }

    @Test func searchFindsSeriesAndAnimeSearchesSendNothing() async throws {
        let subject = try await makeTracker()
        let series = Self.seriesJSON()
        MangaBakaStubURLProtocol.handler = { _ in
            let item = series.replacingOccurrences(of: #"{"status": 200, "data": "#, with: "").dropLast()
            return .init(status: 200, body: #"{"status": 200, "pagination": {"count": 1, "page": 1, "limit": 10, "next": null, "previous": null}, "data": ["# + item + "]}")
        }

        #expect(try await subject.tracker.searchMedia(title: "solo", isAnime: true).isEmpty)
        #expect(MangaBakaStubURLProtocol.log.isEmpty)

        let results = try await subject.tracker.searchMedia(title: "solo", isAnime: false)

        #expect(results.map(\.id) == ["42"])
        #expect(results.first?.title == "Solo Leveling")
        #expect(results.first?.format == "MANHWA")
        #expect(results.first?.chapters == 120)
        #expect(results.first?.isReadingFormat == true)
        #expect(MangaBakaStubURLProtocol.log.first?.apiKey == nil)
    }

    @Test func malformedIDsSendNothing() async throws {
        let subject = try await makeTracker()

        await #expect(throws: MangaBakaTrackerError.invalidMediaID) {
            try await subject.tracker.updateProgress(mediaId: "manga:42", progress: 3, status: "CURRENT")
        }
        #expect(MangaBakaStubURLProtocol.log.isEmpty)
    }
}
