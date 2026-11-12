import Foundation
import Testing
import ito_runner
@testable import Ito

@MainActor
struct EditionIdentityBatchTests {

    @Test func chooserOptionsAndFrozenBatchKeepSameNameGroupIDsDistinct() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "Shared", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "Shared", scanlatorID: "group-b")
        ], downloads: downloads)

        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The group chooser should be open")
            return
        }
        #expect(presentation.options.count == 2)
        #expect(Set(presentation.options.map(\.ref.id)) == ["group-a", "group-b"])
        #expect(presentation.options.allSatisfy { $0.ref.name == "Shared" && $0.chapterCount == 1 })

        let selection = EditionSelection.scanlators([ScanlatorRef(id: "group-a", name: "Shared")])
        await subject.viewModel.downloadBatch.applyEditionChoice(
            selection, remember: false, then: .all, chooserID: presentation.id
        ).value
        let request = try #require(downloads.batchRequests.first)
        #expect(try JSONDecoder().decode(EditionSelection.self, from: request.selection) == selection)
        #expect(downloads.preferenceWriteCount == 0)
        #expect(request.chapters.map(\.key) == ["a"])
    }

    @Test func uniqueLegacyChoiceResolvesInMemoryWithoutWritingAndShowsTheCurrentName() async throws {
        let downloads = MediaDetailDownloadsFake()
        let legacy = EditionSelection.scanlators([ScanlatorRef(name: "Current")])
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        downloads.seedPreference(legacy, for: identity)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "Current", scanlatorID: "group-a")
        ], downloads: downloads)

        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The group chooser should be open")
            return
        }
        #expect(presentation.options.map(\.ref) == [ScanlatorRef(id: "group-a", name: "Current")])
        #expect(presentation.initialSelection == .scanlators([ScanlatorRef(id: "group-a", name: "Current")]))
        #expect(downloads.storedPreferences[identity] == legacy)
        #expect(downloads.preferenceWriteCount == 0)
    }

    @Test func missingBoundIDRequiresReviewEvenWhenOnlyOneDifferentGroupRemains() async throws {
        let downloads = MediaDetailDownloadsFake()
        let selection = EditionSelection.scanlators([ScanlatorRef(id: "missing", name: "Same label")])
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        downloads.seedPreference(selection, for: identity)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "current", chapter: 1, scanlator: "Same label", scanlatorID: "replacement")
        ], downloads: downloads)

        await subject.viewModel.downloadBatch.startDownload(.all).value

        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("An unavailable bound ID must open review instead of planning")
            return
        }
        #expect(presentation.storedChoiceProblem == .needsReview)
        #expect(subject.downloads.batchRequests.isEmpty)
        #expect(subject.downloads.preferenceWriteCount == 0)
    }

    @Test func aBoundIDRenameShowsOneCurrentLabelWithoutRewritingThePreference() async throws {
        let downloads = MediaDetailDownloadsFake()
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        let stored = EditionSelection.scanlators([ScanlatorRef(id: "group-a", name: "Old")])
        downloads.seedPreference(stored, for: identity)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "Current", scanlatorID: "group-a")
        ], downloads: downloads)

        await subject.viewModel.downloadBatch.openEditionChooser().value

        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The chooser should open")
            return
        }
        #expect(presentation.options.count == 1)
        #expect(presentation.options[0].ref.name == "Current")
        guard case .scanlators(let initialReferences) = presentation.initialSelection else {
            Issue.record("The renamed bound ID should remain selected")
            return
        }
        #expect(initialReferences.map(\.name) == ["Current"])
        #expect(downloads.storedPreferences[identity] == stored)

        await subject.viewModel.downloadBatch.applyEditionChoice(
            presentation.initialSelection, remember: false, then: .all, chooserID: presentation.id
        ).value
        let currentDescriptor = EditionSelection.scanlators([ScanlatorRef(id: "group-a", name: "Current")])
        let request = try #require(downloads.batchRequests.first)
        #expect(request.selection == (try currentDescriptor.storageData()))
        let frozen = try JSONDecoder().decode(EditionSelection.self, from: request.selection)
        guard case .scanlators(let references) = frozen else {
            Issue.record("The frozen batch should carry the group selection")
            return
        }
        #expect(references.map(\.name) == ["Current"])
        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.storedPreferences[identity] == stored)
    }

    @Test func mixedLegacyNameRequiresReviewThenExplicitIDlessReselectionContinues() async throws {
        let downloads = MediaDetailDownloadsFake()
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        let legacy = EditionSelection.scanlators([ScanlatorRef(name: "Shared")])
        downloads.seedPreference(legacy, for: identity)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "idless", chapter: 1, scanlator: "Shared"),
            Chapter(key: "identified", chapter: 2, scanlator: "Shared", scanlatorID: "group-id")
        ], downloads: downloads)

        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The mixed legacy reference must require review")
            return
        }
        #expect(presentation.storedChoiceProblem == .needsReview)
        #expect(presentation.options.count == 2)
        let exactIDless = EditionSelection.scanlators([
            ScanlatorRef(name: "Shared", binding: .exactIDless)
        ])

        await subject.viewModel.downloadBatch.applyEditionChoice(
            exactIDless, remember: true, then: .all, chooserID: presentation.id
        ).value

        #expect(downloads.preferenceWriteCount == 1)
        #expect(downloads.storedPreferences[identity] == exactIDless)
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["idless"])
        await subject.viewModel.downloadBatch.startDownload(.all).value
        #expect(downloads.batchRequests.last?.selection == (try exactIDless.storageData()))
        #expect(downloads.batchRequests.last?.chapters.map(\.key) == ["idless"])
    }

    @Test func catalogChangeInvalidatesTheChooserConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let old)? = subject.viewModel.downloadSheet else {
            Issue.record("The original chooser should be open")
            return
        }
        subject.catalog.chapters = [
            Chapter(key: "a", chapter: 1, scanlator: "Replacement", scanlatorID: "group-replacement")
        ]
        await subject.viewModel.refresh()

        await subject.viewModel.downloadBatch.applyEditionChoice(
            .scanlators([ScanlatorRef(id: "group-a", name: "A")]),
            remember: true,
            then: .all,
            chooserID: old.id
        ).value

        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
    }

    @Test func immediateChooserDismissalBeforeTaskAdmissionCannotPersist() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let presentation)? = subject.viewModel.downloadSheet else {
            Issue.record("The chooser should be open")
            return
        }

        let apply = subject.viewModel.downloadBatch.applyEditionChoice(
            .scanlators([ScanlatorRef(id: "group-a", name: "A")]),
            remember: true,
            then: .all,
            chooserID: presentation.id
        )
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await apply.value

        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.batchRequests.isEmpty)
        #expect(!subject.viewModel.downloadBatch.isApplyingChoice)
    }

    @Test func removingAndReaddingTheSameSavedScopeInvalidatesAnOldChooser() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let old)? = subject.viewModel.downloadSheet else {
            Issue.record("The original chooser should be open")
            return
        }
        let saved = MediaDetailLibraryRecord(itemID: "series-1", pluginID: "plugin.test", mediaKind: .manga)
        subject.library.publish(records: [], hasCustomCategories: false)
        #expect(subject.viewModel.downloadSheet == nil)
        subject.library.publish(records: [saved], hasCustomCategories: false)

        await subject.viewModel.downloadBatch.applyEditionChoice(
            .scanlators([ScanlatorRef(id: "group-a", name: "A")]),
            remember: true,
            then: .all,
            chooserID: old.id
        ).value

        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
    }

    @Test func removingAndReaddingTheSameSavedScopeInvalidatesAnOldPreview() async throws {
        let downloads = MediaDetailDownloadsFake()
        let chapters = (1...12).map {
            Chapter(key: "c\($0)", chapter: Double($0), scanlator: "A", scanlatorID: "group-a")
        }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: chapters, downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let oldPreview)? = subject.viewModel.downloadSheet else {
            Issue.record("A large plan should have a preview")
            return
        }
        let saved = MediaDetailLibraryRecord(itemID: "series-1", pluginID: "plugin.test", mediaKind: .manga)
        subject.library.publish(records: [], hasCustomCategories: false)
        await subject.viewModel.downloadBatch.confirmDownloadPreview(previewID: oldPreview.id).value
        #expect(downloads.batchRequests.isEmpty)
        subject.library.publish(records: [saved], hasCustomCategories: false)

        await subject.viewModel.downloadBatch.confirmDownloadPreview(previewID: oldPreview.id).value

        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadSheet == nil)
    }

    @Test func dismissedChooserCallbackCannotPersistOrReplaceNewPresentation() async throws {
        let downloads = MediaDetailDownloadsFake()
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let old)? = subject.viewModel.downloadSheet else {
            Issue.record("The first group chooser should be open")
            return
        }
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let current)? = subject.viewModel.downloadSheet else {
            Issue.record("The replacement group chooser should be open")
            return
        }

        await subject.viewModel.downloadBatch.applyEditionChoice(
            .scanlators([ScanlatorRef(id: "group-a", name: "A")]),
            remember: true,
            then: nil,
            chooserID: old.id
        ).value

        #expect(downloads.preferenceWriteCount == 0)
        guard case .chooser(let stillCurrent)? = subject.viewModel.downloadSheet else {
            Issue.record("A stale callback must not dismiss the current chooser")
            return
        }
        #expect(stillCurrent.id == current.id)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func heldSaveCompletionCannotChangeTheNewerChooser() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer {
            downloads.holdsPreferenceWrites = false
            downloads.releasePreferenceWrites()
        }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let old)? = subject.viewModel.downloadSheet else {
            Issue.record("The original chooser should be open")
            return
        }
        let save = subject.viewModel.downloadBatch.applyEditionChoice(
            .scanlators([ScanlatorRef(id: "group-a", name: "A")]),
            remember: true,
            then: nil,
            chooserID: old.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let current)? = subject.viewModel.downloadSheet else {
            Issue.record("The replacement chooser should be open while the save is held")
            downloads.releasePreferenceWrites()
            await save.value
            return
        }

        downloads.releasePreferenceWrites()
        await save.value

        guard case .chooser(let stillCurrent)? = subject.viewModel.downloadSheet else {
            Issue.record("A held save completion must not dismiss a newer chooser")
            return
        }
        #expect(stillCurrent.id == current.id)
        #expect(subject.viewModel.downloadBatch.remembered == .none)
        #expect(downloads.preferenceWriteCount == 1)
    }

    // MARK: - Admitted batches report by their saved lifecycle, not the catalogue

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aHeldBatchRefusalSurvivesACatalogRefreshAndIsReported() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsBatches = true
        defer {
            downloads.holdsBatches = false
            downloads.releaseBatches()
        }
        downloads.batchOutcome = .refused(.paywalled)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: oneGroupChapters(), downloads: downloads
        )

        let queueing = subject.viewModel.downloadBatch.startDownload(.all)
        try await downloads.waitForPendingBatch()
        subject.catalog.chapters.append(Chapter(key: "b", chapter: 2, scanlator: "A", scanlatorID: "group-a"))
        await subject.viewModel.refresh()
        downloads.holdsBatches = false
        downloads.releaseBatches()
        await queueing.value

        #expect(subject.messages.messages == [.downloadRefused])
        #expect(!subject.viewModel.downloadBatch.isEnqueuing)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aHeldBatchSuccessSurvivesACatalogRefreshAndIsReported() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsBatches = true
        defer {
            downloads.holdsBatches = false
            downloads.releaseBatches()
        }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: oneGroupChapters(), downloads: downloads
        )

        let queueing = subject.viewModel.downloadBatch.startDownload(.all)
        try await downloads.waitForPendingBatch()
        subject.catalog.chapters.append(Chapter(key: "b", chapter: 2, scanlator: "A", scanlatorID: "group-a"))
        await subject.viewModel.refresh()
        downloads.holdsBatches = false
        downloads.releaseBatches()
        await queueing.value

        #expect(subject.messages.messages == [.downloadsQueued(queued: 1, alreadyStored: 0)])
        #expect(!subject.viewModel.downloadBatch.isEnqueuing)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aHeldBatchAfterRemoveAndReaddIsSilentAndCannotEndANewerSubmission() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsBatches = true
        defer {
            downloads.holdsBatches = false
            downloads.releaseBatches()
        }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(
            chapters: oneGroupChapters(), downloads: downloads
        )
        let saved = MediaDetailLibraryRecord(itemID: "series-1", pluginID: "plugin.test", mediaKind: .manga)

        let older = subject.viewModel.downloadBatch.startDownload(.all)
        try await downloads.waitForPendingBatch()
        subject.library.publish(records: [], hasCustomCategories: false)
        subject.library.publish(records: [saved], hasCustomCategories: false)
        #expect(!subject.viewModel.downloadBatch.isEnqueuing, "Removal releases the screen's queueing state")

        let newer = subject.viewModel.downloadBatch.startDownload(.all)
        try await downloads.waitForPendingBatch(count: 2)
        #expect(subject.viewModel.downloadBatch.isEnqueuing)

        downloads.releaseOldestBatch()
        await older.value
        #expect(subject.viewModel.downloadBatch.isEnqueuing, "An older submission must not clear a newer one")
        #expect(subject.messages.messages.isEmpty, "A removed series' batch reports nothing")

        downloads.holdsBatches = false
        downloads.releaseOldestBatch()
        await newer.value
        #expect(!subject.viewModel.downloadBatch.isEnqueuing)
        #expect(subject.messages.messages == [.downloadsQueued(queued: 1, alreadyStored: 0)])
    }

    @Test func removingASeriesForgetsItsRememberedChoiceSoReaddingItDoesNotReuseIt() async throws {
        let downloads = MediaDetailDownloadsFake()
        let identity = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)
        downloads.seedPreference(.scanlators([ScanlatorRef(id: "group-a", name: "A")]), for: identity)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a"),
            Chapter(key: "b", chapter: 2, scanlator: "B", scanlatorID: "group-b")
        ], downloads: downloads)
        let saved = MediaDetailLibraryRecord(itemID: "series-1", pluginID: "plugin.test", mediaKind: .manga)

        await subject.viewModel.downloadBatch.startDownload(.all).value
        #expect(downloads.batchRequests.count == 1, "The remembered choice applies while the series is saved")

        subject.library.publish(records: [], hasCustomCategories: false)
        downloads.forgetPreference(for: identity)
        subject.library.publish(records: [saved], hasCustomCategories: false)
        await subject.viewModel.downloadBatch.startDownload(.all).value

        #expect(downloads.batchRequests.count == 1, "The forgotten choice is not reused; the chooser opens instead")
        guard case .chooser? = subject.viewModel.downloadSheet else {
            Issue.record("A re-added series with two groups and no choice should ask")
            return
        }
    }

    private func oneGroupChapters() -> [Chapter] {
        [Chapter(key: "a", chapter: 1, scanlator: "A", scanlatorID: "group-a")]
    }
}
