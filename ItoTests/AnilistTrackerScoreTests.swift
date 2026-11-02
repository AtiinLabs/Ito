import Foundation
import Testing
@testable import Ito

/// Records only GraphQL payloads, never credentials or headers.
private final class AniListScoreURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payloads: [Data] = []
    nonisolated(unsafe) private static var viewerJSON = "null"
    nonisolated(unsafe) private static var mutationJSON = ""
    nonisolated(unsafe) private static var responseGate: (query: String, gate: AsyncTestGate)?
    nonisolated(unsafe) private static var entryResponse = (
        status: 200,
        body: "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":8.5,\"progress\":20,\"status\":\"CURRENT\"}}}"
    )

    static func configure(viewer: String, mutation: String) {
        lock.withLock {
            payloads = []
            viewerJSON = viewer
            mutationJSON = mutation
            responseGate = nil
            entryResponse = (
                status: 200,
                body: "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":8.5,\"progress\":20,\"status\":\"CURRENT\"}}}"
            )
        }
    }

    static var requests: [Data] { lock.withLock { payloads } }

    static func pauseResponses(containing query: String, gate: AsyncTestGate) {
        lock.withLock { responseGate = (query, gate) }
    }

    static func respondToEntry(status: Int = 200, body: String) {
        lock.withLock { entryResponse = (status, body) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.readBody) ?? Data()
        let responseBody = Self.lock.withLock {
            Self.payloads.append(data)
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let query = payload?["query"] as? String ?? ""
            if query.contains("mediaListOptions") {
                return "{\"data\":{\"Viewer\":\(Self.viewerJSON)}}"
            }
            if query.contains("Viewer") {
                return "{\"data\":{\"Viewer\":{\"id\":1,\"name\":\"hydrated-user\"}}}"
            }
            if query.contains("SaveMediaListEntry") {
                return Self.mutationJSON
            }
            return Self.entryResponse.body
        }
        let gate = Self.lock.withLock { () -> AsyncTestGate? in
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let setting = Self.responseGate,
                  (payload?["query"] as? String)?.contains(setting.query) == true else { return nil }
            return setting.gate
        }
        let status = Self.lock.withLock {
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (payload?["query"] as? String)?.contains("MediaList(") == true ? Self.entryResponse.status : 200
        }
        Task {
            await gate?.enter()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return body }
            body.append(buffer, count: count)
        }
    }
}

@MainActor
@Suite(.serialized)
struct AnilistTrackerScoreTests {
    private func withTracker(
        viewer: String,
        username: String? = "fixture-user",
        mutation: String = "{\"data\":{\"SaveMediaListEntry\":{\"id\":1,\"mediaId\":42,\"score\":8.5,\"progress\":7,\"status\":\"CURRENT\"}}}",
        operation: (AnilistTracker) async throws -> Void
    ) async throws {
        AniListScoreURLProtocol.configure(viewer: viewer, mutation: mutation)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AniListScoreURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "AnilistTrackerScoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let username { defaults.set(username, forKey: "anilist_username") }
        let repository = AniListCredentialRepository(
            secureStore: FakeTrackerCredentialStore(initialToken: "fixture-token"),
            legacyStore: FakeLegacyTokenStore()
        )
        let tracker = AnilistTracker(credentialRepository: repository, usernameDefaults: defaults, session: session)
        _ = try await tracker.bootstrapCredentials()
        try await operation(tracker)
    }

    private static func viewer(_ format: TrackerScoreFormat) -> String {
        "{\"name\":\"fixture-user\",\"mediaListOptions\":{\"scoreFormat\":\"\(format.rawValue)\"}}"
    }

    private func scoreSession(_ tracker: AnilistTracker, _ format: TrackerScoreFormat) -> TrackerScoreSession {
        TrackerScoreSession(format: format, identity: tracker.scoreEditingIdentity)
    }

    private func payloads() throws -> [[String: Any]] {
        try AniListScoreURLProtocol.requests.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    @Test(arguments: TrackerScoreFormat.allCases)
    func loadsNativeFormat(format: TrackerScoreFormat) async throws {
        try await withTracker(viewer: Self.viewer(format)) { tracker in
            #expect(try await tracker.getScoreFormat() == format)
            let payload = try #require(payloads().first)
            let query = try #require(payload["query"] as? String)
            #expect(query.contains("mediaListOptions { scoreFormat }"))
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test(arguments: ["null", "{}", "{\"mediaListOptions\":null}",
                      "{\"mediaListOptions\":{\"scoreFormat\":\"FUTURE_FORMAT\"}}"])
    func unsupportedFormatFailsClosed(viewer: String) async throws {
        try await withTracker(viewer: viewer) { tracker in
            await #expect(throws: TrackerScoreEditingError.unsupportedFormat) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: 7, status: "CURRENT", score: 0,
                    scoreSession: scoreSession(tracker, .point10Decimal)
                )
            }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test(arguments: [8.5, 0.0])
    func manualScoreWritesOneCombinedMutation(score: Double) async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            try await tracker.updateEntry(
                mediaId: "42", progress: 7, status: "CURRENT", score: score,
                scoreSession: scoreSession(tracker, .point10Decimal)
            )
            let requests = try payloads()
            #expect(requests.count == 2)
            let mutation = try #require(requests.last)
            #expect((mutation["query"] as? String)?.contains("SaveMediaListEntry") == true)
            let variables = try #require(mutation["variables"] as? [String: Any])
            #expect(variables["score"] as? Double == score)
            #expect(variables["mediaId"] as? Int == 42)
            #expect(variables["progress"] as? Int == 7)
            #expect(variables["status"] as? String == "CURRENT")
            #expect(variables["scoreRaw"] == nil)
        }
    }

    @Test(arguments: [-1.0, 10.1, 8.55, Double.nan, Double.infinity])
    func invalidScoreDoesNotMutate(score: Double) async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            await #expect(throws: TrackerScoreEditingError.invalidScore) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: score,
                    scoreSession: scoreSession(tracker, .point10Decimal)
                )
            }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test(arguments: TrackerScoreFormat.allCases)
    func validatesNativeRangeAndStep(format: TrackerScoreFormat) {
        #expect(format.isValid(0))
        #expect(format.isValid(format.maxScore))
        #expect(format.isValid(format.step))
        #expect(!format.isValid(format.maxScore + format.step))
        #expect(!format.isValid(format.step / 2))
        #expect(!format.isValid(-format.step))
        #expect(!format.isValid(.nan))
        #expect(!format.isValid(.infinity))
    }

    @Test func automaticProgressOmitsScoreAndStillDeduplicates() async throws {
        try await withTracker(viewer: "null") { tracker in
            try await tracker.updateProgress(mediaId: "42", progress: 21, status: "CURRENT")
            let requests = try payloads()
            #expect(requests.count == 2)
            let variables = try #require(requests.last?["variables"] as? [String: Any])
            #expect(variables["score"] == nil)
            #expect(variables["scoreRaw"] == nil)
            #expect(variables["progress"] as? Int == 21)
            try await tracker.updateProgress(mediaId: "42", progress: 7, status: "CURRENT")
            #expect(AniListScoreURLProtocol.requests.count == 3)
        }
    }

    @Test func nilManualScoreOmitsScoreAndFormatLookup() async throws {
        try await withTracker(viewer: "null") { tracker in
            try await tracker.updateEntry(
                mediaId: "42", progress: nil, status: "COMPLETED", score: nil, scoreSession: nil
            )
            let requests = try payloads()
            #expect(requests.count == 1)
            let variables = try #require(requests.first?["variables"] as? [String: Any])
            #expect(variables["score"] == nil)
            #expect(variables["status"] as? String == "COMPLETED")
        }
    }

    @Test func scoreOnlyEditOmitsProgressAndStatus() async throws {
        try await withTracker(viewer: Self.viewer(.point5)) { tracker in
            try await tracker.updateEntry(
                mediaId: "42", progress: nil, status: nil, score: 4, scoreSession: scoreSession(tracker, .point5)
            )
            let requests = try payloads()
            #expect(requests.count == 2)
            let variables = try #require(requests.last?["variables"] as? [String: Any])
            #expect(variables["score"] as? Double == 4)
            #expect(variables["progress"] == nil)
            #expect(variables["status"] == nil)
        }
    }

    @Test(arguments: [
        "{\"data\":{\"SaveMediaListEntry\":null},\"errors\":[{\"message\":\"Rejected\"}]}",
        "{\"data\":{\"SaveMediaListEntry\":{\"id\":1,\"mediaId\":99}}}"
    ])
    func unacknowledgedMutationFails(mutation: String) async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal), mutation: mutation) { tracker in
            await #expect(throws: URLError.self) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: 8.5,
                    scoreSession: scoreSession(tracker, .point10Decimal)
                )
            }
        }
    }

    @Test func missingUsernameLoadsViewerAndReadsExplicitNativeScore() async throws {
        let viewer = "{\"name\":\"hydrated-user\",\"mediaListOptions\":{\"scoreFormat\":\"POINT_10_DECIMAL\"}}"
        try await withTracker(viewer: viewer, username: nil) { tracker in
            let format = try await tracker.getScoreFormat()
            let entry = try await tracker.getMediaListEntry(mediaId: "42", scoreSession: scoreSession(tracker, format))
            #expect(entry?.progress == 20)
            #expect(entry?.score == 8.5)
            #expect(tracker.username == "hydrated-user")
            let requests = try payloads()
            #expect(requests.count == 2)
            let query = try #require(requests.last?["query"] as? String)
            #expect(query.contains("score(format: $format)"))
            let variables = try #require(requests.last?["variables"] as? [String: Any])
            #expect(variables["userName"] as? String == "hydrated-user")
            #expect(variables["format"] as? String == "POINT_10_DECIMAL")
        }
    }

    @Test func changedNativeFormatDoesNotWriteReinterpretedScore() async throws {
        try await withTracker(viewer: Self.viewer(.point10)) { tracker in
            await #expect(throws: TrackerScoreEditingError.scoreFormatChanged) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: 8, scoreSession: scoreSession(tracker, .point100)
                )
            }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test func scoreWithoutCapturedFormatFailsClosed() async throws {
        try await withTracker(viewer: Self.viewer(.point10)) { tracker in
            await #expect(throws: TrackerScoreEditingError.unsupportedFormat) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: 8, scoreSession: nil
                )
            }
            #expect(AniListScoreURLProtocol.requests.isEmpty)
        }
    }

    @Test func ordinaryEntryReadHydratesMissingUsernameWithoutScoreOptions() async throws {
        try await withTracker(viewer: "null", username: nil) { tracker in
            let entry = try await tracker.getMediaListEntry(mediaId: "42")
            #expect(entry?.progress == 20)
            #expect(tracker.username == "hydrated-user")
            let requests = try payloads()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { payload in
                (payload["query"] as? String)?.contains("mediaListOptions") == false
            })
        }
    }
}

extension AnilistTrackerScoreTests {
    @Test func replacedAccountCannotSaveDraftEvenWithSameFormat() async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            await #expect(throws: TrackerScoreEditingError.accountChanged) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: 8.5, scoreSession: captured
                )
            }
            #expect(AniListScoreURLProtocol.requests.isEmpty)
        }
    }

    @Test func restoredTokenDoesNotReviveOldDraftIdentity() async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            try await tracker.persistAuthenticatedToken("fixture-token")
            await #expect(throws: TrackerScoreEditingError.accountChanged) {
                try await tracker.getMediaListEntry(mediaId: "42", scoreSession: captured)
            }
            #expect(AniListScoreURLProtocol.requests.isEmpty)
        }
    }

    @Test func accountSwitchDuringFormatLoadPreventsMutation() async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            let gate = AsyncTestGate()
            AniListScoreURLProtocol.pauseResponses(containing: "mediaListOptions", gate: gate)
            let update = Task {
                try await tracker.updateEntry(
                    mediaId: "42", progress: nil, status: nil, score: 8.5, scoreSession: captured
                )
            }
            await gate.waitForAdmissions()
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            await gate.open()
            await #expect(throws: TrackerScoreEditingError.accountChanged) { try await update.value }
            let requests = try payloads()
            #expect(requests.count == 1)
            #expect((requests.first?["query"] as? String)?.contains("SaveMediaListEntry") == false)
        }
    }

    @Test func accountSwitchDuringEntryReadRejectsOldResult() async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            let gate = AsyncTestGate()
            AniListScoreURLProtocol.pauseResponses(containing: "score(format:", gate: gate)
            let read = Task { try await tracker.getMediaListEntry(mediaId: "42", scoreSession: captured) }
            await gate.waitForAdmissions()
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            await gate.open()
            await #expect(throws: TrackerScoreEditingError.accountChanged) { try await read.value }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test(arguments: [nil, 8.5] as [Double?])
    func accountSwitchDuringAcknowledgmentNeverReportsSuccess(score: Double?) async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            let gate = AsyncTestGate()
            AniListScoreURLProtocol.pauseResponses(containing: "SaveMediaListEntry", gate: gate)
            let update = Task {
                try await tracker.updateEntry(
                    mediaId: "42", progress: 7, status: "CURRENT", score: score, scoreSession: captured
                )
            }
            await gate.waitForAdmissions()
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            await gate.open()
            await #expect(throws: TrackerScoreEditingError.accountChanged) { try await update.value }
            let mutations = try payloads().filter {
                ($0["query"] as? String)?.contains("SaveMediaListEntry") == true
            }
            #expect(mutations.count == 1)
        }
    }

    @Test func manualProgressWithSessionDoesNotUseAutomaticDeduplication() async throws {
        try await withTracker(viewer: "null") { tracker in
            try await tracker.updateEntry(
                mediaId: "42", progress: 7, status: "CURRENT", score: nil,
                scoreSession: scoreSession(tracker, .point10Decimal)
            )
            let requests = try payloads()
            #expect(requests.count == 1)
            #expect((requests.first?["query"] as? String)?.contains("SaveMediaListEntry") == true)
            let variables = try #require(requests.first?["variables"] as? [String: Any])
            #expect(variables["progress"] as? Int == 7)
            #expect(variables["score"] == nil)
        }
    }
}

extension AnilistTrackerScoreTests {
    @Test func accountSwitchDuringUsernameHydrationPreventsEntryRead() async throws {
        try await withTracker(viewer: "null", username: nil) { tracker in
            let captured = scoreSession(tracker, .point10Decimal)
            let gate = AsyncTestGate()
            AniListScoreURLProtocol.pauseResponses(containing: "Viewer", gate: gate)
            let read = Task { try await tracker.getMediaListEntry(mediaId: "42", scoreSession: captured) }
            await gate.waitForAdmissions()
            try await tracker.persistAuthenticatedToken("fixture-account-b")
            await gate.open()
            await #expect(throws: TrackerScoreEditingError.accountChanged) { try await read.value }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test func manualProgressWithSessionRequiresAcknowledgment() async throws {
        try await withTracker(
            viewer: "null",
            mutation: "{\"data\":{\"SaveMediaListEntry\":null},\"errors\":[{\"message\":\"Rejected\"}]}"
        ) { tracker in
            await #expect(throws: URLError.self) {
                try await tracker.updateEntry(
                    mediaId: "42", progress: 7, status: "CURRENT", score: nil,
                    scoreSession: scoreSession(tracker, .point10Decimal)
                )
            }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }
}

extension AnilistTrackerScoreTests {
    @Test(arguments: [
        "{\"data\":{\"MediaList\":null},\"errors\":[{\"message\":\"Denied\",\"status\":403}]}",
        "{\"data\":{\"MediaList\":null}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":99}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7,\"progress\":null,\"status\":null}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7,\"progress\":12,\"status\":null}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7,\"progress\":null,\"status\":\"CURRENT\"}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7,\"progress\":12,\"status\":\"FUTURE_STATUS\"}}}",
        "{\"data\":{\"MediaList\":{\"id\":1,\"mediaId\":42,\"score\":7,\"progress\":-1,\"status\":\"CURRENT\"}}}"
    ])
    func manualEntryReadRejectsPartialOrMismatchedEntry(body: String) async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            AniListScoreURLProtocol.respondToEntry(body: body)
            await #expect(throws: URLError.self) {
                try await tracker.getMediaListEntry(
                    mediaId: "42", scoreSession: scoreSession(tracker, .point10Decimal)
                )
            }
        }
    }

    @Test func manualEntryNotFoundStillMeansNewEntry() async throws {
        try await withTracker(viewer: Self.viewer(.point10Decimal)) { tracker in
            AniListScoreURLProtocol.respondToEntry(
                status: 404, body: "{\"errors\":[{\"message\":\"Not Found\",\"status\":404}]}"
            )
            let entry = try await tracker.getMediaListEntry(
                mediaId: "42", scoreSession: scoreSession(tracker, .point10Decimal)
            )
            #expect(entry == nil)
        }
    }

    @Test(arguments: [
        "{\"mediaListOptions\":{\"scoreFormat\":\"POINT_10\"}}",
        "{\"name\":\"\",\"mediaListOptions\":{\"scoreFormat\":\"POINT_10\"}}",
        "{\"name\":\"  \\n \",\"mediaListOptions\":{\"scoreFormat\":\"POINT_10\"}}"
    ])
    func partialViewerCannotReuseCachedUsername(viewer: String) async throws {
        try await withTracker(viewer: viewer) { tracker in
            await #expect(throws: URLError.self) { try await tracker.getScoreFormat() }
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }

    @Test func ordinaryEntryReadRetainsNullEntryBehavior() async throws {
        try await withTracker(viewer: "null") { tracker in
            AniListScoreURLProtocol.respondToEntry(body: "{\"data\":{\"MediaList\":null}}")
            let entry = try await tracker.getMediaListEntry(mediaId: "42")
            #expect(entry == nil)
            #expect(AniListScoreURLProtocol.requests.count == 1)
        }
    }
}
