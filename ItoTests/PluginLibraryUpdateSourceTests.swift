import Foundation
import ito_runner
import Testing
@testable import Ito

/// A runner that answers every update with one fixed entry and remembers the context it was called with.
nonisolated final class FixedMediaRunner: MediaUpdateRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let entry: MediaEntry
    private var received: [NetworkOperationContext] = []

    init(_ entry: MediaEntry) {
        self.entry = entry
    }

    var contexts: [NetworkOperationContext] { lock.withLock { received } }

    func getMediaUpdate(_ entry: MediaEntry, needsDetails: Bool, context: NetworkOperationContext) async throws -> MediaEntry {
        lock.withLock { received.append(context) }
        return self.entry
    }
}

/// The one catalog fetch of a library check, through the seam that stands in for the plugin manager: the scope it
/// froze reaches the request, and the observation it returns carries the version of the copy that answered.
@MainActor
struct PluginLibraryUpdateSourceTests {
    private static let scope = String(repeating: "e", count: 32)

    private struct Harness {
        let source: PluginLibraryUpdateSource
        let runner: FixedMediaRunner
        let requests: RequestLog
    }

    /// What the `context` closure was asked for, in order.
    @MainActor
    private final class RequestLog {
        var scopes: [String?] = []
        var purposes: [NetworkOperationContext.Purpose] = []
    }

    private func harness(returning entry: MediaEntry, version: String?) -> Harness {
        let runner = FixedMediaRunner(entry)
        let requests = RequestLog()
        let source = PluginLibraryUpdateSource(
            resolve: { _ in .init(runner: runner, pluginVersion: version) },
            context: { pluginID, operation, scope in
                requests.scopes.append(scope)
                requests.purposes.append(operation.purpose)
                return NetworkOperationContext(
                    purpose: operation.purpose, sourceID: pluginID, authorizationScope: UUID(),
                    operationID: operation.operationID, policyRevision: 1, generation: UUID()
                )
            },
            installedPluginIDs: { ["plugin.test"] },
            trust: PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        )
        return Harness(source: source, runner: runner, requests: requests)
    }

    private func item(anime: Bool = false) throws -> LibraryItem {
        let payload = anime
            ? try JSONEncoder().encode(Anime(key: "series-1", title: "Series"))
            : try JSONEncoder().encode(Manga(key: "series-1", title: "Series"))
        return LibraryItem(
            id: "series-1", title: "Series", coverUrl: nil, pluginId: "plugin.test", isAnime: anime,
            pluginType: anime ? .anime : .manga, rawPayload: payload, anilistId: nil
        )
    }

    private func manga(_ chapters: [Chapter]) -> MediaEntry {
        .manga(Manga(
            key: "series-1", title: "Series", chapters: chapters,
            catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)
        ))
    }

    private func fetch(_ h: Harness, _ item: LibraryItem, scope: String?) async throws -> UpdateManager.SuccessfulUpdate {
        try await h.source.fetchUpdate(
            for: item, operation: PluginNetworkOperation(purpose: .automaticLibraryUpdate, operationID: UUID()),
            frozenScope: scope
        )
    }

    @Test func theFrozenScopeReachesTheRequestAndTheObservationCarriesTheVersionOfTheCopyThatAnswered() async throws {
        let h = harness(returning: manga(SubscriptionLedgerFixture.numbered(1...3)), version: "2.4.1")

        let update = try await fetch(h, try item(), scope: Self.scope)

        #expect(h.requests.scopes == [Self.scope])
        #expect(h.requests.purposes == [.automaticLibraryUpdate])
        #expect(h.runner.contexts.count == 1)
        #expect(update.freshCount == 3)
        let observation = try #require(update.catalog).get()
        #expect(observation.fingerprint.pluginVersion == "2.4.1")
        #expect(observation.fingerprint.sourceEpoch == Self.scope)
        #expect(observation.media == (try item()).mediaIdentity)
        #expect(observation.chapters.count == 3)
    }

    @Test func anAnswerWithoutTheInstalledVersionIsAnUnknownScopeNotAGuess() async throws {
        let h = harness(returning: manga(SubscriptionLedgerFixture.numbered(1...3)), version: nil)

        let update = try await fetch(h, try item(), scope: Self.scope)

        guard case .failure(let outcome)? = update.catalog else {
            Issue.record("a missing version must fail the observation")
            return
        }
        #expect(outcome == .unknownScope)
    }

    @Test func aCheckWithoutAFrozenScopeReadsTheLiveScopeAndReturnsNoCatalog() async throws {
        let h = harness(returning: manga(SubscriptionLedgerFixture.numbered(1...3)), version: "2.4.1")

        let update = try await fetch(h, try item(), scope: nil)

        #expect(h.requests.scopes == [nil])
        #expect(update.catalog == nil)
        #expect(update.freshCount == 3)
    }

    @Test func animeNeverGetsAnObservation() async throws {
        let h = harness(
            returning: .anime(Anime(key: "series-1", title: "Series")),
            version: "2.4.1"
        )

        let update = try await fetch(h, try item(anime: true), scope: Self.scope)

        #expect(update.catalog == nil)
        #expect(update.freshCount == 0)
    }

    @Test func anEntryTooLargeToFreezeFailsAsOversizedInsteadOfBeingStored() async throws {
        let chapters = (0...CatalogLimits.chapters).map { index in
            Chapter(key: "k\(index)", logicalUnitID: "u\(index)", readingOrder: Int64(index))
        }
        let h = harness(returning: manga(chapters), version: "2.4.1")

        let update = try await fetch(h, try item(), scope: Self.scope)

        guard case .failure(let outcome)? = update.catalog else {
            Issue.record("an oversized catalog must fail the observation")
            return
        }
        #expect(outcome == .oversizedCatalog)
    }

    @Test func theObservationOfAnAnswerIsBuiltWithoutTheNetwork() throws {
        let entry = manga(SubscriptionLedgerFixture.numbered(1...2))
        let item = try item()

        let withScope = PluginLibraryUpdateSource.observation(
            of: entry, for: item, pluginVersion: "1.0", frozenScope: Self.scope
        )
        let withoutScope = PluginLibraryUpdateSource.observation(
            of: entry, for: item, pluginVersion: "1.0", frozenScope: nil
        )

        #expect(try #require(withScope).get().fingerprint.sourceEpoch == Self.scope)
        #expect(withoutScope == nil)
    }
}
