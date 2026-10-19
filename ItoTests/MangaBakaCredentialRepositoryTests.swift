import Foundation
import MangaBakaSDK
import Security
import Testing
@testable import Ito

struct MangaBakaCredentialRepositoryTests {
    @Test func concurrent401sRefreshOnce() async throws {
        let refresher = FakeMangaBakaRefresher(results: [.success(mangaBakaToken("new")), .success(mangaBakaToken("newer"))])
        let store = FakeTrackerCredentialStore(initialToken: try mangaBakaStoredJSON(.oauth(mangaBakaToken("old"))))
        let repository = MangaBakaCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()
        let rejected = MangaBakaCredential.oauthAccessToken("access-old")

        async let first = repository.credential(replacing: rejected)
        async let second = repository.credential(replacing: rejected)
        let results = try await [first, second]

        #expect(results == [.oauthAccessToken("access-new"), .oauthAccessToken("access-new")])
        #expect(refresher.refreshedTokens == ["refresh-old"])
    }

    @Test func aTokenTheKeychainCouldNotTakeIsKeptAndWrittenLater() async throws {
        let refresher = FakeMangaBakaRefresher(results: [.success(mangaBakaToken("new"))])
        let store = FakeTrackerCredentialStore(
            initialToken: try mangaBakaStoredJSON(.oauth(mangaBakaToken("old"))),
            setResults: [.failure(.protectedDataUnavailable(errSecInteractionNotAllowed)), .success(())]
        )
        let repository = MangaBakaCredentialRepository(store: store, refresher: refresher)
        _ = await repository.bootstrap()

        let refreshed = try await repository.credential(replacing: .oauthAccessToken("access-old"))
        #expect(refreshed == .oauthAccessToken("access-new"))
        #expect(try await mangaBakaStoredCredential(in: store) == .oauth(mangaBakaToken("old")))

        // The next use writes the rotated token instead of losing it.
        #expect(try await repository.validCredential() == .oauthAccessToken("access-new"))
        #expect(try await mangaBakaStoredCredential(in: store) == .oauth(mangaBakaToken("new")))
    }

    @Test func signingOutReturnsTheOAuthTokenToRevoke() async throws {
        let store = FakeTrackerCredentialStore(initialToken: try mangaBakaStoredJSON(.oauth(mangaBakaToken("old"))))
        let repository = MangaBakaCredentialRepository(store: store, refresher: FakeMangaBakaRefresher(results: []))
        _ = await repository.bootstrap()

        #expect(try await repository.logout() == mangaBakaToken("old"))
        await #expect(throws: MangaBakaCredentialRepository.CredentialError.notSignedIn) {
            _ = try await repository.validCredential()
        }
    }
}
