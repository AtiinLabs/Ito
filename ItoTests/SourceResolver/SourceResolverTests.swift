import XCTest
@testable import Ito
import ito_runner

private actor ConcurrencyProbe {
    var activeCount = 0
    var maxActiveCount = 0

    func enter() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func exit() {
        activeCount -= 1
    }
}

private final class GateState: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var released = false
    private var blocked = false
    private var canceled = false

    func block() async throws {
        let shouldReturn = lock.withLock {
            if released {
                released = false
                return true
            }
            return false
        }
        if shouldReturn {
            try Task.checkCancellation()
            return
        }
        let isCanceled = lock.withLock {
            if canceled { return true }
            blocked = true
            return false
        }
        if isCanceled { throw CancellationError() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if self.released {
                        self.released = false
                        self.blocked = false
                        continuation.resume()
                    } else if self.canceled {
                        self.blocked = false
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.cont = continuation
                    }
                }
            }
        } onCancel: {
            let c = self.lock.withLock {
                let c = self.cont
                self.cont = nil
                self.blocked = false
                self.canceled = true
                return c
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let c = lock.withLock {
            let c = cont
            cont = nil
            released = true
            blocked = false
            return c
        }
        c?.resume()
    }

    func waitUntilBlocked() async {
        while true {
            let b = lock.withLock { blocked }
            if b { return }
            await Task.yield()
        }
    }
}

private actor FakePlugin: PluginSearching {
    let pluginID: String
    let pluginVersion: String?
    let mediaType: PluginMediaType

    var receivedQueries: [String] = []
    var mockResults: [String: [ResolvedPluginMedia]] = [:]
    var mockErrors: [String: Error] = [:]

    let gate = GateState()
    var useGate = false

    let probe: ConcurrencyProbe?
    var searchCount = 0

    init(
        pluginID: String,
        pluginVersion: String? = "1.0.0",
        mediaType: PluginMediaType = .manga,
        probe: ConcurrencyProbe? = nil
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
        self.probe = probe
    }

    func setMockResults(_ results: [ResolvedPluginMedia], forQuery query: String) {
        mockResults[query] = results
    }

    func setMockError(_ error: Error, forQuery query: String) {
        mockErrors[query] = error
    }

    func setUseGate(_ use: Bool) {
        self.useGate = use
    }

    func search(query: String) async throws -> [ResolvedPluginMedia] {
        await probe?.enter()
        do {
            searchCount += 1
            receivedQueries.append(query)

            if useGate {
                try await gate.block()
            }

            if let err = mockErrors[query] {
                throw err
            }

            let res = mockResults[query] ?? []
            await probe?.exit()
            return res
        } catch {
            await probe?.exit()
            throw error
        }
    }
}

actor CallbackTracker {
    private(set) var yieldCounts: [Int] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isResolveReturned = false

    func recordYield(count: Int) {
        yieldCounts.append(count)
        XCTAssertFalse(isResolveReturned, "Callback ran after resolver returned")

        let ready = waiters.filter { yieldCounts.count >= $0.count }
        waiters.removeAll { yieldCounts.count >= $0.count }

        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func markResolveReturned() {
        isResolveReturned = true
    }

    func waitForYieldCount(_ count: Int) async {
        if yieldCounts.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

final class SourceResolverTests: XCTestCase {

    func testZeroPlugins() async {
        let resolver = SourceResolver(plugins: [])
        let req = SourceSearchRequest(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Naruto", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let pluginsSearched = result.pluginsSearched

        XCTAssertTrue(matches.isEmpty)
        XCTAssertTrue(pluginsSearched.isEmpty)
    }

    func testOneCompatiblePlugin() async {
        let plugin = FakePlugin(pluginID: "test.plugin")
        let manga = Manga(key: "m1", title: "Naruto")
        await plugin.setMockResults([.manga(manga)], forQuery: "Naruto")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Naruto", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let pluginsSearched = result.pluginsSearched

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(pluginsSearched, ["test.plugin"])
        let queries = await plugin.receivedQueries
        XCTAssertEqual(queries, ["Naruto"])
    }

    func testOneCompatiblePluginNovel() async {
        let plugin = FakePlugin(pluginID: "test.novel.plugin", mediaType: .novel)
        let novel = Novel(key: "n1", title: "Overlord")
        await plugin.setMockResults([.novel(novel)], forQuery: "Overlord")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .novel, preferredTitle: "Overlord", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.pluginID, "test.novel.plugin")
        if case .novel(let n) = result.matches.first?.media {
            XCTAssertEqual(n.key, "n1")
        } else {
            XCTFail("Expected novel media")
        }
    }

    func testIncompatibleMediaTypeSkipped() async {
        let plugin = FakePlugin(pluginID: "test.anime.plugin", mediaType: .anime)
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Naruto", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let pluginsSkipped = result.pluginsSkipped
        let pluginsSearched = result.pluginsSearched

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(pluginsSkipped, ["test.anime.plugin"])
        XCTAssertTrue(pluginsSearched.isEmpty)
    }

    func testMaxTwoPluginsActiveConcurrently() async {
        let probe = ConcurrencyProbe()
        let p1 = FakePlugin(pluginID: "p1", probe: probe)
        let p2 = FakePlugin(pluginID: "p2", probe: probe)
        let p3 = FakePlugin(pluginID: "p3", probe: probe)
        let p4 = FakePlugin(pluginID: "p4", probe: probe)

        await p1.setUseGate(true)
        await p2.setUseGate(true)
        await p3.setUseGate(true)
        await p4.setUseGate(true)

        let resolver = SourceResolver(plugins: [p1, p2, p3, p4])
        let req = SourceSearchRequest(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let task = Task {
            await resolver.resolve(request: req) { _ in }
        }

        await p1.gate.waitUntilBlocked()
        await p2.gate.waitUntilBlocked()

        let maxActive = await probe.maxActiveCount
        XCTAssertLessThanOrEqual(maxActive, 2)

        p1.gate.release()
        await p3.gate.waitUntilBlocked()

        let maxActive2 = await probe.maxActiveCount
        XCTAssertLessThanOrEqual(maxActive2, 2)

        p2.gate.release()
        p3.gate.release()
        p4.gate.release()

        _ = await task.value
    }

    func testFallbackTriggeredOnEmptyResults() async {
        let plugin = FakePlugin(pluginID: "p1")
        await plugin.setMockResults([], forQuery: "Main Title")
        let manga = Manga(key: "m1", title: "Alt Title")
        await plugin.setMockResults([.manga(manga)], forQuery: "Alt Title")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt Title", titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches

        XCTAssertEqual(matches.count, 1)
        let queries = await plugin.receivedQueries
        XCTAssertEqual(queries, ["Main Title", "Alt Title"])
    }

    func testNoFallbackIfExactMatchFound() async {
        let plugin = FakePlugin(pluginID: "p1")
        let manga = Manga(key: "m1", title: "Main Title")
        await plugin.setMockResults([.manga(manga)], forQuery: "Main Title")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt Title", titleRomaji: nil, titleNative: nil, synonyms: [])

        _ = await resolver.resolve(request: req) { _ in }

        let queries = await plugin.receivedQueries
        XCTAssertEqual(queries, ["Main Title"])
    }

    func testNoPluginReceivesMoreThanTwoQueries() async {
        let plugin = FakePlugin(pluginID: "p1")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt1", titleRomaji: "Alt2", titleNative: "Alt3", synonyms: ["Alt4"])

        _ = await resolver.resolve(request: req) { _ in }

        let queries = await plugin.receivedQueries
        XCTAssertEqual(queries.count, 2)
    }

    func testNormalizedDuplicateFallbackNotExecuted() async {
        let plugin = FakePlugin(pluginID: "p1")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "main title", titleRomaji: nil, titleNative: nil, synonyms: [])

        _ = await resolver.resolve(request: req) { _ in }

        let queries = await plugin.receivedQueries
        XCTAssertEqual(queries.count, 1)
    }

    func testResultDeduplication() async {
        let plugin = FakePlugin(pluginID: "p1")
        let m1 = Manga(key: "m1", title: "Test")
        let m1Dup = Manga(key: "m1", title: "Test")

        await plugin.setMockResults([.manga(m1), .manga(m1Dup)], forQuery: "Test")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches

        XCTAssertEqual(matches.count, 1)
    }

    func testExactUniqueAutoConfirm() async {
        let plugin = FakePlugin(pluginID: "p1")
        let m1 = Manga(key: "m1", title: "Test Title")

        await plugin.setMockResults([.manga(m1)], forQuery: "Test Title")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test Title", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let firstDecision = result.matches.first?.decision

        XCTAssertEqual(firstDecision, .autoConfirm)
    }

    func testAmbiguousExactMatchesRequireConfirmation() async {
        let plugin = FakePlugin(pluginID: "p1")
        let m1 = Manga(key: "m1", title: "Test Title")
        let m2 = Manga(key: "m2", title: "Test Title")

        await plugin.setMockResults([.manga(m1), .manga(m2)], forQuery: "Test Title")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test Title", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].decision, .requiresConfirmation)
        XCTAssertEqual(matches[1].decision, .requiresConfirmation)
    }

    func testFuzzyMatchRequiresConfirmation() async {
        let plugin = FakePlugin(pluginID: "p1")
        let m1 = Manga(key: "m1", title: "Test Title Something")

        await plugin.setMockResults([.manga(m1)], forQuery: "Test Title")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test Title", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let firstDecision = result.matches.first?.decision

        XCTAssertEqual(firstDecision, .requiresConfirmation)
    }

    func testRejectedExactMatchDoesNotAutoConfirm() async {
        let plugin = FakePlugin(pluginID: "p1")
        let m1 = Manga(key: "m1", title: "Test Title")

        await plugin.setMockResults([.manga(m1)], forQuery: "Test Title")
        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test Title", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req, isRejected: { pid, key in
            return pid == "p1" && key == "m1"
        }) { _ in }
        let matches = result.matches

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.decision, .requiresConfirmation)
    }

    func testPluginErrorDoesNotRemoveOtherSuccessfulResults() async {
        let p1 = FakePlugin(pluginID: "p1")
        await p1.setMockError(URLError(.badServerResponse), forQuery: "Test")

        let p2 = FakePlugin(pluginID: "p2")
        let m = Manga(key: "m", title: "Test")
        await p2.setMockResults([.manga(m)], forQuery: "Test")

        let resolver = SourceResolver(plugins: [p1, p2])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let failures = result.pluginFailures

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(failures.keys.first, "p1")
    }

    func testCancellationPreventsAvoidableFutureWork() async {
        let probe = ConcurrencyProbe()
        let p1 = FakePlugin(pluginID: "p1", probe: probe)
        let p2 = FakePlugin(pluginID: "p2", probe: probe)
        let p3 = FakePlugin(pluginID: "p3", probe: probe)

        await p1.setUseGate(true)
        await p2.setUseGate(true)
        await p3.setUseGate(true)

        let resolver = SourceResolver(plugins: [p1, p2, p3])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let task = Task {
            await resolver.resolve(request: req) { _ in }
        }

        await p1.gate.waitUntilBlocked()
        await p2.gate.waitUntilBlocked()

        task.cancel()

        p1.gate.release()
        p2.gate.release()

        let result = await task.value
        let isCancelled = result.isCancelled
        XCTAssertTrue(isCancelled)

        let p3Searched = await p3.searchCount
        XCTAssertEqual(p3Searched, 0, "Plugin 3 should not have been searched after cancellation")
    }

    func testCallbacksPreserveCompletionOrder() async {
        let p1 = FakePlugin(pluginID: "p1")
        let p2 = FakePlugin(pluginID: "p2")

        let m1 = Manga(key: "m1", title: "Test")
        await p1.setMockResults([.manga(m1)], forQuery: "Test")
        await p1.setUseGate(true)

        let m2 = Manga(key: "m2", title: "Test")
        await p2.setMockResults([.manga(m2)], forQuery: "Test")
        await p2.setUseGate(true)

        let resolver = SourceResolver(plugins: [p1, p2])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let tracker = CallbackTracker()

        let resolutionTask = Task {
            await resolver.resolve(request: req) { matches in
                await tracker.recordYield(count: matches.count)
            }
        }

        await p1.gate.waitUntilBlocked()
        await p2.gate.waitUntilBlocked()

        p2.gate.release()
        await tracker.waitForYieldCount(1)

        p1.gate.release()

        _ = await resolutionTask.value
        await tracker.markResolveReturned()

        let yields = await tracker.yieldCounts
        XCTAssertEqual(yields, [1, 2], "Callbacks must preserve deterministic accumulated order, with the faster plugin completing first")
    }

    func testActiveCountReturnsToZeroAfterCancellation() async {
        let probe = ConcurrencyProbe()
        let p1 = FakePlugin(pluginID: "p1", probe: probe)
        await p1.setUseGate(true)

        let resolver = SourceResolver(plugins: [p1])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [])

        let task = Task {
            await resolver.resolve(request: req) { _ in }
        }

        await p1.gate.waitUntilBlocked()

        task.cancel()
        p1.gate.release()
        _ = await task.value

        let finalCount = await probe.activeCount
        XCTAssertEqual(finalCount, 0)
    }

    func testPrimaryErrorFollowedBySuccessfulFallback() async {
        let plugin = FakePlugin(pluginID: "p1")
        await plugin.setMockError(URLError(.badServerResponse), forQuery: "Main Title")
        let m1 = Manga(key: "m1", title: "Alt Title")
        await plugin.setMockResults([.manga(m1)], forQuery: "Alt Title")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt Title", titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let failures = result.pluginFailures

        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(failures.isEmpty)
    }

    func testEmptySuccessfulPrimaryFollowedByFallbackError() async {
        let plugin = FakePlugin(pluginID: "p1")
        await plugin.setMockResults([], forQuery: "Main Title")
        await plugin.setMockError(URLError(.badServerResponse), forQuery: "Alt Title")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt Title", titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let failures = result.pluginFailures

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(failures.keys.first, "p1")
    }

    func testPrimaryAndFallbackBothFailing() async {
        let plugin = FakePlugin(pluginID: "p1")
        await plugin.setMockError(URLError(.badServerResponse), forQuery: "Main Title")
        await plugin.setMockError(URLError(.notConnectedToInternet), forQuery: "Alt Title")

        let resolver = SourceResolver(plugins: [plugin])
        let req = SourceSearchRequest(canonicalProvider: "al", canonicalMediaId: "1", mediaType: .manga, preferredTitle: "Main Title", titleEnglish: "Alt Title", titleRomaji: nil, titleNative: nil, synonyms: [])

        let result = await resolver.resolve(request: req) { _ in }
        let matches = result.matches
        let failures = result.pluginFailures

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(failures.keys.first, "p1")
    }

    func testMatchedSourceEqualityDifferentKeysAreUnequal() {
        let m1 = Manga(key: "m1", title: "T")
        let m2 = Manga(key: "m2", title: "T")
        let s1 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .manga(m1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        let s2 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .manga(m2), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        XCTAssertNotEqual(s1, s2)
    }

    func testMatchedSourceEqualityDifferentDiscriminatorsAreUnequal() {
        let m1 = Manga(key: "m1", title: "T")
        let a1 = Anime(key: "m1", title: "T")
        let n1 = Novel(key: "m1", title: "T")
        let sm = MatchedSource(pluginID: "p", pluginVersion: nil, media: .manga(m1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        let sa = MatchedSource(pluginID: "p", pluginVersion: nil, media: .anime(a1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        let sn = MatchedSource(pluginID: "p", pluginVersion: nil, media: .novel(n1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        XCTAssertNotEqual(sm, sa)
        XCTAssertNotEqual(sm, sn)
        XCTAssertNotEqual(sa, sn)
    }

    func testMatchedSourceEqualityIdenticalIdentityAreEqual() {
        let m1 = Manga(key: "m1", title: "T1")
        let m2 = Manga(key: "m1", title: "T2")
        let s1 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .manga(m1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        let s2 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .manga(m2), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        XCTAssertEqual(s1, s2)

        let n1 = Novel(key: "n1", title: "T1")
        let n2 = Novel(key: "n1", title: "T2")
        let sn1 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .novel(n1), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        let sn2 = MatchedSource(pluginID: "p", pluginVersion: nil, media: .novel(n2), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)
        XCTAssertEqual(sn1, sn2)
    }
}
