import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct DownloadMorePromptContinuationTests {
    @Test func directMoreUnderTenEnqueuesAndReportsTheActualCommit() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.batchOutcome = DownloadBatchOutcome(queued: 1, alreadyQueued: 1)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: (1...5).map { Chapter(key: "c\($0)", chapter: Double($0)) },
            downloads: downloads
        )
        subject.progress.readChapterIDs[MediaDetailDownloadsFake.series] = ["c1"]
        subject.progress.lastRead[MediaDetailDownloadsFake.series] = "c1"
        let model = subject.viewModel.downloadBatch
        model.presentDownloadMore()
        guard case .moreCount(let prompt)? = model.sheet else { Issue.record("Expected prompt"); return }
        await model.confirmDownloadMore(count: 2, promptID: prompt.id).value
        #expect(model.sheet == nil)
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["c2", "c3"])
        #expect(subject.messages.messages == [.downloadsQueuedMore(requested: 2, queued: 1, storedMeanwhile: 1)])
    }

    @Test func dismissDuringPreferenceReadCannotEnqueueOrReopenThePrompt() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceReads = true
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: (1...5).map { Chapter(key: "c\($0)", chapter: Double($0)) },
            downloads: downloads,
            awaitsLoads: false
        )
        await downloads.waitForPendingPreferenceRead()
        let model = subject.viewModel.downloadBatch
        model.presentDownloadMore()
        guard case .moreCount(let prompt)? = model.sheet else { Issue.record("Expected prompt"); return }
        let confirmation = model.confirmDownloadMore(count: 2, promptID: prompt.id)
        model.dismissDownloadSheet()
        downloads.holdsPreferenceReads = false
        downloads.releasePreferenceReads()
        await confirmation.value
        #expect(model.sheet == nil)
        #expect(downloads.batchRequests.isEmpty)
    }

    @Test func replacingPromptDuringInventoryReadPreservesTheNewPrompt() async throws {
        let inventory = MediaDetailDownloadBatchTests.InventoryBox(rows: [])
        inventory.holdReads = true
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: (1...5).map { Chapter(key: "c\($0)", chapter: Double($0)) },
            inventory: inventory,
            awaitsLoads: false
        )
        subject.downloads.set(.downloaded, chapterKey: "not-listed")
        await inventory.waitForPendingRead()
        let model = subject.viewModel.downloadBatch
        model.presentDownloadMore()
        guard case .moreCount(let oldPrompt)? = model.sheet else { Issue.record("Expected prompt"); return }
        let confirmation = model.confirmDownloadMore(count: 2, promptID: oldPrompt.id)
        model.presentDownloadMore()
        guard case .moreCount(let newPrompt)? = model.sheet else { Issue.record("Expected replacement prompt"); return }
        inventory.holdReads = false
        inventory.releaseReads()
        await confirmation.value
        #expect(model.sheet == .moreCount(newPrompt))
        #expect(subject.downloads.batchRequests.isEmpty)
    }
}
