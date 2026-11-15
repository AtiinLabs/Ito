import Foundation
import Testing
import ito_runner
@testable import Ito

/// What a chosen saved copy records once its reader opens, and what the chooser says about each copy.
@MainActor
struct DownloadedAlternativeEffectsTests {
    private static let pluginID = "plugin.test"

    private func candidate(
        _ key: String,
        group: String?,
        groupID: String?,
        form: OfflineContentKind = .images,
        title: String? = "Title"
    ) -> DownloadedChapterAlternative {
        var chapter = Chapter.upload(key, group: group, groupID: groupID)
        chapter.title = title
        return DownloadedChapterAlternative(
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
            contentKind: form,
            chapter: chapter
        )
    }

    private func context() -> DownloadedAlternativeContext {
        DownloadedAlternativeContext(
            id: UUID(),
            anchor: .saved(edition: OfflineChapterEdition(
                pluginId: Self.pluginID,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "a"
            )),
            mediaIdentity: MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-1", mediaKind: .manga),
            detailGeneration: 0,
            sourceEpoch: nil
        )
    }

    // MARK: - 39, 40

    @Test func theSelectedCopyIsRecordedOnceAsItsOwnChapterAndFormatUnderTheCatalogKind() async throws {
        let real = try await RealAlternativeFixture.make(
            upload: .upload("b", group: "Other", groupID: "g-b"),
            pages: [OfflineStoreFixture.textPage(0, "Saved words.")]
        )
        let lease = try await real.openLease()
        let destination = try MediaDetailReaderDestination.downloadedAlternative(
            real.candidate,
            lease: lease,
            of: .manga(Manga(key: "series-1", title: "Series One", chapters: [.upload("a"), .upload("b")])),
            remote: nil,
            pluginID: Self.pluginID
        )
        guard case .text(_, let content, _, let entry, let chapter) = destination else {
            Issue.record("A copy saved as text opens the text reader")
            return
        }
        let subject = makeNovelReaderSubject(entry: entry, initialChapter: chapter)
        let loader = ResolvingNovelChapterLoader(
            pluginID: Self.pluginID,
            local: real.store,
            remote: nil,
            preference: content.preference
        )
        let viewModel = NovelReaderViewModel(
            chapterLoader: loader,
            pluginID: Self.pluginID,
            entry: entry,
            initialChapter: chapter,
            dependencies: subject.dependencies,
            offline: ReaderOfflineContext()
        )
        // Choosing and opening so far recorded nothing.
        #expect(subject.history.requests.isEmpty)
        #expect(subject.progress.requests.isEmpty)
        #expect(subject.tracker.requests.isEmpty)

        viewModel.start()
        await viewModel.waitForAllOperationsForTesting()

        let recorded = subject.history.requests
        #expect(recorded.map(\.chapterKey) == ["b"])
        #expect(recorded.first?.format == .text)
        #expect(recorded.first?.entry.kind == .manga)
        #expect(recorded.first?.scanlator == "Other")
        #expect(recorded.first?.chapterTitle == "Title b")
        // History stores the novel body length in UTF-16 units, each text block followed by its separator.
        #expect(recorded.first?.textLength == ("Saved words." as NSString).length + NovelTextOffsets.blockSeparator.utf16.count)
        #expect(recorded.first?.pluginID == Self.pluginID)
        // Reading has not finished, so nothing else is written.
        #expect(subject.progress.requests.isEmpty)
        #expect(subject.tracker.requests.isEmpty)
    }

    // MARK: - 43

    @Test func eachRowKeepsItsExactGroupIDAndSavedFormAndNeverInventsAnIdentity() {
        let named = DownloadedAlternativeRowModel(candidate("b", group: "Same", groupID: "id-1", form: .images))
        let sameNameOtherID = DownloadedAlternativeRowModel(candidate("c", group: "Same", groupID: "id-2", form: .text))
        let nameOnly = DownloadedAlternativeRowModel(candidate("d", group: "Same", groupID: nil, form: .mixed))
        let idOnly = DownloadedAlternativeRowModel(candidate("e", group: nil, groupID: "id-3"))
        let neither = DownloadedAlternativeRowModel(candidate("f", group: nil, groupID: nil, title: nil))
        let emptyName = DownloadedAlternativeRowModel(candidate("g", group: "", groupID: ""))

        #expect(named.group == .named("Same", id: "id-1"))
        #expect(sameNameOtherID.group == .named("Same", id: "id-2"))
        #expect(named.group != sameNameOtherID.group)
        #expect(nameOnly.group == .named("Same", id: nil))
        #expect(idOnly.group == .unnamed(id: "id-3"))
        #expect(neither.group == .none)
        #expect(emptyName.group == .none)
        #expect([named.form, sameNameOtherID.form, nameOnly.form] == [.images, .text, .mixed])
        // Source content is kept exactly as saved.
        #expect(named.key == "b")
        #expect(named.title == "Title")
        #expect(neither.title == nil)
    }

    @Test func confirmationNeedsASelectionWaitsWhileOpeningAndNeverSurvivesAnEmptyOrFailedList() {
        let b = candidate("b", group: nil, groupID: nil)
        let context = context()
        let unselected = DownloadedAlternativeSelectorState.choosing(
            context: context, candidates: [b], selectedCandidateID: nil, failure: nil
        )
        let selected = DownloadedAlternativeSelectorState.choosing(
            context: context, candidates: [b], selectedCandidateID: b.id, failure: nil
        )
        let forged = DownloadedAlternativeSelectorState.choosing(
            context: context, candidates: [b], selectedCandidateID: "forged", failure: nil
        )
        let acquiring = DownloadedAlternativeSelectorState.acquiring(
            context: context, candidates: [b], selectedCandidateID: b.id
        )
        let empty = DownloadedAlternativeSelectorState.choosing(
            context: context, candidates: [], selectedCandidateID: nil, failure: nil
        )

        #expect(!DownloadedAlternativeSheet.canConfirm(.idle))
        #expect(!DownloadedAlternativeSheet.canConfirm(.loading(context)))
        #expect(!DownloadedAlternativeSheet.canConfirm(unselected))
        #expect(DownloadedAlternativeSheet.canConfirm(selected))
        #expect(!DownloadedAlternativeSheet.canConfirm(forged))
        #expect(!DownloadedAlternativeSheet.canConfirm(acquiring))
        #expect(!DownloadedAlternativeSheet.canConfirm(empty))
        #expect(!DownloadedAlternativeSheet.canConfirm(.failed(context, .selection(.sourceChanged))))
        #expect(!DownloadedAlternativeSheet.canConfirm(.handingOff(context)))
        #expect(DownloadedAlternativeSheet.isAcquiring(acquiring))
        #expect(!DownloadedAlternativeSheet.isAcquiring(selected))
    }

    @Test func everyFailureHasItsOwnHostMessageAndReadFailuresKeepTheirTypedText() {
        let selections: [DownloadedAlternativeError] = [
            .unavailable, .inventoryUnavailable, .selectionChanged, .sourceChanged, .unsupportedMediaKind
        ]
        let messages = selections.map { DownloadedAlternativeSheet.message(for: .selection($0)) }

        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == selections.count)
        #expect(
            DownloadedAlternativeSheet.message(for: .read(.protectedDataUnavailable))
                == OfflineReadError.protectedDataUnavailable.errorDescription
        )
        #expect(
            DownloadedAlternativeSheet.message(for: .read(.localCopyDamaged))
                == OfflineReadError.localCopyDamaged.errorDescription
        )
    }
}
