import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct DownloadMorePromptTests {
    @Test func invalidCountAndStalePromptDoNotReplaceOrSubmitTheCurrentPrompt() async throws {
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: (1...4).map { Chapter(key: "c\($0)", chapter: Double($0)) }
        )
        let model = subject.viewModel.downloadBatch
        model.presentDownloadMore()
        guard case .moreCount(let original)? = model.sheet else { Issue.record("Expected prompt"); return }
        await model.confirmDownloadMore(count: 0, promptID: original.id).value
        #expect(model.sheet == .moreCount(original))
        model.presentDownloadMore()
        guard case .moreCount(let current)? = model.sheet else { Issue.record("Expected new prompt"); return }
        await model.confirmDownloadMore(count: 2, promptID: original.id).value
        #expect(model.sheet == .moreCount(current))
        #expect(subject.downloads.batchRequests.isEmpty)
    }

    @Test func confirmingReplacesTheSameSheetWithPreviewAndReportsActualCommitCounts() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.batchOutcome = DownloadBatchOutcome(queued: 1, alreadyQueued: 1)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: (1...4).map { Chapter(key: "c\($0)", chapter: Double($0)) }, downloads: downloads
        )
        let model = subject.viewModel.downloadBatch
        model.presentDownloadMore()
        guard case .moreCount(let prompt)? = model.sheet else { Issue.record("Expected prompt"); return }
        let sheetID = model.sheet?.id
        await model.confirmDownloadMore(count: 2, promptID: prompt.id).value
        guard case .preview(let preview)? = model.sheet else { Issue.record("Expected preview"); return }
        #expect(model.sheet?.id == sheetID)
        #expect(preview.action == .more(try #require(DownloadPositionCount(2))))
        #expect(downloads.batchRequests.isEmpty)
        await model.confirmDownloadPreview(previewID: preview.id).value
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["c1", "c2"])
        #expect(subject.messages.messages == [.downloadsQueuedMore(requested: 2, queued: 1, storedMeanwhile: 1)])
    }

}
