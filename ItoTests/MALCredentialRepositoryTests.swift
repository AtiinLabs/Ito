import Foundation
import mal
import Security
import Testing
@testable import Ito

actor FakeMALTokenRefresher: MALTokenRefreshing {
    private var results: [Result<MALToken, any Error>]
    private let gate: AsyncTestGate?
    private(set) var refreshedTokens: [String] = []

    init(results: [Result<MALToken, any Error>], gate: AsyncTestGate? = nil) {
        self.results = results
        self.gate = gate
    }

    func refresh(_ token: MALToken) async throws -> MALToken {
        refreshedTokens.append(token.refreshToken)
        await gate?.enter()
        return try results.removeFirst().get()
    }
}

func malTestToken(_ name: String, issuedAt: Date = Date(), expiresIn: Int = 2_678_400) -> MALToken {
    MALToken(accessToken: "access-\(name)", refreshToken: "refresh-\(name)", expiresIn: expiresIn, issuedAt: issuedAt)
}

func malStoredJSON(_ token: MALToken) throws -> String {
    try #require(String(bytes: JSONEncoder().encode(token), encoding: .utf8))
}

struct MALCredentialRepositoryTests {
    private let expired = malTestToken("old", issuedAt: Date(timeIntervalSince1970: 0), expiresIn: 60)

    private func storedToken(_ store: FakeTrackerCredentialStore) async throws -> MALToken? {
        guard let json = await store.currentToken() else { return nil }
        return try JSONDecoder().decode(MALToken.self, from: Data(json.utf8))
    }

    @Test func concurrentCallersShareOneRefreshAndTheRotatedTokenIsStoredFirst() async throws {
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(expired))
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("new"))], gate: gate)
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        async let first = repository.validAccessToken()
        async let second = repository.validAccessToken()
        async let third = repository.validAccessToken()
        await gate.waitForAdmissions()
        await gate.open()

        #expect(try await [first, second, third] == ["access-new", "access-new", "access-new"])
        #expect(await refresher.refreshedTokens == ["refresh-old"])
        #expect(try await storedToken(store)?.refreshToken == "refresh-new")
    }

    @Test func cancellingTheCallerDoesNotAbandonARotationInFlight() async throws {
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(expired))
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("new"))], gate: gate)
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        let caller = Task { try await repository.validAccessToken() }
        await gate.waitForAdmissions()
        caller.cancel()
        await gate.open()
        _ = await caller.result

        #expect(try await storedToken(store)?.refreshToken == "refresh-new")
        #expect(try await repository.validAccessToken() == "access-new")
        #expect(await refresher.refreshedTokens == ["refresh-old"])
    }

    @Test func aSecond401ForAnAlreadyReplacedTokenDoesNotRotateAgain() async throws {
        let current = malTestToken("current")
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(current))
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("next"))])
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        #expect(try await repository.accessToken(replacing: "access-current") == "access-next")
        #expect(try await repository.accessToken(replacing: "access-current") == "access-next")
        #expect(await refresher.refreshedTokens == ["refresh-current"])
    }

    @Test func rejectedRefreshSignsOutButANetworkFailureKeepsTheSession() async throws {
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(expired))
        let refresher = FakeMALTokenRefresher(results: [
            .failure(MALError.networkError(URLError(.notConnectedToInternet))),
            .failure(MALError.httpError(statusCode: 401, error: "invalid_request", message: "The refresh token is invalid."))
        ])
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        await #expect(throws: MALError.networkError(URLError(.notConnectedToInternet))) {
            try await repository.validAccessToken()
        }
        #expect(try await storedToken(store)?.refreshToken == "refresh-old")

        await #expect(throws: MALCredentialRepository.CredentialError.sessionExpired) {
            try await repository.validAccessToken()
        }
        #expect(await store.currentToken() == nil)
        await #expect(throws: MALCredentialRepository.CredentialError.notSignedIn) {
            try await repository.validAccessToken()
        }
    }

    @Test func logoutDuringARefreshDiscardsTheRefreshedToken() async throws {
        let store = FakeTrackerCredentialStore(initialToken: try malStoredJSON(expired))
        let gate = AsyncTestGate()
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("new"))], gate: gate)
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        let caller = Task { try await repository.validAccessToken() }
        await gate.waitForAdmissions()
        try await repository.logout()
        await gate.open()

        await #expect(throws: MALCredentialRepository.CredentialError.notSignedIn) { try await caller.value }
        #expect(await store.currentToken() == nil)
        #expect(await store.recordedOperations().contains(.set(providerID: "myanimelist")) == false)
    }

    @Test func aRotatedTokenTheKeychainRejectedIsKeptAndWrittenLater() async throws {
        let store = FakeTrackerCredentialStore(
            initialToken: try malStoredJSON(expired),
            setResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed))]
        )
        let refresher = FakeMALTokenRefresher(results: [.success(malTestToken("new"))])
        let repository = MALCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        #expect(try await repository.validAccessToken() == "access-new")
        #expect(try await storedToken(store)?.refreshToken == "refresh-old")

        #expect(try await repository.validAccessToken() == "access-new")
        #expect(try await storedToken(store)?.refreshToken == "refresh-new")
        #expect(await refresher.refreshedTokens == ["refresh-old"])
    }

    @Test func bootstrapDefersLockedKeychainAndTreatsUnreadableDataAsSignedOut() async throws {
        let locked = MALCredentialRepository(
            store: FakeTrackerCredentialStore(readResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed))]),
            refresher: FakeMALTokenRefresher(results: [])
        )
        let corrupt = MALCredentialRepository(
            store: FakeTrackerCredentialStore(initialToken: "not json"),
            refresher: FakeMALTokenRefresher(results: [])
        )

        let lockedResult = await locked.bootstrap()
        let corruptResult = await corrupt.bootstrap()
        #expect(lockedResult.state == .retryableProtectedDataFailure)
        #expect(!lockedResult.isSignedIn)
        #expect(corruptResult.state == .ready)
        #expect(!corruptResult.isSignedIn)
    }
}
