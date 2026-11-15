import XCTest
import ito_runner
@testable import Ito

/// Choosing among saved uploads of one reading position from the series screen: what the menu offers, how the
/// single download sheet is shared with the batch controls, and that nothing stale ever opens a reader or keeps
/// a lease. Every wait is on an explicit gate or on the task the screen returned.
@MainActor
final class MediaDetailDownloadedAlternativeTests: XCTestCase {
    private static let pluginID = "plugin.test"
    private static let epoch = OfflineStoreFixture.epoch
    private static let anchorChapter = Chapter(key: "a", title: "A", chapter: 5, logicalUnitID: "unit-1")

    private enum Phase: Equatable { case idle, loading, choosing, acquiring, failed, handingOff }

    private func phase(_ viewModel: MediaDetailViewModel<Manga>) -> Phase {
        switch viewModel.downloadedAlternativeState {
        case .idle: .idle
        case .loading: .loading
        case .choosing: .choosing
        case .acquiring: .acquiring
        case .failed: .failed
        case .handingOff: .handingOff
        }
    }

    private func failure(_ viewModel: MediaDetailViewModel<Manga>) -> DownloadedAlternativeFailure? {
        switch viewModel.downloadedAlternativeState {
        case .failed(_, let failure): failure
        case .choosing(_, _, _, let failure): failure
        default: nil
        }
    }

    // MARK: - Doubles

    @MainActor private final class DestinationLog {
        var candidateIDs: [String] = []
        var failure: (any Error)?
    }

    @MainActor private final class EpochBox {
        var current: String? = MediaDetailDownloadedAlternativeTests.epoch
        var failure: (any Error)?
        func read() throws -> String? {
            if let failure { throw failure }
            return current
        }
    }

    /// One gate per call, in order: the first call passes the first gate, and so on.
    @MainActor private final class GateSequence {
        let gates: [DownloadTestGate]
        private var next = 0
        init(count: Int) { gates = (0..<count).map { _ in DownloadTestGate() } }
        func pass() async throws {
            let gate = gates[next]
            next += 1
            try await gate.pass()
        }
    }

    private struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let downloads: MediaDetailDownloadsFake
        let route: MediaRouteHarness<Manga>
        let progress: MediaDetailProgressFake
        let baseline: MediaDetailBaselineFake
        let messages: MediaDetailMessageSpy
        let destinations: DestinationLog
        let epoch: EpochBox
    }

    private func makeSubject(chapters: [Chapter]? = nil, saved: Bool = true) -> Subject {
        let media = Manga(
            key: "series-1",
            title: "Series One",
            chapters: chapters ?? [
                Self.anchorChapter,
                Chapter(key: "locked", chapter: 6, paywalled: true, logicalUnitID: "unit-1"),
                Chapter(key: "no-unit", chapter: 7)
            ]
        )
        let route = MediaRouteHarness<Manga>()
        let downloads = MediaDetailDownloadsFake()
        let epoch = EpochBox()
        downloads.alternativeEpoch = { _ in try epoch.read() }
        let destinations = DestinationLog()
        let progress = MediaDetailProgressFake()
        let baseline = MediaDetailBaselineFake()
        let messages = MediaDetailMessageSpy()
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: { try await route.load($0, operation: $1) },
            searchForRelink: nil,
            makeReaderDestination: { parent, selected in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(parent),
                    chapter: selected
                )
            },
            makeDownloadedAlternativeDestination: { media, candidate, lease in
                destinations.candidateIDs.append(candidate.id)
                if let failure = destinations.failure { throw failure }
                return try .downloadedAlternative(
                    candidate,
                    lease: lease,
                    of: .manga(media),
                    remote: nil,
                    pluginID: Self.pluginID
                )
            }
        )
        let dependencies = PreparedMediaDetailDependencies(
            library: MediaDetailLibraryFake(state: MediaDetailLibraryState(
                records: saved
                    ? [MediaDetailLibraryRecord(itemID: "series-1", pluginID: Self.pluginID, mediaKind: .manga)]
                    : [],
                hasCustomCategories: false
            )),
            progress: progress,
            tracker: MediaDetailTrackerFake(),
            theme: MediaDetailThemeFake(),
            relink: MediaDetailRelinkFake(),
            baseline: baseline,
            settings: MediaDetailSettingsFake(alwaysShowCategoryPicker: false, autoSyncTrackersToLocal: true),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake(),
            downloads: downloads
        )
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: dependencies,
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
        return Subject(
            viewModel: viewModel,
            downloads: downloads,
            route: route,
            progress: progress,
            baseline: baseline,
            messages: messages,
            destinations: destinations,
            epoch: epoch
        )
    }

    private func candidate(_ key: String, group: String? = nil, groupID: String? = nil) -> DownloadedChapterAlternative {
        DownloadedChapterAlternative(
            edition: OfflineChapterEdition(
                pluginId: Self.pluginID,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: key
            ),
            metadataOrigin: MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-1", mediaKind: .manga),
            versionID: "version-\(key)",
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshotSHA256: String(repeating: "b", count: 64),
            contentKind: .images,
            chapter: .upload(key, group: group, groupID: groupID)
        )
    }

    private func listing(
        _ anchor: OfflineChapterAlternativeAnchor,
        _ candidates: [DownloadedChapterAlternative],
        epoch: String? = MediaDetailDownloadedAlternativeTests.epoch
    ) -> DownloadedChapterAlternatives {
        DownloadedChapterAlternatives(
            anchor: anchor,
            metadataOrigin: MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-1", mediaKind: .manga),
            logicalUnitID: "unit-1",
            sourceEpoch: epoch,
            candidates: candidates
        )
    }

    private func presentationID(_ viewModel: MediaDetailViewModel<Manga>) throws -> UUID {
        try XCTUnwrap(viewModel.downloadedAlternativeState.context?.id)
    }

    private func isAlternativeSheet(_ viewModel: MediaDetailViewModel<Manga>) -> Bool {
        if case .downloadedAlternatives? = viewModel.downloadSheet { return true }
        return false
    }

    /// Lists the real copy and selects it. Returns the presentation id.
    private func choose(_ subject: Subject, _ real: RealAlternativeFixture) async throws -> UUID {
        subject.downloads.alternativeLookup = { _ in real.lookupResult }
        await subject.viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        let id = try presentationID(subject.viewModel)
        subject.viewModel.selectDownloadedAlternative(real.candidate.id, presentationID: id)
        return id
    }

    private func assertNoEffects(_ subject: Subject, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(subject.progress.readRequests.isEmpty, file: file, line: line)
        XCTAssertTrue(subject.progress.markRequests.isEmpty, file: file, line: line)
        XCTAssertTrue(subject.baseline.requests.isEmpty, file: file, line: line)
        XCTAssertTrue(subject.downloads.downloadRequests.isEmpty, file: file, line: line)
        XCTAssertTrue(subject.downloads.editionCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty, file: file, line: line)
        XCTAssertEqual(subject.downloads.preferenceWriteCount, 0, file: file, line: line)
    }

    // MARK: - 19, 20

    func testTheMenuOffersTheChooserForARowWithALogicalUnitWithoutAQueueAStateOrALiveCopyOfAnythingElse() async throws {
        let subject = makeSubject()
        let viewModel = subject.viewModel

        XCTAssertEqual(viewModel.downloadActions(for: Self.anchorChapter), [.download, .chooseDownloadedAlternative])
        XCTAssertEqual(
            makeSubject(saved: false).viewModel.downloadActions(for: Self.anchorChapter),
            [.chooseDownloadedAlternative]
        )
        // A locked row and a row without a logical unit are not eligible.
        XCTAssertEqual(viewModel.downloadActions(for: Chapter(key: "locked", chapter: 6, paywalled: true, logicalUnitID: "unit-1")), [])
        XCTAssertEqual(viewModel.downloadActions(for: Chapter(key: "no-unit", chapter: 7)), [.download])
        // The menu reads the row alone; a tap on a row the list no longer has finds nothing to look up.
        let unlisted = Chapter(key: "unlisted", chapter: 9, logicalUnitID: "unit-1")
        XCTAssertEqual(viewModel.downloadActions(for: unlisted), [.download, .chooseDownloadedAlternative])
        subject.downloads.alternativeLookup = { [self] anchor in listing(anchor, []) }
        await viewModel.showDownloadedAlternatives(for: unlisted).value
        XCTAssertEqual(phase(viewModel), .idle)
        XCTAssertEqual(subject.downloads.alternativeLookupCount, 0)

        subject.downloads.alternativeLookup = { [self] anchor in listing(anchor, []) }
        let task = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        XCTAssertEqual(phase(viewModel), .loading)
        XCTAssertTrue(isAlternativeSheet(viewModel))
        await task.value

        XCTAssertEqual(phase(viewModel), .choosing)
        XCTAssertEqual(subject.downloads.alternativeLookupCount, 1)
        XCTAssertEqual(subject.downloads.alternativeOpenCount, 0)
        assertNoEffects(subject)
    }

    func testTheMenuOffersNothingWhereDownloadsAreUnavailableAndNothingOpensFromTheUnavailableSeam() {
        let offline = makeUnavailableSubject()

        XCTAssertFalse(offline.showsDownloadControls)
        XCTAssertEqual(offline.downloadActions(for: Self.anchorChapter), [])
        offline.showDownloadedAlternatives(for: Self.anchorChapter)
        XCTAssertEqual(phase(offline), .idle)
        XCTAssertNil(offline.downloadSheet)
    }

    private func makeUnavailableSubject() -> MediaDetailViewModel<Manga> {
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: nil,
            searchForRelink: nil,
            makeReaderDestination: { parent, selected in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(parent),
                    chapter: selected
                )
            },
            makeDownloadedAlternativeDestination: { _, _, _ in throw UnexpectedDownloadedAlternativeOpening() }
        )
        return MediaDetailViewModel(
            media: Manga(key: "series-1", title: "Series One", chapters: [Self.anchorChapter]),
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: PreparedMediaDetailDependencies(
                library: MediaDetailLibraryFake(),
                progress: MediaDetailProgressFake(),
                tracker: MediaDetailTrackerFake(),
                theme: MediaDetailThemeFake(),
                relink: MediaDetailRelinkFake(),
                baseline: MediaDetailBaselineFake(),
                settings: MediaDetailSettingsFake(),
                pluginMetadata: MediaDetailPluginMetadataFake(),
                discord: MediaDetailDiscordFake(),
                downloads: UnavailableMediaDetailDownloads()
            ),
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
    }

    func testSeveralCandidatesNeedAChoiceOneStillNeedsConfirmationAndAnEmptyListCannotBeConfirmed() async throws {
        let subject = makeSubject()
        let viewModel = subject.viewModel
        let b = candidate("b", group: "Group B")
        let c = candidate("c", group: "Group C")
        subject.downloads.alternativeLookup = { [self] anchor in listing(anchor, [b, c]) }

        await viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        let id = try presentationID(viewModel)

        guard case .choosing(_, let candidates, let selected, _) = viewModel.downloadedAlternativeState else {
            return XCTFail("The list is open")
        }
        XCTAssertEqual(candidates.map(\.id), ["version-b", "version-c"])
        XCTAssertNil(selected)
        XCTAssertFalse(DownloadedAlternativeSheet.canConfirm(viewModel.downloadedAlternativeState))
        // Confirming without a selection starts nothing.
        await viewModel.confirmDownloadedAlternative(presentationID: id).value
        XCTAssertEqual(subject.downloads.alternativeOpenCount, 0)
        XCTAssertEqual(phase(viewModel), .choosing)

        viewModel.selectDownloadedAlternative("version-c", presentationID: id)
        XCTAssertTrue(DownloadedAlternativeSheet.canConfirm(viewModel.downloadedAlternativeState))

        // One candidate is not opened by being the only one.
        let single = makeSubject()
        single.downloads.alternativeLookup = { [self] anchor in listing(anchor, [b]) }
        await single.viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        guard case .choosing(_, _, let singleSelection, _) = single.viewModel.downloadedAlternativeState else {
            return XCTFail("The list is open")
        }
        XCTAssertNil(singleSelection)
        XCTAssertEqual(single.downloads.alternativeOpenCount, 0)

        // An empty result is truthful and has nothing to confirm.
        let empty = makeSubject()
        empty.downloads.alternativeLookup = { [self] anchor in listing(anchor, []) }
        await empty.viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        guard case .choosing(_, let none, _, nil) = empty.viewModel.downloadedAlternativeState else {
            return XCTFail("An empty list is a result, not a failure")
        }
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(DownloadedAlternativeSheet.canConfirm(empty.viewModel.downloadedAlternativeState))
    }

    // MARK: - 21

    func testDismissingDuringTheLookupLeavesNothingToReopenAndALaterPresentationOwnsItsSpinner() async throws {
        let subject = makeSubject()
        let viewModel = subject.viewModel
        let gates = GateSequence(count: 3)
        subject.downloads.alternativeLookup = { [self] anchor in
            try await gates.pass()
            return listing(anchor, [candidate("b")])
        }

        let first = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        await gates.gates[0].awaitArrival()
        viewModel.dismissDownloadSheet()
        XCTAssertEqual(phase(viewModel), .idle)
        XCTAssertNil(viewModel.downloadSheet)
        await gates.gates[0].release()
        await first.value
        // The late answer neither reopens the sheet nor leaves output behind.
        XCTAssertEqual(phase(viewModel), .idle)
        XCTAssertNil(viewModel.downloadSheet)

        // Another presentation of the same series: the older completion cannot clear its spinner.
        let second = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        await gates.gates[1].awaitArrival()
        let secondID = try presentationID(viewModel)
        let third = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        await gates.gates[2].awaitArrival()
        let thirdID = try presentationID(viewModel)
        XCTAssertNotEqual(secondID, thirdID)
        await gates.gates[1].release()
        await second.value
        XCTAssertEqual(phase(viewModel), .loading)
        XCTAssertEqual(try presentationID(viewModel), thirdID)

        await gates.gates[2].release()
        await third.value
        XCTAssertEqual(phase(viewModel), .choosing)
        XCTAssertEqual(try presentationID(viewModel), thirdID)
    }

    // MARK: - 22, 23

    func testCancellingDuringAcquisitionDropsALateLeaseAndPublishesNothing() async throws {
        let real = try await RealAlternativeFixture.make()
        let subject = makeSubject()
        let viewModel = subject.viewModel
        let gates = GateSequence(count: 1)
        subject.downloads.alternativeOpen = { candidate, epoch in
            let lease = try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
            // A task that ignores cancellation still hands its lease back.
            try? await gates.pass()
            return lease
        }
        let id = try await choose(subject, real)

        let task = viewModel.confirmDownloadedAlternative(presentationID: id)
        await gates.gates[0].awaitArrival()
        XCTAssertEqual(phase(viewModel), .acquiring)
        XCTAssertTrue(real.store.leases.isLeased(versionId: real.versionB))
        viewModel.dismissDownloadSheet()
        await task.value
        await real.store.leases.awaitReclamations()

        XCTAssertEqual(phase(viewModel), .idle)
        XCTAssertNil(viewModel.downloadSheet)
        XCTAssertNil(viewModel.readerDestination)
        XCTAssertTrue(subject.destinations.candidateIDs.isEmpty)
        XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB))
        assertNoEffects(subject)
    }

    func testConfirmingTwiceAcquiresOnceAndForgedIdentifiersDoNothing() async throws {
        let real = try await RealAlternativeFixture.make()
        let subject = makeSubject()
        let viewModel = subject.viewModel
        let gates = GateSequence(count: 1)
        subject.downloads.alternativeOpen = { candidate, epoch in
            try await gates.pass()
            return try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
        }
        subject.downloads.alternativeLookup = { _ in real.lookupResult }
        await viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        let id = try presentationID(viewModel)

        // A forged candidate and a forged presentation do nothing.
        viewModel.selectDownloadedAlternative("forged", presentationID: id)
        viewModel.selectDownloadedAlternative(real.candidate.id, presentationID: UUID())
        guard case .choosing(_, _, let selected, _) = viewModel.downloadedAlternativeState else {
            return XCTFail("The list is open")
        }
        XCTAssertNil(selected)
        viewModel.selectDownloadedAlternative(real.candidate.id, presentationID: id)
        await viewModel.confirmDownloadedAlternative(presentationID: UUID()).value
        XCTAssertEqual(subject.downloads.alternativeOpenCount, 0)

        let first = viewModel.confirmDownloadedAlternative(presentationID: id)
        await gates.gates[0].awaitArrival()
        await viewModel.confirmDownloadedAlternative(presentationID: id).value
        XCTAssertEqual(subject.downloads.alternativeOpenCount, 1)

        await gates.gates[0].release()
        await first.value
        XCTAssertEqual(phase(viewModel), .handingOff)
        await viewModel.confirmDownloadedAlternative(presentationID: id).value
        XCTAssertEqual(subject.downloads.alternativeOpenCount, 1)
        XCTAssertEqual(subject.destinations.candidateIDs, [real.candidate.id])
    }

    // MARK: - 24

    private enum Lifecycle: CaseIterable {
        case refresh, sceneInactive, disappear, ordinarySelection, readOnline, supersedingBatchAction
    }

    private func perform(_ event: Lifecycle, on subject: Subject) async {
        let viewModel = subject.viewModel
        switch event {
        case .refresh: await viewModel.refresh()
        case .sceneInactive: viewModel.cancelDownloadedAlternatives()
        case .disappear:
            viewModel.appear()
            viewModel.disappear()
        case .ordinarySelection: viewModel.selectChapter(Self.anchorChapter)
        case .readOnline: viewModel.readOnlineThisTime(Self.anchorChapter)
        case .supersedingBatchAction: viewModel.openEditionChooser()
        }
    }

    func testEveryLifecycleEventInvalidatesALookupInFlight() async throws {
        for event in Lifecycle.allCases {
            let subject = makeSubject()
            let viewModel = subject.viewModel
            let gates = GateSequence(count: 1)
            subject.downloads.alternativeLookup = { [self] anchor in
                try? await gates.pass()
                return listing(anchor, [candidate("b")])
            }
            let task = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
            await gates.gates[0].awaitArrival()

            await perform(event, on: subject)
            await gates.gates[0].release()
            await task.value

            XCTAssertEqual(phase(viewModel), .idle, "\(event)")
            XCTAssertFalse(isAlternativeSheet(viewModel), "\(event)")
            XCTAssertTrue(subject.destinations.candidateIDs.isEmpty, "\(event)")
        }
    }

    func testEveryLifecycleEventInvalidatesAnAcquisitionInFlightAndItsLateLease() async throws {
        for event in Lifecycle.allCases {
            let real = try await RealAlternativeFixture.make()
            let subject = makeSubject()
            let viewModel = subject.viewModel
            let gates = GateSequence(count: 1)
            subject.downloads.alternativeOpen = { candidate, epoch in
                let lease = try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
                try? await gates.pass()
                return lease
            }
            let id = try await choose(subject, real)
            let task = viewModel.confirmDownloadedAlternative(presentationID: id)
            await gates.gates[0].awaitArrival()

            await perform(event, on: subject)
            await gates.gates[0].release()
            await task.value
            await real.store.leases.awaitReclamations()

            XCTAssertEqual(phase(viewModel), .idle, "\(event)")
            XCTAssertTrue(subject.destinations.candidateIDs.isEmpty, "\(event)")
            XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB), "\(event)")
            // The only reader that can be open is the ordinary one an ordinary selection asked for.
            if let seed = alternativeSeed(viewModel.readerDestination) {
                XCTFail("A saved copy opened after \(event): \(seed.chapter.key)")
            }
        }
    }

    func testReturningToTheSameSeriesDoesNotReviveAnOldGeneration() async throws {
        let subject = makeSubject()
        let viewModel = subject.viewModel
        let gates = GateSequence(count: 2)
        subject.downloads.alternativeLookup = { [self] anchor in
            try? await gates.pass()
            return listing(anchor, [candidate("b")])
        }
        let old = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        await gates.gates[0].awaitArrival()
        await viewModel.refresh()
        let current = viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
        await gates.gates[1].awaitArrival()
        let currentID = try presentationID(viewModel)

        await gates.gates[0].release()
        await old.value

        XCTAssertEqual(phase(viewModel), .loading)
        XCTAssertEqual(try presentationID(viewModel), currentID)
        await gates.gates[1].release()
        await current.value
        XCTAssertEqual(phase(viewModel), .choosing)
    }

    // MARK: - 25

    func testAnEpochThatChangedOrCannotBeReadRejectsTheLookupAtEveryBoundary() async throws {
        // The epoch cannot be read when the lookup starts.
        let unreadable = makeSubject()
        unreadable.epoch.failure = MediaDetailTestFailure.expected
        unreadable.downloads.alternativeLookup = { [self] anchor in listing(anchor, []) }
        await unreadable.viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        XCTAssertEqual(phase(unreadable.viewModel), .failed)
        XCTAssertEqual(unreadable.downloads.alternativeLookupCount, 0)

        // It changes while the lookup is in flight, it cannot be read afterwards, or the inventory was read under another.
        for scenario in ["rotated", "unreadable", "foreign inventory"] {
            let subject = makeSubject()
            let gates = GateSequence(count: 1)
            subject.downloads.alternativeLookup = { [self] anchor in
                try await gates.pass()
                return listing(anchor, [candidate("b")], epoch: scenario == "foreign inventory" ? "other-epoch" : Self.epoch)
            }
            let task = subject.viewModel.showDownloadedAlternatives(for: Self.anchorChapter)
            await gates.gates[0].awaitArrival()
            switch scenario {
            case "rotated": subject.epoch.current = "rotated-epoch"
            case "unreadable": subject.epoch.failure = MediaDetailTestFailure.expected
            default: break
            }
            await gates.gates[0].release()
            await task.value

            XCTAssertEqual(phase(subject.viewModel), .failed, scenario)
            let expected: DownloadedAlternativeFailure = scenario == "unreadable"
                ? .selection(.inventoryUnavailable)
                : .selection(.sourceChanged)
            XCTAssertEqual(failure(subject.viewModel), expected, scenario)
        }
    }

    func testAnEpochThatChangedRejectsTheAcquisitionBeforeDuringAndAfterTheLease() async throws {
        // Before the lease is requested.
        do {
            let real = try await RealAlternativeFixture.make()
            let subject = makeSubject()
            subject.downloads.alternativeOpen = { candidate, epoch in
                try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
            }
            let id = try await choose(subject, real)
            subject.epoch.current = "rotated-epoch"

            await subject.viewModel.confirmDownloadedAlternative(presentationID: id).value

            XCTAssertEqual(failure(subject.viewModel), .selection(.sourceChanged))
            XCTAssertEqual(subject.downloads.alternativeOpenCount, 0)
        }
        // After the lease came back: the copy is dropped and no reader is prepared.
        for unreadable in [false, true] {
            let real = try await RealAlternativeFixture.make()
            let subject = makeSubject()
            let gates = GateSequence(count: 1)
            subject.downloads.alternativeOpen = { candidate, epoch in
                let lease = try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
                try await gates.pass()
                return lease
            }
            let id = try await choose(subject, real)
            let task = subject.viewModel.confirmDownloadedAlternative(presentationID: id)
            await gates.gates[0].awaitArrival()
            if unreadable { subject.epoch.failure = MediaDetailTestFailure.expected } else { subject.epoch.current = "rotated-epoch" }
            await gates.gates[0].release()
            await task.value
            await real.store.leases.awaitReclamations()

            XCTAssertEqual(
                failure(subject.viewModel),
                unreadable ? .selection(.inventoryUnavailable) : .selection(.sourceChanged)
            )
            XCTAssertTrue(subject.destinations.candidateIDs.isEmpty)
            XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB))
            XCTAssertNil(subject.viewModel.readerDestination)
        }
    }

    // MARK: - 26

    func testARouteFailureAfterAcquisitionReleasesTheLeaseAndShowsOnlyTheCurrentFailure() async throws {
        let real = try await RealAlternativeFixture.make()
        let subject = makeSubject()
        subject.destinations.failure = DownloadedAlternativeError.selectionChanged
        subject.downloads.alternativeOpen = { candidate, epoch in
            try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
        }
        let id = try await choose(subject, real)

        await subject.viewModel.confirmDownloadedAlternative(presentationID: id).value
        await real.store.leases.awaitReclamations()

        XCTAssertEqual(subject.destinations.candidateIDs, [real.candidate.id])
        XCTAssertEqual(phase(subject.viewModel), .failed)
        XCTAssertEqual(failure(subject.viewModel), .selection(.selectionChanged))
        XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB))
        XCTAssertNil(subject.viewModel.readerDestination)
        XCTAssertTrue(subject.messages.messages.isEmpty)
        assertNoEffects(subject)
    }

    func testAnOpeningThatFailsToReadLeavesTheListActionableAndASettledSpinner() async throws {
        let real = try await RealAlternativeFixture.make()
        for error in [OfflineReadError.protectedDataUnavailable, .localCopyUnavailable, .localCopyDamaged] {
            let subject = makeSubject()
            subject.downloads.alternativeOpen = { _, _ in throw error }
            let id = try await choose(subject, real)

            await subject.viewModel.confirmDownloadedAlternative(presentationID: id).value

            XCTAssertEqual(phase(subject.viewModel), .choosing, "\(error)")
            XCTAssertEqual(failure(subject.viewModel), .read(error))
            guard case .choosing(_, _, let selected, _) = subject.viewModel.downloadedAlternativeState else { continue }
            // A locked device may simply be tried again; a copy that cannot be read is not offered again.
            XCTAssertEqual(selected != nil, error == .protectedDataUnavailable, "\(error)")
            XCTAssertNil(subject.viewModel.readerDestination)
        }
    }

    // MARK: - 27

    func testALocalChoiceTakesTheSheetFromASuspendedBatchReadAndABatchActionCancelsTheLocalChoice() async throws {
        let chapters = [
            Chapter(key: "a", title: "A", chapter: 5, scanlator: "G1", logicalUnitID: "unit-1"),
            Chapter(key: "g2", title: "G2", chapter: 6, scanlator: "G2", logicalUnitID: "unit-2")
        ]
        let subject = makeSubject(chapters: chapters)
        let viewModel = subject.viewModel
        let held = TestGate()
        subject.downloads.holdsPreferenceReads = true
        subject.downloads.onPreferenceReadPending = { held.open() }
        subject.downloads.alternativeLookup = { [self] anchor in listing(anchor, [candidate("b")]) }
        viewModel.start()
        // A started screen shows output only while it is on screen, as SwiftUI reports it.
        viewModel.appear()
        await held.wait()
        // The start's own detail load is finished, so no later metadata replacement ends the local choice.
        await viewModel.refresh()

        // A preset waits for the remembered choice. It would open the scanlator chooser.
        let batch = viewModel.startDownload(.next)
        await viewModel.showDownloadedAlternatives(for: chapters[0]).value
        subject.downloads.holdsPreferenceReads = false
        subject.downloads.releasePreferenceReads()
        await batch.value
        await viewModel.downloadBatch.settleForTesting()

        XCTAssertNil(viewModel.downloadBatch.sheet)
        XCTAssertTrue(isAlternativeSheet(viewModel))
        XCTAssertEqual(phase(viewModel), .choosing)

        // A new batch action cancels the local choice, so its gated lookup cannot reopen the sheet.
        let gates = GateSequence(count: 1)
        subject.downloads.alternativeLookup = { [self] anchor in
            try? await gates.pass()
            return listing(anchor, [candidate("b")])
        }
        let local = viewModel.showDownloadedAlternatives(for: chapters[0])
        await gates.gates[0].awaitArrival()
        let chooser = viewModel.openEditionChooser()
        XCTAssertEqual(phase(viewModel), .idle)
        await gates.gates[0].release()
        await local.value
        await chooser.value
        XCTAssertEqual(phase(viewModel), .idle)
        XCTAssertFalse(isAlternativeSheet(viewModel))
        // Durable writes were never part of any of this.
        XCTAssertEqual(subject.downloads.preferenceWriteCount, 0)
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)
    }

    // MARK: - 28, 29

    private func alternativeSeed(
        _ destination: MediaDetailReaderDestination?
    ) -> (chapter: Chapter, lease: OfflineChapterLease)? {
        switch destination {
        case .pages(_, let content, _, _, let chapter)?, .text(_, let content, _, _, let chapter)?:
            guard let seed = content.preference.localOnlySeed else { return nil }
            return (chapter, seed.lease)
        default:
            return nil
        }
    }

    func testTheHandOffHoldsTheLeaseUntilTheMatchingDismissalThenOpensTheReaderOnce() async throws {
        let real = try await RealAlternativeFixture.make()
        let subject = makeSubject()
        let viewModel = subject.viewModel
        subject.downloads.alternativeOpen = { candidate, epoch in
            try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
        }
        let id = try await choose(subject, real)

        await viewModel.confirmDownloadedAlternative(presentationID: id).value

        // The sheet closes first; the reader is not opened by the same step.
        XCTAssertEqual(phase(viewModel), .handingOff)
        XCTAssertNil(viewModel.downloadSheet)
        XCTAssertNil(viewModel.readerDestination)
        XCTAssertTrue(real.store.leases.isLeased(versionId: real.versionB))
        // Another sheet-producing action is not admitted while the sheet closes.
        await viewModel.showDownloadedAlternatives(for: Self.anchorChapter).value
        XCTAssertEqual(phase(viewModel), .handingOff)
        XCTAssertEqual(subject.downloads.alternativeLookupCount, 1)
        // The close of some other presentation opens nothing.
        viewModel.downloadedAlternativeSheetDidDismiss(presentationID: UUID())
        XCTAssertNil(viewModel.readerDestination)
        XCTAssertEqual(phase(viewModel), .handingOff)

        viewModel.downloadedAlternativeSheetDidDismiss(presentationID: id)

        let seed = try XCTUnwrap(alternativeSeed(viewModel.readerDestination))
        XCTAssertEqual(seed.chapter.key, "b")
        XCTAssertEqual(seed.lease.versionId, real.versionB)
        XCTAssertEqual(phase(viewModel), .idle)
        let published = viewModel.readerDestination?.id
        viewModel.downloadedAlternativeSheetDidDismiss(presentationID: id)
        XCTAssertEqual(viewModel.readerDestination?.id, published)
        XCTAssertEqual(subject.destinations.candidateIDs, [real.candidate.id])
        assertNoEffects(subject)
    }

    func testAStaleCancelledOrMissingDismissalPublishesNothing() async throws {
        for stale in ["cancelled", "refreshed", "epoch changed", "no hand-off"] {
            let real = try await RealAlternativeFixture.make()
            let subject = makeSubject()
            let viewModel = subject.viewModel
            subject.downloads.alternativeOpen = { candidate, epoch in
                try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
            }
            let id = try await choose(subject, real)
            if stale != "no hand-off" { await viewModel.confirmDownloadedAlternative(presentationID: id).value }
            switch stale {
            case "cancelled": viewModel.cancelDownloadedAlternatives()
            case "refreshed": await viewModel.refresh()
            case "epoch changed": subject.epoch.current = "rotated-epoch"
            default: break
            }

            viewModel.downloadedAlternativeSheetDidDismiss(presentationID: id)
            await real.store.leases.awaitReclamations()

            XCTAssertNil(viewModel.readerDestination, stale)
            XCTAssertEqual(phase(viewModel), stale == "no hand-off" ? .choosing : .idle, stale)
            if stale != "no hand-off" {
                XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB), stale)
            }
        }
    }

    func testLeavingTheScreenBehindItsOwnPublishedReaderKeepsTheLeaseUntilTheReaderCloses() async throws {
        let real = try await RealAlternativeFixture.make()
        let subject = makeSubject()
        let viewModel = subject.viewModel
        subject.downloads.alternativeOpen = { candidate, epoch in
            try await real.store.openDownloadedAlternative(candidate, sourceEpoch: epoch)
        }
        let id = try await choose(subject, real)
        await viewModel.confirmDownloadedAlternative(presentationID: id).value
        viewModel.downloadedAlternativeSheetDidDismiss(presentationID: id)
        XCTAssertNotNil(alternativeSeed(viewModel.readerDestination))

        viewModel.appear()
        viewModel.disappear()
        viewModel.cancelScreenOperations()
        await real.store.leases.awaitReclamations()

        XCTAssertNotNil(alternativeSeed(viewModel.readerDestination))
        XCTAssertTrue(real.store.leases.isLeased(versionId: real.versionB))

        viewModel.dismissReader()
        await real.store.leases.awaitReclamations()
        XCTAssertFalse(real.store.leases.isLeased(versionId: real.versionB))
    }
}
