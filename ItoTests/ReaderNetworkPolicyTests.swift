import Foundation
import ito_runner
import Testing
@testable import Ito

@MainActor
struct ReaderNetworkPolicyTests {
    private let pages = [Page(index: 0, content: .text("fixture"))]

    private func manga(preload: Int = 5) async -> MangaReaderTestSubject {
        let first = Chapter(key: "a", chapter: 1)
        let next = Chapter(key: "b", chapter: 2)
        let entry = Manga(key: "series", title: "Fixture", viewer: .Vertical, chapters: [first, next])
        let subject = makeMangaReaderSubject(manga: entry, initialChapter: first, preloadImageCount: preload)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForTestingOperations()
        return subject
    }

    private func novel() async -> NovelReaderTestSubject {
        let first = Chapter(key: "a", chapter: 1)
        let next = Chapter(key: "b", chapter: 2)
        let subject = makeNovelReaderSubject(novel: Novel(key: "series", title: "Fixture", chapters: [first, next]), initialChapter: first)
        subject.loader.enqueue(.pages(pages), for: "a")
        subject.viewModel.start()
        await subject.viewModel.waitForAllOperationsForTesting()
        return subject
    }

    @Test func continuousMangaSpeculationIsZeroOnZeroPreloadExpensiveAndConstrainedPaths() async {
        let restrictions: [(Int, NetworkPathSnapshot)] = [
            (0, .init(status: .satisfied)),
            (5, .init(status: .satisfied, isExpensive: true)),
            (5, .init(status: .satisfied, isConstrained: true))
        ]
        for (preload, path) in restrictions {
            let subject = await manga(preload: preload)
            subject.settings.policyPath = path
            subject.loader.enqueue(.pages(pages), for: "b")
            subject.viewModel.appendNextChapter(trigger: .speculative)
            await subject.viewModel.waitForTestingOperations()
            #expect(subject.loader.requestedChapterKeys == ["a"])
            // The same restriction never prevents actual boundary interaction.
            subject.viewModel.appendNextChapter(trigger: .reader)
            await subject.viewModel.waitForTestingOperations()
            #expect(subject.loader.requestedChapterKeys == ["a", "b"])
            #expect(subject.loader.operations.last?.purpose == .foregroundReading)
        }
    }

    @Test func admittedMangaLookAheadUsesSpeculativePurpose() async {
        let subject = await manga()
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.appendNextChapter(trigger: .speculative)
        await subject.viewModel.waitForTestingOperations()
        #expect(subject.loader.requestedChapterKeys == ["a", "b"])
        #expect(subject.loader.operations.last?.purpose == .prefetch)
    }

    @Test func mangaQueuedStartAndHeldCompletionCannotOutliveTheirPolicyEpoch() async {
        let queued = await manga()
        queued.loader.enqueue(.pages(pages), for: "b")
        queued.viewModel.appendNextChapter(trigger: .speculative)
        // No suspension between scheduling and revocation: the loader task cannot run first.
        queued.settings.policyPath = .init(status: .satisfied, isExpensive: true)
        await queued.viewModel.waitForTestingOperations()
        #expect(queued.loader.requestedChapterKeys == ["a"])
        #expect(!queued.viewModel.loadingNextChapter)

        let held = await manga()
        held.loader.enqueue(.suspended, for: "b")
        held.viewModel.appendNextChapter(trigger: .speculative)
        await held.loader.waitForPendingCount(1, for: "b")
        held.settings.policyPath = .init(status: .satisfied, isConstrained: true)
        held.settings.policyPath = .init(status: .satisfied)
        held.loader.resolveFirst(for: "b", with: .success(pages))
        await held.viewModel.waitForTestingOperations()
        #expect(held.viewModel.segments.map { $0.chapter.key } == ["a"])
        #expect(!held.viewModel.loadingNextChapter)
        #expect(!held.viewModel.appendFailed)
    }

    @Test func novelRevokedBeforeTaskExecutionStartsNoLoaderAndOffersManualNext() async {
        let subject = await novel()
        subject.loader.enqueue(.pages(pages), for: "b")
        subject.viewModel.loadNextChapter(trigger: .seamless)
        subject.settings.policyPath = .init(status: .satisfied, isExpensive: true)
        await subject.viewModel.waitForAllOperationsForTesting()
        #expect(subject.loader.callCount(for: "b") == 0)
        #expect(!subject.viewModel.isLoadingNext)
        #expect(subject.viewModel.prefetchChapters)
        #expect(subject.viewModel.showsManualNextChapter)
        subject.viewModel.loadNextChapter(trigger: .reader)
        await subject.viewModel.waitForAllOperationsForTesting()
        #expect(subject.loader.callCount(for: "b") == 1)
        #expect(subject.loader.operations.last?.purpose == .foregroundReading)
    }

    @Test func heldNovelCompletionCannotPublishAfterRevokeAndAllowEvenWithoutNotificationDelivery() async {
        let subject = await novel()
        subject.loader.enqueue(.suspended, for: "b")
        subject.viewModel.loadNextChapter(trigger: .seamless)
        await subject.loader.waitForPendingCount(1, for: "b")
        subject.settings.policyPath = .init(status: .satisfied, isConstrained: true)
        #expect(subject.viewModel.prefetchChapters)
        #expect(subject.viewModel.showsManualNextChapter)
        subject.settings.policyPath = .init(status: .satisfied)
        subject.loader.resolveFirst(for: "b", with: .success(pages))
        await subject.viewModel.waitForAllOperationsForTesting()
        #expect(subject.viewModel.loadedChapters.map { $0.chapter.key } == ["a"])
        #expect(!subject.viewModel.isLoadingNext)
        #expect(!subject.viewModel.appendFailed)
        #expect(subject.history.requests.map(\.chapterKey) == ["a"])
    }
}
