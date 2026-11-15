import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class LibraryViewModelOfflineFacetTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A saved manga whose catalog is complete and fresh, with its two chapters saved, and the Library state that says so.
    private struct SavedSeries {
        let item: Ito.LibraryItem
        let media: MediaIdentity
        let summary: LibraryDownloadSummary
        let proof: LibraryOfflineProofSnapshot
    }

    private static func mangaPayload(id: String, title: String) throws -> Data {
        try JSONEncoder().encode(Manga(
            key: id,
            title: title,
            chapters: [
                Chapter(key: "a", volume: nil, chapter: 1, scanlator: nil, paywalled: nil),
                Chapter(key: "b", volume: nil, chapter: 2, scanlator: nil, paywalled: nil)
            ]
        ))
    }

    private func savedItem(id: String, payload: Data) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: "Series",
            coverUrl: nil,
            pluginId: "plugin",
            isAnime: false,
            pluginType: .manga,
            rawPayload: payload,
            anilistId: nil
        )
    }

    private func savedSeries(id: String, refreshedAt: Date) throws -> SavedSeries {
        let payload = try Self.mangaPayload(id: id, title: "Series")
        let item = savedItem(id: id, payload: payload)
        let media = item.mediaIdentity
        let record = LibrarySnapshotStateRecord(
            pluginId: media.pluginId,
            mediaKind: media.mediaKind,
            canonicalMediaId: media.canonicalMediaId,
            payloadSHA256: OfflineDigest.sha256Hex(payload),
            refreshedAt: refreshedAt,
            catalogScope: .allEligible,
            catalogCompleteness: .complete,
            chapterRowCount: 2
        )
        return SavedSeries(
            item: item,
            media: media,
            summary: LibraryDownloadSummary(
                savedCounts: [media: 2],
                mediaWithDownloads: [media],
                chapterStates: [media: ["a": .downloaded, "b": .downloaded]]
            ),
            proof: LibraryOfflineProofSnapshot(
                availability: .available,
                states: [media: record],
                preferences: [:]
            )
        )
    }

    func testOfflineFacetIsANDedWithTheSearchAndTheListInBothLayouts() {
        let saved = item("saved", "Saved Hero")
        let bare = item("bare", "Saved Villain")
        let other = item("other", "Other Hero")
        let first = category("first", "First")
        let second = category("second", "Second")
        let downloads = FakeLibraryDownloads(summary: LibraryDownloadSummary(
            savedCounts: [saved.mediaIdentity: 2, other.mediaIdentity: 1],
            mediaWithDownloads: [saved.mediaIdentity, other.mediaIdentity],
            chapterStates: [:]
        ))
        let subject = makeSubject(
            snapshot: snapshot(
                items: [saved, bare, other],
                categories: [first, second],
                links: [link(saved, first), link(bare, first), link(other, second)]
            ),
            downloads: downloads
        )
        XCTAssertTrue(subject.viewModel.supportsOfflineFacets)

        subject.viewModel.selectOfflineFacet(.anyVerified)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["saved", "other"])
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["first", "second"])
        XCTAssertEqual(subject.viewModel.groups[0].items.map(\.id), ["saved"])

        subject.viewModel.searchText = "Hero"
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["saved", "other"])
        subject.viewModel.searchText = "Saved"
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["saved"])
        subject.viewModel.searchText = ""

        subject.viewModel.toggleLayout()
        XCTAssertEqual(subject.viewModel.layoutStyle, .tabbed)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["saved", "other"])
        subject.viewModel.selectCategory("first")
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["first"])
        XCTAssertEqual(subject.viewModel.groups[0].items.map(\.id), ["saved"])
        subject.viewModel.searchText = "Villain"
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertTrue(subject.viewModel.showsNoResults)
    }

    func testAnyAndNoneVerifiedCountOnlyVerifiedCopies() {
        let verified = item("verified", "Verified")
        let queued = item("queued", "Queued")
        let damaged = item("damaged", "Damaged")
        let downloads = FakeLibraryDownloads(summary: LibraryDownloadSummary(
            savedCounts: [verified.mediaIdentity: 1],
            mediaWithDownloads: [verified.mediaIdentity, queued.mediaIdentity, damaged.mediaIdentity],
            chapterStates: [queued.mediaIdentity: ["q1": .queued], damaged.mediaIdentity: ["d1": .damaged]]
        ))
        let subject = makeSubject(snapshot: snapshot(items: [verified, queued, damaged]), downloads: downloads)

        subject.viewModel.selectOfflineFacet(.anyVerified)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["verified"])
        subject.viewModel.selectOfflineFacet(.noneVerified)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["queued", "damaged"])
    }

    func testAFilterWithNoMatchSaysNoResultsAndNeverShowsAnEmptyListState() {
        let bare = item("bare", "Bare")
        let first = category("first", "First")
        let second = category("second", "Second")
        let subject = makeSubject(
            snapshot: snapshot(items: [bare], categories: [first, second], links: [link(bare, first)]),
            downloads: FakeLibraryDownloads(summary: .empty)
        )
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["first"])

        subject.viewModel.selectOfflineFacet(.anyVerified)
        XCTAssertTrue(subject.viewModel.showsNoResults)
        XCTAssertTrue(subject.viewModel.groups.isEmpty)

        subject.viewModel.selectOfflineFacet(.all)
        XCTAssertFalse(subject.viewModel.showsNoResults)
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["first"])
    }

    func testTheSavedChapterFilterIsHiddenAndForcedToAllWithoutAnInventory() {
        let subject = makeSubject(snapshot: snapshot(items: [item("one", "One")]))
        XCTAssertFalse(subject.viewModel.supportsOfflineFacets)

        subject.viewModel.selectOfflineFacet(.anyVerified)
        XCTAssertEqual(subject.viewModel.offlineFacet, .all)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one"])
    }

    func testNoPreparationRunsWhileTheEntireFacetIsNotSelected() throws {
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof)
        )

        subject.viewModel.selectOfflineFacet(.anyVerified)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])
    }

    func testTheEntireFacetStaysEmptyWhileProofsAreLoadingOrUnavailable() throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let proofs = FakeOfflineProofs(.loading)
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: proofs,
            now: { clock.date }
        )

        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        XCTAssertTrue(subject.viewModel.isAwaitingOfflineProofs)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)

        proofs.publish(.unavailable)
        XCTAssertFalse(subject.viewModel.isAwaitingOfflineProofs)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertTrue(subject.viewModel.showsNoResults)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
    }

    func testAProvenSeriesIsAdmittedOnceItsPayloadIsDecodedAndLeavesAtOnceWhenACopyGoes() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let downloads = FakeLibraryDownloads(summary: series.summary)
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: downloads,
            proofs: FakeOfflineProofs(series.proof),
            now: { clock.date }
        )

        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        XCTAssertTrue(subject.viewModel.isPreparingOfflineFacet)
        await awaitProven(series.media, in: subject.viewModel)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])

        downloads.publish(LibraryDownloadSummary(
            savedCounts: [series.media: 1],
            mediaWithDownloads: [series.media],
            chapterStates: [series.media: ["a": .downloaded]]
        ))
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
    }

    func testAStalePrepareResultDoesNotAdmitASeriesWhosePayloadChangedWhileItWasHeld() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let gate = PreparationGate()
        let consumer = PreparationConsumerBarrier()
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof),
            now: { clock.date },
            prepare: { requests in await gate.prepare(requests) },
            preparationConsumed: { generation in await consumer.signal(generation) }
        )
        let publications = PublicationCounter()
        let proofSubscription = subject.viewModel.$entireSeriesProofs.dropFirst().sink { _ in
            publications.count += 1
        }
        defer { proofSubscription.cancel() }

        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        await gate.waitUntilHeld(1)
        let changed = savedItem(id: "series", payload: try Self.mangaPayload(id: "series", title: "Changed title"))
        subject.library.publish(snapshot(items: [changed]))
        await gate.waitUntilHeld(2)
        XCTAssertTrue(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)

        // Invocation zero computed a successful catalog before cancellation. Its consumer must not publish or
        // clear the loading state owned by invocation one.
        await gate.release(0)
        await consumer.waitFor(1)
        XCTAssertTrue(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
        XCTAssertEqual(publications.count, 0)

        // The newer payload still has the old proof digest, so its independently prepared result cannot prove it.
        await gate.release(1)
        await consumer.waitFor(2)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
        XCTAssertEqual(publications.count, 0)
    }

    func testSwitchingAwayWhileADecodeIsHeldPublishesNothingWhenItIsReleased() async throws {
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let gate = PreparationGate()
        let consumer = PreparationConsumerBarrier()
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof),
            prepare: { requests in await gate.prepare(requests) },
            preparationConsumed: { generation in await consumer.signal(generation) }
        )

        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        await gate.waitUntilHeld(1)
        XCTAssertTrue(subject.viewModel.isPreparingOfflineFacet)

        subject.viewModel.selectOfflineFacet(.all)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        let publications = PublicationCounter()
        let proofSubscription = subject.viewModel.$entireSeriesProofs.dropFirst().sink { _ in
            publications.count += 1
        }
        let flagSubscription = subject.viewModel.$isPreparingOfflineFacet.dropFirst().sink { _ in
            publications.count += 1
        }
        defer {
            proofSubscription.cancel()
            flagSubscription.cancel()
        }

        // This invocation already computed the successful result; wait until its consumer has rejected it.
        await gate.release(0)
        await consumer.waitFor(1)
        XCTAssertEqual(publications.count, 0)
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
    }

    func testDeinitWhileADecodeIsHeldPublishesNothing() async throws {
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let gate = PreparationGate()
        let consumer = PreparationConsumerBarrier()
        var subject: LibrarySubject? = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof),
            prepare: { requests in await gate.prepare(requests) },
            preparationConsumed: { generation in await consumer.signal(generation) }
        )
        weak var weakViewModel = subject?.viewModel
        subject?.viewModel.selectOfflineFacet(.entireKnownSeries)
        await gate.waitUntilHeld(1)

        let publications = PublicationCounter()
        let proofSubscription = subject?.viewModel.$entireSeriesProofs.dropFirst().sink { _ in
            publications.count += 1
        }
        defer { proofSubscription?.cancel() }
        subject = nil
        XCTAssertNil(weakViewModel)

        await gate.release(0)
        await consumer.waitFor(1)
        XCTAssertEqual(publications.count, 0)
    }

    func testAnIdentityHeldByTwoItemsMakesNoClaimAndAsksForNoDecode() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let gate = PreparationGate()
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item, series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof),
            now: { clock.date },
            prepare: { requests in await gate.prepare(requests) }
        )

        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        subject.library.publish(snapshot(items: [series.item, series.item]))
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        let invocations = await gate.invocations
        XCTAssertEqual(invocations, 0)
    }

    func testAPreparedDigestMismatchIsRetriedWhenALaterProofNamesTheSameBytes() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let consumer = PreparationConsumerBarrier()
        var mismatched = try XCTUnwrap(series.proof.states[series.media])
        mismatched.payloadSHA256 = String(repeating: "f", count: 64)
        let proofs = FakeOfflineProofs(LibraryOfflineProofSnapshot(
            availability: .available,
            states: [series.media: mismatched],
            preferences: [:]
        ))
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: proofs,
            now: { clock.date },
            preparationConsumed: { generation in await consumer.signal(generation) }
        )

        // The decode names another digest, so it keeps no rows for these bytes and nothing is proven.
        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        await consumer.waitFor(1)
        XCTAssertTrue(subject.viewModel.entireSeriesProofs.isEmpty)

        // A proof that names these same bytes must not be held back by the earlier decode.
        proofs.publish(series.proof)
        XCTAssertTrue(subject.viewModel.isPreparingOfflineFacet)
        await consumer.waitFor(2)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])
    }

    func testAChangedProofOrPolicyDropsAProvenSeriesAtOnceAndAdmitsItAgainWithoutADecode() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let proofs = FakeOfflineProofs(series.proof)
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: proofs,
            now: { clock.date }
        )
        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        await awaitProven(series.media, in: subject.viewModel)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])

        // A policy this build cannot read proves nothing, and the change reaches the filter synchronously.
        proofs.publish(LibraryOfflineProofSnapshot(
            availability: .available,
            states: series.proof.states,
            preferences: [series.media: Data("unreadable".utf8)]
        ))
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)

        // The readable proof is back with its bytes already decoded: admitted at once, with no decode in flight.
        proofs.publish(series.proof)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])
        XCTAssertFalse(subject.viewModel.isPreparingOfflineFacet)

        // A catalog the source no longer calls complete drops the series at once.
        var visible = try XCTUnwrap(series.proof.states[series.media])
        visible.catalogScope = .visible
        proofs.publish(LibraryOfflineProofSnapshot(
            availability: .available,
            states: [series.media: visible],
            preferences: [:]
        ))
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
    }

    func testAnInjectedClockPastTheFreshnessWindowRemovesTheSeriesAtReadTime() async throws {
        let clock = TestClock(Self.now)
        let series = try savedSeries(id: "series", refreshedAt: Self.now)
        let subject = makeSubject(
            snapshot: snapshot(items: [series.item]),
            downloads: FakeLibraryDownloads(summary: series.summary),
            proofs: FakeOfflineProofs(series.proof),
            now: { clock.date }
        )
        subject.viewModel.selectOfflineFacet(.entireKnownSeries)
        await awaitProven(series.media, in: subject.viewModel)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["series"])

        clock.date = Self.now.addingTimeInterval(SeriesOfflineCoverage.freshnessWindow + 1)
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
    }

    /// Waits, through the published values, until `media` is proven. Nothing is polled.
    private func awaitProven(_ media: MediaIdentity, in viewModel: LibraryViewModel) async {
        for await proofs in viewModel.$entireSeriesProofs.values where proofs[media] != nil {
            return
        }
    }

    private func makeSubject(
        snapshot: LibraryRootSnapshot? = nil,
        layoutRawValue: Int = LibraryLayoutStyle.sectioned.rawValue,
        downloads: (any LibraryDownloadServing)? = nil,
        proofs: (any LibraryOfflineProofServing)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        prepare: LibraryCatalogPreparer? = nil,
        preparationConsumed: @escaping @MainActor @Sendable (UInt64) async -> Void = { _ in }
    ) -> LibrarySubject {
        let library = FakeLibraryRoot(snapshot: snapshot ?? self.snapshot())
        let layout = FakeLibraryLayout(rawValue: layoutRawValue)
        let updates = FakeLibraryUpdates()
        let export = FakeLibraryExport()
        let discord = FakeLibraryDiscord()
        let plugins = FakeLibraryPlugins()
        let installer = FakeDeferredInstaller()
        let decoder = FakeDeferredDecoder()
        let messages = FakeLibraryMessages()
        let logger = PresentationEventCaptureSpy()
        let thumbnails = LibraryCoverThumbnailsFake()
        let dependencies = PreparedLibraryDependencies(
            library: library,
            layout: layout,
            updates: updates,
            export: export,
            discord: discord,
            plugins: plugins,
            installer: installer,
            payloadDecoder: decoder,
            coverThumbnails: thumbnails,
            downloads: downloads ?? UnavailableLibraryDownloads(),
            offlineProofs: proofs ?? UnavailableLibraryOfflineProofs()
        )
        return LibrarySubject(
            viewModel: LibraryViewModel(
                dependencies: dependencies,
                tabRouter: AppRouter(),
                messagePresenter: messages,
                presentationLogger: logger,
                now: now,
                prepare: prepare ?? LibraryOfflineFacetEvaluator.prepareInBackground,
                preparationConsumed: preparationConsumed
            ),
            library: library,
            layout: layout,
            updates: updates,
            export: export,
            discord: discord,
            messages: messages,
            logger: logger,
            thumbnails: thumbnails
        )
    }

    private func snapshot(
        items: [Ito.LibraryItem] = [],
        categories: [LibraryCategory] = [],
        links: [ItemCategoryLink] = [],
        isLoading: Bool = false
    ) -> LibraryRootSnapshot {
        LibraryRootSnapshot(
            items: items,
            categories: categories,
            links: links,
            isLoading: isLoading
        )
    }

    private func item(
        _ id: String,
        _ title: String,
        pluginID: String = "plugin"
    ) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: title,
            coverUrl: nil,
            pluginId: pluginID,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private func category(
        _ id: String,
        _ name: String,
        isSystem: Bool = false
    ) -> LibraryCategory {
        LibraryCategory(
            id: id,
            name: name,
            sortOrder: 0,
            isSystemCategory: isSystem,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func link(_ item: Ito.LibraryItem, _ category: LibraryCategory) -> ItemCategoryLink {
        ItemCategoryLink(
            itemId: item.id,
            categoryId: category.id,
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private final class PublicationCounter {
    var count = 0
}

@MainActor
private final class FakeLibraryDownloads: LibraryDownloadServing {
    private let subject: CurrentValueSubject<LibraryDownloadSummary, Never>
    let isInventoryAvailable = true

    init(summary: LibraryDownloadSummary) {
        subject = CurrentValueSubject(summary)
    }

    var downloadSummary: LibraryDownloadSummary { subject.value }
    var downloadSummaryPublisher: AnyPublisher<LibraryDownloadSummary, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(_ summary: LibraryDownloadSummary) {
        subject.send(summary)
    }

    func deleteDownloads(of media: MediaIdentity) async throws {
        _ = media
    }
}

@MainActor
private final class FakeOfflineProofs: LibraryOfflineProofServing {
    private let subject: CurrentValueSubject<LibraryOfflineProofSnapshot, Never>

    init(_ snapshot: LibraryOfflineProofSnapshot) {
        subject = CurrentValueSubject(snapshot)
    }

    var offlineProofSnapshot: LibraryOfflineProofSnapshot { subject.value }
    var offlineProofSnapshotPublisher: AnyPublisher<LibraryOfflineProofSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(_ snapshot: LibraryOfflineProofSnapshot) {
        subject.send(snapshot)
    }
}

/// Holds each preparation's successful result before awaiting its own release control.
private actor PreparationGate {
    private var invocationCount = 0
    private var releasedInvocations: Set<Int> = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var invocations: Int { invocationCount }

    /// Computes the result before suspending, so cancellation cannot turn a late successful decode into an empty one.
    func prepare(_ requests: [LibraryCatalogPreparation]) async -> [MediaIdentity: LibraryPreparedCatalog] {
        let prepared = LibraryOfflineFacetEvaluator.prepare(requests)
        let invocation = invocationCount
        invocationCount += 1
        resumeHeldWaiters()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if releasedInvocations.remove(invocation) != nil {
                continuation.resume()
            } else {
                releaseWaiters[invocation] = continuation
            }
        }
        return prepared
    }

    func waitUntilHeld(_ count: Int) async {
        guard invocationCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            heldWaiters.append((count, continuation))
        }
    }

    func release(_ invocation: Int) {
        if let continuation = releaseWaiters.removeValue(forKey: invocation) {
            continuation.resume()
        } else {
            releasedInvocations.insert(invocation)
        }
    }

    private func resumeHeldWaiters() {
        let ready = heldWaiters.filter { $0.target <= invocationCount }
        heldWaiters.removeAll { $0.target <= invocationCount }
        ready.forEach { $0.continuation.resume() }
    }
}

/// Signals only after the view-model consumer has completed its generation/cancellation checks and any publication.
private actor PreparationConsumerBarrier {
    private var completed: Set<UInt64> = []
    private var waiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func signal(_ generation: UInt64) {
        completed.insert(generation)
        waiters.removeValue(forKey: generation)?.forEach { $0.resume() }
    }

    func waitFor(_ generation: UInt64) async {
        guard !completed.contains(generation) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[generation, default: []].append(continuation)
        }
    }
}
