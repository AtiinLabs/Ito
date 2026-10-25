import Combine
import UIKit
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MediaDetailViewModelTests: XCTestCase {
    func testInitialSummaryFirstLoadAndDuplicateStartSuppression() async {
        let summary = manga(key: "m1", title: "Summary")
        let hydrated = manga(key: "m1", title: "Hydrated", chapters: [chapter("c1", 1)])
        let subject = makeMangaSubject(media: summary)
        subject.route.loadResponses = [.suspended]

        XCTAssertEqual(subject.viewModel.media.title, "Summary")
        XCTAssertEqual(subject.viewModel.detailLoadState, .idle)

        subject.viewModel.start()
        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 }
        XCTAssertEqual(subject.viewModel.detailLoadState, .loading)
        XCTAssertEqual(subject.route.loadRequests.map(\.title), ["Summary"])

        subject.route.resolveLoad(at: 0, with: .success(hydrated))
        await waitUntil { subject.viewModel.detailLoadState == .content }
        XCTAssertEqual(subject.viewModel.media.title, "Hydrated")
    }

    func testLoadFailureIsRecoverableAndUsesTypedMessage() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [.failure, .value(manga(key: "m1", title: "Recovered"))]

        subject.viewModel.start()
        await waitUntil {
            if case .failure = subject.viewModel.detailLoadState { return true }
            return false
        }
        XCTAssertEqual(subject.viewModel.media.title, "Manga")
        XCTAssertEqual(subject.messages.messages, [.detailLoadFailed])

        subject.viewModel.retryDetailLoad()
        await waitUntil { subject.viewModel.detailLoadState == .content }
        XCTAssertEqual(subject.viewModel.media.title, "Recovered")
    }

    func testForceRefreshUsesCurrentAuthoritativeMedia() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [
            .value(manga(key: "m1", title: "First")),
            .value(manga(key: "m1", title: "Second"))
        ]

        subject.viewModel.start()
        await waitUntil { subject.viewModel.media.title == "First" }
        await subject.viewModel.refresh()

        XCTAssertEqual(subject.viewModel.media.title, "Second")
        XCTAssertEqual(subject.route.loadRequests.map(\.title), ["Manga", "First"])
    }

    func testStaleLoadCannotOverwriteNewerRefreshOrClearItsSpinner() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [.suspended, .suspended]

        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 }
        let refresh = Task { await subject.viewModel.refresh() }
        await waitUntil { subject.route.pendingLoadCount == 2 }

        subject.route.resolveLoad(
            at: 1,
            with: .success(manga(key: "m1", title: "Newest"))
        )
        await refresh.value
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertEqual(subject.viewModel.media.title, "Newest")

        subject.route.resolveLoad(
            at: 0,
            with: .success(manga(key: "m1", title: "Obsolete"))
        )
        await Task.yield()
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertEqual(subject.viewModel.media.title, "Newest")
    }

    func testNewerLoadRemainsLoadingWhenOlderCancelledOperationFinishes() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [.suspended, .suspended]

        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 }
        let refresh = Task { await subject.viewModel.refresh() }
        await waitUntil { subject.route.pendingLoadCount == 2 }

        subject.route.resolveLoad(at: 0, with: .failure(MediaDetailTestFailure.expected))
        await Task.yield()
        XCTAssertEqual(subject.viewModel.detailLoadState, .loading)

        subject.route.resolveLoad(
            at: 0,
            with: .success(manga(key: "m1", title: "Current"))
        )
        await refresh.value
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertEqual(subject.viewModel.media.title, "Current")
    }

    func testAnimeGroupUsesCurrentSeasonAndUpdatesAfterHydration() async {
        let summary = anime(
            seasons: [
                Anime.Season(key: "s1", title: "One"),
                Anime.Season(key: "s2", title: "Two", isCurrent: true)
            ]
        )
        let hydrated = anime(
            seasons: [
                Anime.Season(key: "s3", title: "Three", isCurrent: true),
                Anime.Season(key: "s4", title: "Four")
            ]
        )
        let subject = makeAnimeSubject(media: summary, hydrated: hydrated)

        XCTAssertEqual(subject.viewModel.selectedGroup, "s2")
        subject.viewModel.start()
        await waitUntil { subject.viewModel.detailLoadState == .content }
        XCTAssertEqual(subject.viewModel.selectedGroup, "s3")
    }

    func testNumericOrderingAndMissingChapterNumbersMatchCharacterizedBehavior() {
        let subject = makeMangaSubject(
            media: manga(chapters: [
                chapter("one", 1),
                chapter("missing", nil),
                chapter("three", 3)
            ])
        )

        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["three", "one", "missing"])
        subject.viewModel.sortOrder = .ascending
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["one", "three", "missing"])
    }

    func testDateOrderingAndMissingDatesMatchCharacterizedBehavior() {
        let subject = makeMangaSubject(
            media: manga(chapters: [
                chapter("old", 1, date: 1_700_000_000),
                chapter("missing", 2),
                chapter("new", 3, date: 1_700_086_400)
            ])
        )

        subject.viewModel.sortOrder = .dateDescending
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key).last, "missing")
        subject.viewModel.sortOrder = .dateAscending
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key).first, "missing")
    }

    func testReadUnreadFiltersAndRowStateUseCanonicalIdentity() {
        let media = manga(chapters: [chapter("one", 1), chapter("two", 2)])
        let identity = MediaIdentity(pluginId: Self.pluginID, itemId: media.key, mediaKind: .manga)
        let subject = makeMangaSubject(media: media)
        subject.progress.readChapterIDs[identity] = ["one"]

        subject.viewModel.filterOption = .read
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["one"])
        XCTAssertTrue(subject.viewModel.isRead(media.chapters![0]))
        subject.viewModel.filterOption = .unread
        XCTAssertEqual(subject.viewModel.displayedChapters.map(\.key), ["two"])
        XCTAssertTrue(subject.progress.readRequests.allSatisfy { $0.media == identity })
    }

    func testResumeTargetsFirstUnreadThenFinalChapterWhenAllRead() {
        let media = manga(chapters: [
            chapter("three", 3), chapter("one", 1), chapter("two", 2)
        ])
        let identity = MediaIdentity(pluginId: Self.pluginID, itemId: media.key, mediaKind: .manga)
        let subject = makeMangaSubject(media: media)
        subject.progress.readChapterIDs[identity] = ["one"]

        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "two")
        // An unfinished chapter opened last wins over the first unread one.
        subject.progress.lastRead[identity] = "three"
        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "three")
        subject.progress.readChapterIDs[identity] = ["one", "two", "three"]
        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "three")
    }

    func testResumeEmptyAndStartResumeState() {
        let empty = makeMangaSubject(media: manga(chapters: []))
        XCTAssertNil(empty.viewModel.resumeChapter)
        XCTAssertFalse(empty.viewModel.hasReadProgress)

        let subject = makeMangaSubject(media: manga(chapters: [chapter("one", 1)]))
        let identity = subject.viewModel.mediaIdentity
        XCTAssertFalse(subject.viewModel.hasReadProgress)

        subject.progress.lastRead[identity] = "one"
        XCTAssertTrue(subject.viewModel.hasReadProgress)
    }

    func testTrackerSyncedReadChapterNumbersCountAsProgressWithoutChangingResumeTarget() {
        let media = manga(chapters: [
            chapter("one", 1), chapter("two", 2), chapter("three", 3)
        ])
        let subject = makeMangaSubject(media: media)
        let identity = subject.viewModel.mediaIdentity

        subject.progress.readChapterNumbers[identity] = [1, 2]

        XCTAssertTrue(subject.viewModel.hasReadProgress)
        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "three")
        XCTAssertNil(subject.progress.lastRead[identity])
    }

    func testNoSyncedReadMarkersMeansStartEvenWhenTrackerSyncIsDisabledOrProgressIsZero() {
        let subject = makeMangaSubject(media: manga(chapters: [chapter("one", 1)]))
        let identity = subject.viewModel.mediaIdentity

        subject.settings.autoSyncTrackersToLocal = false
        XCTAssertFalse(subject.viewModel.hasReadProgress)

        subject.settings.autoSyncTrackersToLocal = true
        subject.progress.readChapterNumbers[identity] = []
        XCTAssertFalse(subject.viewModel.hasReadProgress)
    }

    func testInitialAndExternalAuthoritativeLibraryStatePublication() async {
        let identity = MediaIdentity(pluginId: Self.pluginID, itemId: "m1", mediaKind: .manga)
        let subject = makeMangaSubject(
            libraryState: MediaDetailLibraryState(
                records: [MediaDetailLibraryRecord(itemID: "m1", pluginID: Self.pluginID, mediaKind: .manga)],
                hasCustomCategories: false
            )
        )
        XCTAssertTrue(subject.viewModel.isSaved)

        subject.library.publish(records: [], hasCustomCategories: true)
        await Task.yield()
        XCTAssertFalse(subject.viewModel.isSaved)
        XCTAssertTrue(subject.viewModel.hasCustomCategories)

        subject.library.publish(
            records: [MediaDetailLibraryRecord(itemID: "m1", pluginID: identity.pluginId, mediaKind: .manga)],
            hasCustomCategories: true
        )
        await Task.yield()
        XCTAssertTrue(subject.viewModel.isSaved)
    }

    func testDurableMangaSavePublishesSuccessOnlyAfterBoundaryCompletes() async {
        let subject = makeMangaSubject()
        subject.library.suspendSave = true
        let mutation = Task { await subject.viewModel.toggleSave() }
        await waitUntil { subject.library.pendingSaveCount == 1 }

        XCTAssertEqual(subject.viewModel.libraryMutationState, .saving)
        XCTAssertFalse(subject.viewModel.isSaved)
        XCTAssertTrue(subject.messages.messages.isEmpty)

        subject.library.resolveSave(with: .success(()))
        await mutation.value
        XCTAssertTrue(subject.viewModel.isSaved)
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertEqual(subject.messages.savedItemIDs, ["m1"])
        XCTAssertEqual(subject.library.saveKinds, [.manga])
    }

    func testAnimeAndNovelUseTheirTypedDurableSaveBoundaries() async {
        let animeSubject = makeAnimeSubject()
        await animeSubject.viewModel.toggleSave()
        XCTAssertEqual(animeSubject.library.saveKinds, [.anime])
        XCTAssertTrue(animeSubject.viewModel.isSaved)

        let novelSubject = makeNovelSubject()
        await novelSubject.viewModel.toggleSave()
        XCTAssertEqual(novelSubject.library.saveKinds, [.novel])
        XCTAssertTrue(novelSubject.viewModel.isSaved)
    }

    func testASavedNovelWithTheSameSourceKeyDoesNotMakeAMangaSavedOrUnsaveIt() async {
        let subject = makeMangaSubject(libraryState: MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m1", pluginID: Self.pluginID, mediaKind: .novel)],
            hasCustomCategories: false
        ))
        XCTAssertFalse(subject.viewModel.isSaved)

        await subject.viewModel.toggleSave()

        XCTAssertTrue(subject.viewModel.isSaved)
        XCTAssertEqual(subject.library.saveKinds, [.manga])
        XCTAssertTrue(subject.library.unsaveRequests.isEmpty)
        XCTAssertTrue(subject.library.state.records.contains { $0.mediaKind == .novel })
    }

    func testDurableUnsaveUpdatesOnlyAfterBoundaryCompletes() async {
        let savedState = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m1", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        let subject = makeMangaSubject(libraryState: savedState)
        subject.library.suspendUnsave = true
        let mutation = Task { await subject.viewModel.toggleSave() }
        await waitUntil { subject.library.pendingUnsaveCount == 1 }
        XCTAssertTrue(subject.viewModel.isSaved)

        subject.library.resolveUnsave(with: .success(()))
        await mutation.value
        XCTAssertFalse(subject.viewModel.isSaved)
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertEqual(subject.library.unsaveRequests.count, 1)
    }

    func testSaveFailureNeverPresentsSuccessOrCategoryAssignment() async {
        let subject = makeMangaSubject(customCategories: true, alwaysShowCategoryPicker: true)
        subject.library.saveError = MediaDetailTestFailure.expected

        await subject.viewModel.toggleSave()

        XCTAssertEqual(subject.viewModel.libraryMutationState, .failedSaving)
        XCTAssertFalse(subject.viewModel.isSaved)
        XCTAssertNil(subject.viewModel.categoryAssignmentIntent)
        XCTAssertEqual(subject.messages.messages, [.saveFailed])
    }

    func testUnsaveFailurePreservesAuthoritativeSavedState() async {
        let subject = makeMangaSubject(saved: true)
        subject.library.unsaveError = MediaDetailTestFailure.expected

        await subject.viewModel.toggleSave()

        XCTAssertEqual(subject.viewModel.libraryMutationState, .failedUnsaving)
        XCTAssertTrue(subject.viewModel.isSaved)
        XCTAssertNil(subject.viewModel.categoryAssignmentIntent)
        XCTAssertEqual(subject.messages.messages, [.unsaveFailed])
    }

    func testCategoryPickerDecisionRequiresNewDurableSavePreferenceAndCustomCategory() async {
        let subject = makeMangaSubject(customCategories: true, alwaysShowCategoryPicker: true)
        subject.library.durableSavedItemID = "plugin.test_m1"
        await subject.viewModel.toggleSave()

        let intent = subject.viewModel.categoryAssignmentIntent
        XCTAssertEqual(intent?.itemID, "plugin.test_m1")
        XCTAssertEqual(intent?.id, "plugin.test_m1")
        XCTAssertTrue(subject.messages.messages.isEmpty)

        subject.viewModel.dismissCategoryAssignment()
        XCTAssertNil(subject.viewModel.categoryAssignmentIntent)
    }

    func testCategoryPickerIsSkippedForSystemOnlyOrDisabledPreference() async {
        let systemOnly = makeMangaSubject(customCategories: false, alwaysShowCategoryPicker: true)
        systemOnly.library.durableSavedItemID = "plugin.test_m1"
        await systemOnly.viewModel.toggleSave()
        XCTAssertNil(systemOnly.viewModel.categoryAssignmentIntent)
        XCTAssertTrue(systemOnly.messages.messages.isEmpty)
        XCTAssertEqual(systemOnly.messages.savedItemIDs, ["plugin.test_m1"])

        let disabled = makeMangaSubject(customCategories: true, alwaysShowCategoryPicker: false)
        await disabled.viewModel.toggleSave()
        XCTAssertNil(disabled.viewModel.categoryAssignmentIntent)
        XCTAssertTrue(disabled.messages.messages.isEmpty)
        XCTAssertEqual(disabled.messages.savedItemIDs, ["m1"])
    }

    func testDuplicateLibraryMutationIsSuppressed() async {
        let subject = makeMangaSubject()
        subject.library.suspendSave = true
        let first = Task { await subject.viewModel.toggleSave() }
        await waitUntil { subject.library.pendingSaveCount == 1 }
        await subject.viewModel.toggleSave()
        XCTAssertEqual(subject.library.saveKinds, [.manga])

        subject.library.resolveSave(with: .success(()))
        await first.value
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertEqual(subject.messages.savedItemIDs, ["m1"])
    }

    func testDurableSaveCompletionAfterDisappearanceDoesNotPresentStaleOutput() async {
        let subject = makeMangaSubject(
            customCategories: true,
            alwaysShowCategoryPicker: true
        )
        subject.viewModel.appear()
        subject.viewModel.start()
        await waitUntil { subject.viewModel.detailLoadState == .content }
        subject.library.suspendSave = true
        let mutation = Task { await subject.viewModel.toggleSave() }
        await waitUntil { subject.library.pendingSaveCount == 1 }

        subject.viewModel.disappear()
        subject.library.resolveSave(with: .success(()))
        await mutation.value

        XCTAssertTrue(subject.viewModel.isSaved)
        XCTAssertNil(subject.viewModel.categoryAssignmentIntent)
        XCTAssertTrue(subject.messages.messages.isEmpty)
        XCTAssertTrue(subject.messages.savedItemIDs.isEmpty)
    }

    func testCachedThemeHitMissAndExtraction() async {
        let cachedTheme = ThemeColors(dominantHex: "#111111", secondaryHex: "#222222")
        let extractedTheme = ThemeColors(dominantHex: "#333333", secondaryHex: "#444444")
        let cached = makeMangaSubject()
        cached.theme.cachedResponses = [.value(cachedTheme)]
        cached.viewModel.start()
        await waitUntil { cached.viewModel.theme == cachedTheme }
        XCTAssertEqual(cached.theme.cachedKeys, ["m1"])

        let missing = makeMangaSubject()
        missing.theme.cachedResponses = [.value(nil)]
        missing.theme.extractionResponses = [.value(extractedTheme)]
        missing.viewModel.start()
        await waitUntil { missing.theme.cachedKeys.count == 1 }
        XCTAssertNil(missing.viewModel.theme)
        missing.viewModel.heroImageLoaded(UIImage())
        await waitUntil { missing.viewModel.theme == extractedTheme }
        XCTAssertEqual(missing.theme.extractionKeys, ["m1"])
    }

    func testStaleCachedThemeCannotReplaceNewerExtraction() async {
        let stale = ThemeColors(dominantHex: "#000001", secondaryHex: "#000002")
        let current = ThemeColors(dominantHex: "#000003", secondaryHex: "#000004")
        let subject = makeMangaSubject()
        subject.theme.cachedResponses = [.suspended]
        subject.theme.extractionResponses = [.value(current)]

        subject.viewModel.start()
        await waitUntil { subject.theme.pendingCachedCount == 1 }
        subject.viewModel.heroImageLoaded(UIImage())
        await waitUntil { subject.viewModel.theme == current }
        subject.theme.resolveCached(at: 0, value: stale)
        await Task.yield()
        XCTAssertEqual(subject.viewModel.theme, current)
    }

    func testExtractionReturningNoThemeDoesNotClearCurrentTheme() async {
        let cached = ThemeColors(dominantHex: "#010101", secondaryHex: "#020202")
        let subject = makeMangaSubject()
        subject.theme.cachedResponses = [.value(cached)]
        subject.theme.extractionResponses = [.value(nil)]
        subject.viewModel.start()
        await waitUntil { subject.viewModel.theme == cached }

        subject.viewModel.heroImageLoaded(UIImage())
        await waitUntil { subject.theme.extractionKeys.count == 1 }
        XCTAssertEqual(subject.viewModel.theme, cached)
    }

    func testStaleExtractionCannotReplaceNewerExtraction() async {
        let old = ThemeColors(dominantHex: "#100000", secondaryHex: "#200000")
        let new = ThemeColors(dominantHex: "#300000", secondaryHex: "#400000")
        let subject = makeMangaSubject()
        subject.theme.extractionResponses = [.suspended, .suspended]

        subject.viewModel.heroImageLoaded(UIImage())
        await waitUntil { subject.theme.pendingExtractionCount == 1 }
        subject.viewModel.heroImageLoaded(UIImage())
        await waitUntil { subject.theme.pendingExtractionCount == 2 }
        subject.theme.resolveExtraction(at: 1, value: new)
        await waitUntil { subject.viewModel.theme == new }
        subject.theme.resolveExtraction(at: 0, value: old)
        await Task.yield()
        XCTAssertEqual(subject.viewModel.theme, new)
    }

    func testRelinkSearchSuccessEmptyFailureRetryAndDismissal() async {
        let result = manga(key: "m2", title: "Result")
        let subject = makeMangaSubject()
        subject.route.searchResponses = [.value([result]), .value([]), .failure, .suspended]

        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        XCTAssertEqual(subject.route.searchQueries, ["Manga"])
        XCTAssertEqual(subject.viewModel.relinkSearchResults.map(\.key), ["m2"])

        subject.viewModel.retryRelinkSearch()
        await waitUntil { subject.viewModel.relinkSearchState == .empty }
        subject.viewModel.retryRelinkSearch()
        await waitUntil {
            if case .failure = subject.viewModel.relinkSearchState { return true }
            return false
        }
        subject.viewModel.retryRelinkSearch()
        await waitUntil { subject.route.pendingSearchCount == 1 }
        subject.viewModel.dismissRelink()
        subject.route.resolveSearch(at: 0, with: .success([result]))
        await Task.yield()
        XCTAssertNil(subject.viewModel.relinkPresentation)
        XCTAssertEqual(subject.viewModel.relinkSearchState, .idle)
        XCTAssertTrue(subject.viewModel.relinkSearchResults.isEmpty)
    }

    func testStaleRelinkSearchCannotOverwriteNewerSearch() async {
        let subject = makeMangaSubject()
        subject.route.searchResponses = [.suspended, .suspended]
        subject.viewModel.openRelink()
        await waitUntil { subject.route.pendingSearchCount == 1 }
        subject.viewModel.retryRelinkSearch()
        await waitUntil { subject.route.pendingSearchCount == 2 }

        subject.route.resolveSearch(
            at: 1,
            with: .success([manga(key: "new", title: "New")])
        )
        await waitUntil { subject.viewModel.relinkSearchResults.first?.key == "new" }
        subject.route.resolveSearch(
            at: 0,
            with: .failure(MediaDetailTestFailure.expected)
        )
        await Task.yield()
        XCTAssertEqual(subject.viewModel.relinkSearchState, .results)
        XCTAssertEqual(subject.viewModel.relinkSearchResults.first?.key, "new")
    }

    func testRelinkHydratesEncodesRemapsAndTransitionsIdentity() async throws {
        let selected = manga(key: "m2", title: "Selected")
        let hydrated = manga(
            key: "m2",
            title: "Hydrated",
            cover: "https://example.test/cover.jpg",
            chapters: [chapter("new-c", 4)]
        )
        let subject = makeMangaSubject(saved: true)
        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(hydrated)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        subject.tracker.states[MediaIdentity(pluginId: Self.pluginID, itemId: "m2", mediaKind: .manga)] =
            MediaDetailTrackerState(isAvailable: true, isTracked: true, anilistID: "55")

        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)

        XCTAssertEqual(subject.viewModel.media.key, "m2")
        XCTAssertEqual(subject.viewModel.media.title, "Hydrated")
        XCTAssertEqual(subject.viewModel.mediaIdentity, MediaIdentity(pluginId: Self.pluginID, itemId: "m2", mediaKind: .manga))
        XCTAssertNil(subject.viewModel.relinkPresentation)
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertTrue(subject.viewModel.isSaved)
        XCTAssertTrue(subject.viewModel.isTrackingAvailable)
        XCTAssertTrue(subject.viewModel.isTracked)
        XCTAssertEqual(subject.relink.requests.count, 1)
        let request = try XCTUnwrap(subject.relink.requests.first)
        XCTAssertEqual(
            request.possibleSourceItemIDs,
            ["m1", "\(Self.pluginID)_m1", "\(Self.pluginID)\u{1F}manga\u{1F}m1"]
        )
        XCTAssertEqual(request.destinationItemID, "m2")
        XCTAssertEqual(try JSONDecoder().decode(Manga.self, from: request.rawPayload).title, "Hydrated")
        XCTAssertEqual(subject.library.refreshCount, 1)
        XCTAssertEqual(subject.progress.refreshCount, 1)
        XCTAssertEqual(subject.tracker.refreshCount, 1)
        XCTAssertEqual(subject.baseline.refreshCount, 1)
    }

    func testRelinkHydrationAndRemapFailuresKeepOriginalMediaAndSheetUsable() async {
        let selected = manga(key: "m2", title: "Selected")
        let hydrationFailure = makeMangaSubject()
        hydrationFailure.route.searchResponses = [.value([selected])]
        hydrationFailure.route.loadResponses = [.failure]
        hydrationFailure.viewModel.openRelink()
        await waitUntil { hydrationFailure.viewModel.relinkSearchState == .results }
        await hydrationFailure.viewModel.performRelink(with: selected)
        XCTAssertEqual(hydrationFailure.viewModel.media.key, "m1")
        XCTAssertNotNil(hydrationFailure.viewModel.relinkPresentation)
        XCTAssertTrue(hydrationFailure.relink.requests.isEmpty)

        let remapFailure = makeMangaSubject()
        remapFailure.route.searchResponses = [.value([selected])]
        remapFailure.route.loadResponses = [.value(selected)]
        remapFailure.relink.error = MediaDetailTestFailure.expected
        remapFailure.viewModel.openRelink()
        await waitUntil { remapFailure.viewModel.relinkSearchState == .results }
        await remapFailure.viewModel.performRelink(with: selected)
        XCTAssertEqual(remapFailure.viewModel.media.key, "m1")
        XCTAssertNotNil(remapFailure.viewModel.relinkPresentation)
        if case .failure = remapFailure.viewModel.relinkMutationState {} else {
            XCTFail("Expected retryable relink failure")
        }
    }

    func testDuplicateRelinkMutationIsSuppressed() async {
        let selected = manga(key: "m2", title: "Selected")
        let subject = makeMangaSubject()
        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(selected), .value(selected)]
        subject.relink.suspend = true
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }

        let first = Task { await subject.viewModel.performRelink(with: selected) }
        await waitUntil { subject.relink.pendingCount == 1 }
        await subject.viewModel.performRelink(with: selected)
        XCTAssertEqual(subject.relink.requests.count, 1)
        subject.relink.resolve(with: .success(()))
        await first.value
        XCTAssertEqual(subject.viewModel.media.key, "m2")
    }

    func testRelinkInvalidatesOldDetailAndThemeOperations() async {
        let selected = manga(key: "m2", title: "Selected")
        let hydrated = manga(key: "m2", title: "Relinked")
        let staleMedia = manga(key: "m1", title: "Stale")
        let staleTheme = ThemeColors(dominantHex: "#AAAAAA", secondaryHex: "#BBBBBB")
        let currentTheme = ThemeColors(dominantHex: "#CCCCCC", secondaryHex: "#DDDDDD")
        let subject = makeMangaSubject(saved: true)
        subject.route.loadResponses = [.suspended, .value(hydrated)]
        subject.route.searchResponses = [.value([selected])]
        subject.theme.cachedResponses = [.suspended, .value(currentTheme)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )

        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 && subject.theme.pendingCachedCount == 1 }
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)
        await waitUntil { subject.viewModel.theme == currentTheme }
        subject.route.resolveLoad(at: 0, with: .success(staleMedia))
        subject.theme.resolveCached(at: 0, value: staleTheme)
        await Task.yield()

        XCTAssertEqual(subject.viewModel.media.title, "Relinked")
        XCTAssertEqual(subject.viewModel.theme, currentTheme)
    }

    func testStaleSaveCompletionAfterRelinkCannotPresentSuccess() async {
        let selected = manga(key: "m2", title: "Selected")
        let subject = makeMangaSubject(customCategories: true, alwaysShowCategoryPicker: true)
        subject.library.suspendSave = true
        let save = Task { await subject.viewModel.toggleSave() }
        await waitUntil { subject.library.pendingSaveCount == 1 }
        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(selected)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: true
        )
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)
        subject.library.resolveSave(with: .success(()))
        await save.value

        XCTAssertEqual(subject.viewModel.media.key, "m2")
        XCTAssertNil(subject.viewModel.categoryAssignmentIntent)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testTrackingAvailabilityTrackedPublicationAndSheetIntent() async {
        let subject = makeMangaSubject()
        XCTAssertFalse(subject.viewModel.isTrackingAvailable)
        subject.viewModel.openTrackerSheet()
        XCTAssertNil(subject.viewModel.trackerSheetIntent)

        let identity = subject.viewModel.mediaIdentity
        subject.tracker.publish(
            MediaDetailTrackerState(isAvailable: true, isTracked: true, anilistID: "42"),
            for: identity
        )
        await Task.yield()
        XCTAssertTrue(subject.viewModel.isTrackingAvailable)
        XCTAssertTrue(subject.viewModel.isTracked)
        subject.viewModel.openTrackerSheet()
        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.mediaIdentity, identity)
        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.title, "Manga")
        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.isAnime, false)
        subject.viewModel.dismissTrackerSheet()
        XCTAssertNil(subject.viewModel.trackerSheetIntent)
    }

    func testAnimeTrackerSheetIntentCarriesAnimeMediaType() {
        let subject = makeAnimeSubject()
        let identity = subject.viewModel.mediaIdentity
        subject.tracker.publish(
            MediaDetailTrackerState(isAvailable: true, isTracked: false, anilistID: nil),
            for: identity
        )

        subject.viewModel.openTrackerSheet()

        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.mediaIdentity, identity)
        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.title, "Anime")
        XCTAssertEqual(subject.viewModel.trackerSheetIntent?.isAnime, true)
    }

    func testTrackerCallbackAutoSyncRulesFailureAndDuplicateSuppression() async {
        let enabled = makeMangaSubject(autoSyncTrackersToLocal: true)
        enabled.viewModel.trackerDidSave(progress: 5)
        await waitUntil { enabled.progress.markRequests.count == 1 }
        XCTAssertEqual(enabled.progress.markRequests.first?.media, enabled.viewModel.mediaIdentity)
        XCTAssertEqual(enabled.progress.markRequests.first?.maximum, 5)
        enabled.viewModel.trackerDidSave(progress: 5)
        await Task.yield()
        XCTAssertEqual(enabled.progress.markRequests.count, 1)

        enabled.viewModel.trackerDidSave(progress: nil)
        XCTAssertEqual(enabled.progress.markRequests.count, 1)

        let disabled = makeMangaSubject(autoSyncTrackersToLocal: false)
        disabled.viewModel.trackerDidSave(progress: 8)
        await Task.yield()
        XCTAssertTrue(disabled.progress.markRequests.isEmpty)

        let failing = makeMangaSubject(autoSyncTrackersToLocal: true)
        failing.progress.markError = MediaDetailTestFailure.expected
        failing.viewModel.trackerDidSave(progress: 9)
        await waitUntil { failing.messages.messages == [.trackerProgressFailed] }
        XCTAssertEqual(failing.progress.markRequests.count, 1)
    }

    func testMangaReaderDestinationCarriesRunnerPluginMediaAndChapter() {
        let subject = makeMangaSubject(media: manga(chapters: [chapter("c1", 1), chapter("c2", 2)]))
        let selected = subject.viewModel.media.chapters![0]
        subject.viewModel.selectChapter(selected)

        guard case .pages(_, let runner, let pluginID, let media, let chapter) = subject.viewModel.readerDestination else {
            return XCTFail("Expected Manga reader destination")
        }
        XCTAssertTrue(runner === subject.runner)
        XCTAssertEqual(pluginID, Self.pluginID)
        XCTAssertEqual(media.key, "m1")
        XCTAssertEqual(chapter.key, "c1")

        subject.viewModel.selectChapter(subject.viewModel.media.chapters![1])
        guard case .pages(let secondID, _, _, _, let secondChapter) = subject.viewModel.readerDestination else {
            return XCTFail("Expected replacement Manga destination")
        }
        XCTAssertEqual(secondChapter.key, "c2")
        XCTAssertNotNil(secondID)
        subject.viewModel.dismissReader()
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testAnimeAndNovelReaderDestinationsAreTyped() {
        let animeSubject = makeAnimeSubject(media: anime(episodes: [episode("e1", 1)]))
        animeSubject.viewModel.selectChapter(animeSubject.viewModel.media.episodes![0])
        guard case .anime(_, let animeRunner, let animePlugin, let animeMedia, let selectedEpisode) = animeSubject.viewModel.readerDestination else {
            return XCTFail("Expected Anime video destination")
        }
        XCTAssertTrue(animeRunner === animeSubject.runner)
        XCTAssertEqual(animePlugin, Self.pluginID)
        XCTAssertEqual(animeMedia.key, "a1")
        XCTAssertEqual(selectedEpisode.key, "e1")

        let novelSubject = makeNovelSubject(media: novel(chapters: [novelChapter("n1", 1)]))
        novelSubject.viewModel.selectChapter(novelSubject.viewModel.media.chapters![0])
        guard case .text(_, let novelRunner, let novelPlugin, let entry, let selectedChapter) = novelSubject.viewModel.readerDestination else {
            return XCTFail("Expected text reader destination")
        }
        XCTAssertTrue(novelRunner === novelSubject.runner)
        XCTAssertEqual(novelPlugin, Self.pluginID)
        XCTAssertEqual(entry.kind, .novel)
        XCTAssertEqual(entry.key, "n1")
        XCTAssertEqual(selectedChapter.key, "n1")
    }

    func testBaselineRunsOnlyForSavedLoadedMediaAndDeduplicatesRecomputation() async {
        let unsaved = makeMangaSubject(media: manga(chapters: [chapter("c1", 1)]))
        unsaved.viewModel.start()
        await waitUntil { unsaved.viewModel.detailLoadState == .content }
        XCTAssertTrue(unsaved.baseline.requests.isEmpty)

        let saved = makeMangaSubject(media: manga(chapters: [chapter("c1", 1), chapter("c2", 2)]), saved: true)
        saved.viewModel.start()
        saved.viewModel.start()
        await waitUntil { saved.baseline.requests.count == 1 }
        XCTAssertEqual(saved.baseline.requests.first?.media, saved.viewModel.mediaIdentity)
        XCTAssertEqual(saved.baseline.requests.first?.knownChapterCount, 2)
        saved.viewModel.appear()
        saved.viewModel.appear()
        await Task.yield()
        XCTAssertEqual(saved.baseline.requests.count, 1)
    }

    func testBaselineFailureDoesNotCorruptDetailState() async {
        let subject = makeMangaSubject(saved: true)
        subject.baseline.error = MediaDetailTestFailure.expected
        subject.viewModel.start()
        await waitUntil { subject.baseline.requests.count == 1 }
        await Task.yield()
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testPostRelinkBaselineUsesCurrentIdentityAndCount() async {
        let selected = manga(key: "m2", title: "Selected", chapters: [chapter("c1", 1), chapter("c2", 2)])
        let subject = makeMangaSubject(saved: true)
        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(selected)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)
        let relinked = MediaIdentity(pluginId: Self.pluginID, itemId: "m2", mediaKind: .manga)
        await waitUntil { subject.baseline.requests.contains { $0.media == relinked } }

        let current = subject.baseline.requests.last
        XCTAssertEqual(current?.media, relinked)
        XCTAssertEqual(current?.knownChapterCount, 2)
    }

    func testDiscordLifecycleIsIdempotentAndDeterministic() {
        let subject = makeMangaSubject(media: manga(title: "Discord", cover: "cover"))
        let identity = subject.viewModel.mediaIdentity
        subject.tracker.states[identity] = MediaDetailTrackerState(
            isAvailable: true,
            isTracked: true,
            anilistID: "77"
        )
        subject.metadata.names[Self.pluginID] = "Plugin Name"

        subject.viewModel.appear()
        subject.viewModel.appear()
        XCTAssertEqual(subject.discord.events.count, 1)
        guard case .present(let activity) = subject.discord.events.first else {
            return XCTFail("Expected activity")
        }
        XCTAssertEqual(activity.details, "Discord")
        XCTAssertEqual(activity.state, "Viewing Details")
        XCTAssertEqual(activity.activityType, 3)
        XCTAssertEqual(activity.detailsURL, "https://anilist.co/manga/77")
        XCTAssertEqual(activity.largeImageText, "Browsing at Plugin Name")
        XCTAssertEqual(activity.imageURL, "cover")
        XCTAssertTrue(activity.resetTimer)

        subject.viewModel.disappear()
        subject.viewModel.disappear()
        subject.viewModel.appear()
        XCTAssertEqual(subject.discord.events.count, 3)
        if case .clear = subject.discord.events[1] {} else {
            XCTFail("Expected clear between appearances")
        }
        if case .present(let repeated) = subject.discord.events[2] {
            XCTAssertEqual(repeated.details, activity.details)
            XCTAssertEqual(repeated.detailsURL, activity.detailsURL)
        } else {
            XCTFail("Expected repeated activity")
        }
    }

    func testDiscordUsesNoTrackerURLWhenUnavailableAndPostRelinkCurrentMedia() async {
        let selected = manga(key: "m2", title: "Relinked", cover: "new-cover")
        let subject = makeMangaSubject(saved: true)
        subject.viewModel.appear()
        guard case .present(let initial) = subject.discord.events.last else {
            return XCTFail("Expected initial activity")
        }
        XCTAssertNil(initial.detailsURL)

        subject.route.searchResponses = [.value([selected])]
        subject.route.loadResponses = [.value(selected)]
        subject.library.stateOnRefresh = MediaDetailLibraryState(
            records: [MediaDetailLibraryRecord(itemID: "m2", pluginID: Self.pluginID, mediaKind: .manga)],
            hasCustomCategories: false
        )
        subject.tracker.states[MediaIdentity(pluginId: Self.pluginID, itemId: "m2", mediaKind: .manga)] =
            MediaDetailTrackerState(isAvailable: true, isTracked: true, anilistID: "88")
        subject.viewModel.openRelink()
        await waitUntil { subject.viewModel.relinkSearchState == .results }
        await subject.viewModel.performRelink(with: selected)

        guard case .present(let current) = subject.discord.events.last else {
            return XCTFail("Expected current activity")
        }
        XCTAssertEqual(current.details, "Relinked")
        XCTAssertEqual(current.imageURL, "new-cover")
        XCTAssertEqual(current.detailsURL, "https://anilist.co/manga/88")
    }

    func testCancelScreenOperationsInvalidatesSupersedablePublication() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [.suspended]
        subject.theme.cachedResponses = [.suspended]
        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 && subject.theme.pendingCachedCount == 1 }
        subject.viewModel.cancelScreenOperations()
        subject.route.resolveLoad(at: 0, with: .success(manga(key: "m1", title: "Late")))
        subject.theme.resolveCached(
            at: 0,
            value: ThemeColors(dominantHex: "#1", secondaryHex: "#2")
        )
        await Task.yield()
        XCTAssertEqual(subject.viewModel.detailLoadState, .idle)
        XCTAssertEqual(subject.viewModel.media.title, "Manga")
        XCTAssertNil(subject.viewModel.theme)
    }

    func testDisappearCancelsSupersedableWorkAndReappearRestartsCurrentMedia() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [.suspended, .suspended]
        subject.theme.cachedResponses = [.suspended, .suspended]
        subject.viewModel.appear()
        subject.viewModel.start()
        await waitUntil { subject.route.pendingLoadCount == 1 && subject.theme.pendingCachedCount == 1 }

        subject.viewModel.disappear()
        XCTAssertEqual(subject.viewModel.detailLoadState, .idle)
        subject.viewModel.appear()
        await waitUntil { subject.route.pendingLoadCount == 2 && subject.theme.pendingCachedCount == 2 }

        let currentTheme = ThemeColors(dominantHex: "#A", secondaryHex: "#B")
        subject.route.resolveLoad(
            at: 1,
            with: .success(manga(key: "m1", title: "Returned"))
        )
        subject.theme.resolveCached(at: 1, value: currentTheme)
        await waitUntil {
            subject.viewModel.media.title == "Returned" && subject.viewModel.theme == currentTheme
        }
        subject.route.resolveLoad(
            at: 0,
            with: .success(manga(key: "m1", title: "Stale"))
        )
        subject.theme.resolveCached(
            at: 0,
            value: ThemeColors(dominantHex: "#C", secondaryHex: "#D")
        )
        await Task.yield()
        XCTAssertEqual(subject.viewModel.media.title, "Returned")
        XCTAssertEqual(subject.viewModel.theme, currentTheme)
    }

    // MARK: - Subjects

    private static let pluginID = "plugin.test"

    private struct MangaSubject {
        let viewModel: MediaDetailViewModel<Manga>
        let route: MediaRouteHarness<Manga>
        let library: MediaDetailLibraryFake
        let progress: MediaDetailProgressFake
        let tracker: MediaDetailTrackerFake
        let theme: MediaDetailThemeFake
        let relink: MediaDetailRelinkFake
        let baseline: MediaDetailBaselineFake
        let settings: MediaDetailSettingsFake
        let metadata: MediaDetailPluginMetadataFake
        let discord: MediaDetailDiscordFake
        let messages: MediaDetailMessageSpy
        let runner: ItoRunner
    }

    private struct AnimeSubject {
        let viewModel: MediaDetailViewModel<Anime>
        let library: MediaDetailLibraryFake
        let tracker: MediaDetailTrackerFake
        let runner: ItoRunner
    }

    private struct NovelSubject {
        let viewModel: MediaDetailViewModel<Novel>
        let library: MediaDetailLibraryFake
        let runner: ItoRunner
    }

    private func makeMangaSubject(
        media providedMedia: Manga? = nil,
        libraryState explicitState: MediaDetailLibraryState? = nil,
        saved: Bool = false,
        customCategories: Bool = false,
        alwaysShowCategoryPicker: Bool = false,
        autoSyncTrackersToLocal: Bool = true
    ) -> MangaSubject {
        let media = providedMedia ?? manga()
        let state = explicitState ?? MediaDetailLibraryState(
            records: saved
                ? [MediaDetailLibraryRecord(itemID: media.key, pluginID: Self.pluginID, mediaKind: .manga)]
                : [],
            hasCustomCategories: customCategories
        )
        let library = MediaDetailLibraryFake(state: state)
        let progress = MediaDetailProgressFake()
        let tracker = MediaDetailTrackerFake()
        let theme = MediaDetailThemeFake()
        let relink = MediaDetailRelinkFake()
        let baseline = MediaDetailBaselineFake()
        let settings = MediaDetailSettingsFake(
            alwaysShowCategoryPicker: alwaysShowCategoryPicker,
            autoSyncTrackersToLocal: autoSyncTrackersToLocal
        )
        let metadata = MediaDetailPluginMetadataFake()
        let discord = MediaDetailDiscordFake()
        let messages = MediaDetailMessageSpy()
        let route = MediaRouteHarness<Manga>()
        let runner = ItoRunner()
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: { try await route.load($0) },
            searchForRelink: { try await route.search($0) },
            makeReaderDestination: { parent, selected in
                .pages(
                    id: UUID(),
                    runner: runner,
                    pluginID: Self.pluginID,
                    entry: .manga(parent),
                    chapter: selected
                )
            }
        )
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: PreparedMediaDetailDependencies(
                library: library,
                progress: progress,
                tracker: tracker,
                theme: theme,
                relink: relink,
                baseline: baseline,
                settings: settings,
                pluginMetadata: metadata,
                discord: discord
            ),
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
        return MangaSubject(
            viewModel: viewModel,
            route: route,
            library: library,
            progress: progress,
            tracker: tracker,
            theme: theme,
            relink: relink,
            baseline: baseline,
            settings: settings,
            metadata: metadata,
            discord: discord,
            messages: messages,
            runner: runner
        )
    }

    private func makeAnimeSubject(
        media providedMedia: Anime? = nil,
        hydrated: Anime? = nil
    ) -> AnimeSubject {
        let media = providedMedia ?? anime()
        let library = MediaDetailLibraryFake()
        let tracker = MediaDetailTrackerFake()
        let dependencies = PreparedMediaDetailDependencies(
            library: library,
            progress: MediaDetailProgressFake(),
            tracker: tracker,
            theme: MediaDetailThemeFake(),
            relink: MediaDetailRelinkFake(),
            baseline: MediaDetailBaselineFake(),
            settings: MediaDetailSettingsFake(),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake()
        )
        let runner = ItoRunner()
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: MediaDetailRouteContext(
                loadDetails: { _ in hydrated ?? media },
                searchForRelink: { _ in [] },
                makeReaderDestination: { parent, selected in
                    .anime(
                        id: UUID(),
                        runner: runner,
                        pluginID: Self.pluginID,
                        media: parent,
                        episode: selected
                    )
                }
            ),
            dependencies: dependencies,
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        return AnimeSubject(
            viewModel: viewModel,
            library: library,
            tracker: tracker,
            runner: runner
        )
    }

    private func makeNovelSubject(media providedMedia: Novel? = nil) -> NovelSubject {
        let media = providedMedia ?? novel()
        let library = MediaDetailLibraryFake()
        let dependencies = makeDependencies(library: library)
        let runner = ItoRunner()
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: MediaDetailRouteContext(
                loadDetails: { $0 },
                searchForRelink: { _ in [] },
                makeReaderDestination: { parent, selected in
                    .text(
                        id: UUID(),
                        runner: runner,
                        pluginID: Self.pluginID,
                        entry: .novel(parent),
                        chapter: selected
                    )
                }
            ),
            dependencies: dependencies,
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        return NovelSubject(viewModel: viewModel, library: library, runner: runner)
    }

    private func makeDependencies(library: MediaDetailLibraryFake) -> PreparedMediaDetailDependencies {
        PreparedMediaDetailDependencies(
            library: library,
            progress: MediaDetailProgressFake(),
            tracker: MediaDetailTrackerFake(),
            theme: MediaDetailThemeFake(),
            relink: MediaDetailRelinkFake(),
            baseline: MediaDetailBaselineFake(),
            settings: MediaDetailSettingsFake(),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake()
        )
    }

    private func manga(
        key: String = "m1",
        title: String = "Manga",
        cover: String? = nil,
        chapters: [Manga.Chapter]? = nil
    ) -> Manga {
        Manga(key: key, title: title, cover: cover, chapters: chapters)
    }

    private func anime(
        key: String = "a1",
        title: String = "Anime",
        episodes: [Anime.Episode]? = nil,
        seasons: [Anime.Season]? = nil
    ) -> Anime {
        Anime(key: key, title: title, episodes: episodes, seasons: seasons)
    }

    private func novel(
        key: String = "n1",
        title: String = "Novel",
        chapters: [Novel.Chapter]? = nil
    ) -> Novel {
        Novel(key: key, title: title, chapters: chapters)
    }

    private func chapter(_ key: String, _ number: Float?, date: Double? = nil) -> Manga.Chapter {
        Manga.Chapter(key: key, title: key, chapter: number, dateUpdated: date)
    }

    private func episode(_ key: String, _ number: Float?) -> Anime.Episode {
        Anime.Episode(key: key, title: key, episode: number) }

    private func novelChapter(_ key: String, _ number: Float?) -> Novel.Chapter {
        Novel.Chapter(key: key, title: key, chapter: number) }
}
