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
        await subject.viewModel.downloadBatch.settleForTesting()

        guard case .chooser(let stillCurrent)? = subject.viewModel.downloadSheet else {
            Issue.record("A held save completion must not dismiss a newer chooser")
            return
        }
        #expect(stillCurrent.id == current.id)
        #expect(subject.viewModel.downloadBatch.remembered == .chosen(.scanlators([ScanlatorRef(id: "group-a", name: "A")])))
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

extension EditionIdentityBatchTests {
    private static let policySeries = MediaDetailDownloadsFake.series
    private static let primary = ScanlatorRef(id: "a", name: "A")
    private static let secondary = ScanlatorRef(id: "b", name: "B")

    @Test func missingPrimaryAggregatesOnceAndCancelQueuesNothing() async throws {
        let downloads = MediaDetailDownloadsFake()
        let policy = EditionSelection.preferred(primary: Self.primary, fallback: .ask)
        downloads.seedPreference(policy, for: Self.policySeries)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: (16...20).map {
            Chapter(key: "b\($0)", chapter: Double($0), scanlator: "B", scanlatorID: "b", logicalUnitID: "u\($0)")
        }, downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let preview)? = subject.viewModel.downloadSheet else {
            Issue.record("One aggregate missing-primary decision must be presented")
            return
        }
        #expect(preview.missingPositionCount == 5)
        #expect(preview.toQueue.isEmpty)
        #expect(Set(preview.alternatives.map(\.key)) == Set((16...20).map { "b\($0)" }))
        #expect(downloads.batchRequests.isEmpty)
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.confirmDownloadPreview(including: ["b16"], previewID: preview.id).value
        #expect(downloads.batchRequests.isEmpty)
        #expect(downloads.storedPreferences[Self.policySeries] == policy)
        #expect(downloads.preferenceWriteCount == 0)
    }

    @Test func aggregateBatchOnlyApprovalFreezesOnlyCheckedExactAlternatives() async throws {
        let downloads = MediaDetailDownloadsFake()
        let policy = EditionSelection.preferred(primary: Self.primary, fallback: .ask)
        downloads.seedPreference(policy, for: Self.policySeries)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "b16", chapter: 16, scanlator: "B", scanlatorID: "b", logicalUnitID: "u16"),
            Chapter(key: "c17", chapter: 17, scanlator: "C", scanlatorID: "c", logicalUnitID: "u17"),
            Chapter(key: "b18", chapter: 18, scanlator: "B", scanlatorID: "b", logicalUnitID: "u18")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let preview)? = subject.viewModel.downloadSheet else {
            Issue.record("An aggregate decision must precede enqueue")
            return
        }
        await subject.viewModel.downloadBatch.confirmDownloadPreview(
            including: ["b16", "b18"], previewID: preview.id
        ).value
        let request = try #require(downloads.batchRequests.first)
        #expect(request.chapters.map(\.key) == ["b16", "b18"])
        #expect(try JSONDecoder().decode(EditionSelection.self, from: request.selection) == policy)
        #expect(downloads.storedPreferences[Self.policySeries] == policy)
        #expect(downloads.preferenceWriteCount == 0)
        await subject.viewModel.downloadBatch.confirmDownloadPreview(including: ["c17"], previewID: preview.id).value
        #expect(downloads.batchRequests.count == 1)
    }

    @Test func strictPrimaryCannotBeSatisfiedByForbiddenSavedGroup() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.seedPreference(.preferred(primary: Self.primary, fallback: .strict), for: Self.policySeries)
        downloads.set(.downloaded, chapterKey: "b1")
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1"),
            Chapter(key: "b1", chapter: 1, scanlator: "B", scanlatorID: "b", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["a1"])
    }

    @Test func approvedSavedLowerTierWinsWhenPrimaryReturns() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.seedPreference(
            .preferred(primary: Self.primary, fallback: .approved([Self.secondary])), for: Self.policySeries
        )
        downloads.set(.downloaded, chapterKey: "b1")
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1"),
            Chapter(key: "b1", chapter: 1, scanlator: "B", scanlatorID: "b", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.messages.messages == [.nothingToDownload])
    }

    @Test func rememberedApprovalWaitsForSaveAndThenRequiresExactPreviewConfirmation() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer { downloads.holdsPreferenceWrites = false; downloads.releasePreferenceWrites() }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "b16", chapter: 16, scanlator: "B", scanlatorID: "b", logicalUnitID: "u16")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let chooser)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        let policy = EditionSelection.preferred(primary: Self.primary, fallback: .approved([Self.secondary]))
        let saving = subject.viewModel.downloadBatch.applyEditionChoice(
            policy, remember: true, then: .all, chooserID: chooser.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadBatch.remembered == .none)
        downloads.releasePreferenceWrites()
        await saving.value
        #expect(downloads.storedPreferences[Self.policySeries] == policy)
        #expect(downloads.batchRequests.isEmpty)
        guard case .preview(let preview)? = subject.viewModel.downloadSheet else { Issue.record("Expected exact fallback preview"); return }
        #expect(preview.toQueue.map(\.key) == ["b16"])
        await subject.viewModel.downloadBatch.confirmDownloadPreview(previewID: preview.id).value
        #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["b16"])
    }

    @Test func sourceEpochChangeRefusesOldChooserAndPreviewConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.seedPreference(.preferred(primary: Self.primary, fallback: .ask), for: Self.policySeries)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "b16", chapter: 16, scanlator: "B", scanlatorID: "b", logicalUnitID: "u16")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let preview)? = subject.viewModel.downloadSheet else { Issue.record("Expected preview"); return }
        downloads.policyEpoch = "changed"
        await subject.viewModel.downloadBatch.confirmDownloadPreview(including: ["b16"], previewID: preview.id).value
        #expect(downloads.batchRequests.isEmpty)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let chooser)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        downloads.policyEpoch = "changed-again"
        await subject.viewModel.downloadBatch.applyEditionChoice(
            .sourceList, remember: true, then: .all, chooserID: chooser.id
        ).value
        #expect(downloads.preferenceWriteCount == 0)
        #expect(downloads.batchRequests.isEmpty)
    }

    @Test func catalogReplacementCannotReuseExactAlternativeConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.seedPreference(.preferred(primary: Self.primary, fallback: .ask), for: Self.policySeries)
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "b16", chapter: 16, scanlator: "B", scanlatorID: "b", logicalUnitID: "u16")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let preview)? = subject.viewModel.downloadSheet else { Issue.record("Expected preview"); return }
        subject.catalog.chapters = [
            Chapter(key: "new-b16", chapter: 16, scanlator: "B", scanlatorID: "b", logicalUnitID: "u16")
        ]
        await subject.viewModel.refresh()
        await subject.viewModel.downloadBatch.confirmDownloadPreview(including: ["b16"], previewID: preview.id).value
        #expect(downloads.batchRequests.isEmpty)
        guard case .preview(let revised)? = subject.viewModel.downloadSheet else { Issue.record("Expected revised review"); return }
        #expect(revised.id != preview.id)
        #expect(revised.alternatives.map(\.key) == ["new-b16"])
    }

    @Test func aPreferenceResynchronizationInvalidatesNewerChooserConsentWithoutClosingIt() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer { downloads.holdsPreferenceWrites = false; downloads.releasePreferenceWrites() }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1"),
            Chapter(key: "b1", chapter: 1, scanlator: "B", scanlatorID: "b", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let first)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        let saving = subject.viewModel.downloadBatch.applyEditionChoice(
            .preferred(primary: Self.primary, fallback: .ask), remember: true, then: nil, chooserID: first.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        subject.viewModel.downloadBatch.dismissDownloadSheet()
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let newer)? = subject.viewModel.downloadSheet else { Issue.record("Expected newer chooser"); return }
        downloads.releasePreferenceWrites()
        await saving.value
        await subject.viewModel.downloadBatch.settleForTesting()
        await subject.viewModel.downloadBatch.applyEditionChoice(
            .sourceList, remember: true, then: .all, chooserID: newer.id
        ).value
        #expect(downloads.preferenceWriteCount == 1)
        #expect(downloads.batchRequests.isEmpty)
    }
}

struct EditionFallbackResolverTests {
    private let primary = ScanlatorRef(id: "a", name: "A")
    private let b = ScanlatorRef(id: "b", name: "B")
    private let c = ScanlatorRef(id: "c", name: "C")

    private func row(_ key: String, _ group: String, _ unit: String?, stored: StoredEditionState = .none, locked: Bool = false) -> DownloadPlanRow {
        DownloadPlanRow(facts: ChapterFacts(
            key: key, number: 1, scanlator: group.uppercased(), scanlatorID: group,
            isLocked: locked, logicalUnitID: unit, readingOrder: unit == "u2" || unit == "other" ? 2 : (unit == "u3" ? 3 : 1)
        ), stored: stored)
    }

    @Test func approvedOrderHasNoUnlistedTailAndRequiresLogicalProof() {
        let rows = [row("c1", "c", "u1"), row("b1", "b", "u1"),
                    row("c2", "c", "u2"), row("d3", "d", "u3"), row("b-extra", "b", nil)]
        let plan = DownloadPresetResolver.plan(
            rows: rows, preset: .all, selection: .preferred(primary: primary, fallback: .approved([b, c])), anchorKey: nil
        )
        // b-extra shares u1's response order without sharing its logical identity, making ordering
        // ambiguous. This assertion tests approved membership/priority, not that incidental sequence.
        #expect(Set(plan.toQueue.map { rows[$0].facts.key }) == ["b1", "c2"])
        #expect(plan.missingPositionCount == 2)
        #expect(plan.requiresPreview)
    }

    @Test func committedApprovedCopyBeatsNewPrimaryAndForbiddenCopyNeverDoes() {
        let rows = [row("a", "a", "u"), row("b", "b", "u", stored: .verified)]
        let approved = DownloadPresetResolver.plan(
            rows: rows, preset: .next, selection: .preferred(primary: primary, fallback: .approved([b])), anchorKey: nil
        )
        #expect(approved.toQueue.isEmpty)
        #expect(approved.satisfied == [1])
        let strict = DownloadPresetResolver.plan(
            rows: rows, preset: .next, selection: .preferred(primary: primary, fallback: .strict), anchorKey: nil
        )
        #expect(strict.toQueue == [0])
        #expect(strict.satisfied.isEmpty)
    }

    @Test func missingPrimaryNextWindowDoesNotSkipAheadToHideTheGap() {
        let rows = [row("b1", "b", "u1"), row("a2", "a", "u2")]
        let plan = DownloadPresetResolver.plan(
            rows: rows, preset: .next, selection: .preferred(primary: primary, fallback: .ask), anchorKey: nil
        )
        #expect(plan.toQueue.isEmpty)
        #expect(plan.missingPositionCount == 1)
        #expect(plan.alternatives == [0])
    }

    @Test func missingIDNeverDowngradesToNameAndExplicitIDlessBindingRemainsExact() {
        let catalog = [ScanlatorRef(name: "A", binding: .exactIDless)]
        #expect(EditionSelection.preferred(primary: primary, fallback: .ask).resolve(in: catalog) == nil)
        let explicit = EditionSelection.preferred(primary: catalog[0], fallback: .strict)
        let resolution = explicit.resolve(in: catalog)
        #expect(resolution?.admits(scanlator: "A", groupID: nil) == true)
        #expect(resolution?.admits(scanlator: "A", groupID: "new") == false)
    }

    @Test func anyAvailableNeverSubstitutesWithoutLogicalProofButKeepsThePrimaryRows() {
        let rows = [row("a-exact", "a", nil), row("b-exact", "b", nil)]
        let plan = DownloadPresetResolver.plan(
            rows: rows, preset: .all, selection: .preferred(primary: primary, fallback: .anyAvailable), anchorKey: nil
        )
        #expect(plan.toQueue == [0])
        #expect(plan.missingPositionCount == 1)
        #expect(plan.alternatives == [1])
    }

    @Test func anyAvailableIsExplicitAndStillPrefersPrimary() {
        let rows = [row("b", "b", "u"), row("a", "a", "u"), row("c", "c", "other")]
        let plan = DownloadPresetResolver.plan(
            rows: rows, preset: .all, selection: .preferred(primary: primary, fallback: .anyAvailable), anchorKey: nil
        )
        #expect(plan.toQueue == [1, 2])
    }

    @Test func preferredWritesVersionThreeWithoutChangingLegacyMeaning() throws {
        for version in [1, 2] {
            let legacy = Data(
                #"{"formatVersion":\#(version),"kind":"scanlators","scanlators":[{"id":"a","name":"A"},{"id":"b","name":"B"}]}"#.utf8
            )
            #expect(try JSONDecoder().decode(EditionSelection.self, from: legacy) == .scanlators([primary, b]))
        }
        let strict = Data(#"{"formatVersion":2,"kind":"scanlators","scanlators":[{"id":"a","name":"A"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(EditionSelection.self, from: strict)
        #expect(decoded == .scanlators([primary]), "A shipped single-group choice stays strict, not Ask")
        let reencoded = try #require(JSONSerialization.jsonObject(with: decoded.storageData()) as? [String: Any])
        #expect(reencoded["formatVersion"] as? Int == 2)
        let fallbacks: [EditionFallback] = [.strict, .ask, .approved([b, c]), .anyAvailable]
        for fallback in fallbacks {
            let selection = EditionSelection.preferred(primary: primary, fallback: fallback)
            let bytes = try selection.storageData()
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["formatVersion"] as? Int == 3)
            #expect(try JSONDecoder().decode(EditionSelection.self, from: bytes) == selection)
        }
        let wrongVersion = Data(#"{"formatVersion":2,"kind":"preferred","primary":{"id":"a"},"fallback":"ask"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditionSelection.self, from: wrongVersion) }
        let unknown = Data(#"{"formatVersion":3,"kind":"preferred","primary":{"id":"a"},"fallback":"unknown"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditionSelection.self, from: unknown) }
        let duplicate = Data(
            #"{"formatVersion":3,"kind":"preferred","primary":{"id":"a"},"fallback":"approved","approved":[{"id":"a"}]}"#.utf8
        )
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditionSelection.self, from: duplicate) }
    }
}

extension EditionIdentityBatchTests {
    @Test func admittedSaveAfterCatalogInvalidationResynchronizesWithoutQueuing() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer { downloads.holdsPreferenceWrites = false; downloads.releasePreferenceWrites() }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let chooser)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        let policy = EditionSelection.preferred(primary: Self.primary, fallback: .ask)
        let saving = subject.viewModel.downloadBatch.applyEditionChoice(
            policy, remember: true, then: .all, chooserID: chooser.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        subject.catalog.chapters.append(
            Chapter(key: "b2", chapter: 2, scanlator: "B", scanlatorID: "b", logicalUnitID: "u2")
        )
        await subject.viewModel.refresh()
        downloads.releasePreferenceWrites()
        await saving.value
        await subject.viewModel.downloadBatch.settleForTesting()
        #expect(subject.viewModel.downloadBatch.remembered == .chosen(policy))
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(downloads.batchRequests.isEmpty)
    }

    @Test func admittedSaveAfterRemovalNeverRestoresTheOldSessionPreference() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer { downloads.holdsPreferenceWrites = false; downloads.releasePreferenceWrites() }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let chooser)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        let saving = subject.viewModel.downloadBatch.applyEditionChoice(
            .preferred(primary: Self.primary, fallback: .ask), remember: true, then: .all, chooserID: chooser.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        subject.library.publish(records: [], hasCustomCategories: false)
        downloads.releasePreferenceWrites()
        await saving.value
        await subject.viewModel.downloadBatch.settleForTesting()
        #expect(subject.viewModel.downloadBatch.remembered == .unknown)
        #expect(subject.viewModel.downloadSheet == nil)
        #expect(downloads.batchRequests.isEmpty)
    }

    @Test func anAdmittedSaveWhoseSourceEpochRotatedStoresNothingAndReportsNothing() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.holdsPreferenceWrites = true
        defer { downloads.holdsPreferenceWrites = false; downloads.releasePreferenceWrites() }
        let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
            Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1")
        ], downloads: downloads)
        await subject.viewModel.downloadBatch.openEditionChooser().value
        guard case .chooser(let chooser)? = subject.viewModel.downloadSheet else { Issue.record("Expected chooser"); return }
        let policy = EditionSelection.preferred(primary: Self.primary, fallback: .approved([Self.secondary]))
        let saving = subject.viewModel.downloadBatch.applyEditionChoice(
            policy, remember: true, then: .all, chooserID: chooser.id
        )
        try await downloads.waitForPendingPreferenceWrite()
        downloads.policyEpoch = "rotated"
        downloads.releasePreferenceWrites()
        await saving.value
        await subject.viewModel.downloadBatch.settleForTesting()
        #expect(downloads.storedPreferences[Self.policySeries] == nil)
        #expect(subject.viewModel.downloadBatch.remembered != .chosen(policy))
        #expect(subject.messages.messages.isEmpty)
        #expect(downloads.batchRequests.isEmpty)
        #expect(subject.viewModel.downloadBatch.isApplyingChoice == false)
    }

    @Test func savedOnlyApprovedCopySatisfiesItsProvenPositionButForeignOriginDoesNot() async throws {
        for foreign in [false, true] {
            let downloads = MediaDetailDownloadsFake()
            let policy = EditionSelection.preferred(primary: Self.primary, fallback: .approved([Self.secondary]))
            downloads.seedPreference(policy, for: Self.policySeries)
            downloads.set(.downloaded, chapterKey: "b1")
            let saved = Chapter(key: "b1", chapter: 1, scanlator: "B", scanlatorID: "b", logicalUnitID: "u1", readingOrder: 999)
            var record = DownloadedChapterRecord(
                pluginId: "plugin.test", mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: "b1",
                authorityScope: .publicUnscoped, versionId: UUID().uuidString, state: .verified,
                damageReason: nil, contentKind: .images, pageCount: 1, byteCount: 1,
                manifestFormatVersion: 1, manifestSHA256: String(repeating: "a", count: 64),
                chapterSnapshot: try JSONEncoder().encode(saved), seriesTitle: "Series", sourceEpoch: nil,
                verifiedAt: Date()
            )
            if foreign {
                record.originIdentity = try JSONEncoder().encode(OfflineOriginIdentity(
                    pluginId: "foreign", canonicalMediaId: "other"
                ))
            }
            let subject = await MediaDetailDownloadBatchTests().makeSubject(chapters: [
                Chapter(key: "a1", chapter: 1, scanlator: "A", scanlatorID: "a", logicalUnitID: "u1", readingOrder: 1)
            ], downloads: downloads, inventory: .init(rows: [record]))
            await subject.viewModel.downloadBatch.startDownload(.all).value
            if foreign {
                #expect(downloads.batchRequests.first?.chapters.map(\.key) == ["a1"])
            } else {
                #expect(downloads.batchRequests.isEmpty)
                #expect(subject.messages.messages == [.nothingToDownload])
            }
        }
    }
}

extension EditionFallbackResolverTests {
    @Test func lockedApprovedGroupDoesNotBypassEligibilityOrAuthorizeUnlistedGroups() {
        let rows = [row("b1", "b", "u1", locked: true), row("c1", "c", "u1"),
                    row("b2", "b", "u2", stored: .damaged), row("c2", "c", "u2")]
        let plan = DownloadPresetResolver.plan(
            rows: rows, preset: .all, selection: .preferred(primary: primary, fallback: .approved([b, c])), anchorKey: nil
        )
        #expect(plan.toQueue == [1])
        #expect(plan.damaged == [2])
    }
}
