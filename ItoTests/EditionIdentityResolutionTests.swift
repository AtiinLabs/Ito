import Foundation
import Testing
@testable import Ito

struct EditionIdentityResolutionTests {
    @Test func v1AndV2DecodeAndLegacyKindsKeepWritingV2() throws {
        let v1 = Data(#"{"formatVersion":1,"kind":"scanlators","scanlators":[{"id":"g1","name":"Old"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(EditionSelection.self, from: v1)
        #expect(decoded == .scanlators([ScanlatorRef(id: "g1", name: "Old")]))
        let encoded = try decoded.storageData()
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["formatVersion"] as? Int == 2)
        #expect(try JSONDecoder().decode(EditionSelection.self, from: encoded) == decoded)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditionSelection.self, from: Data(#"{"formatVersion":4,"kind":"sourceList"}"#.utf8))
        }
    }

    @Test func untaggedIDlessV1AndV2ReferencesRemainLegacyNameIntent() throws {
        for version in [1, 2] {
            let bytes = Data(
                #"{"formatVersion":\#(version),"kind":"scanlators","scanlators":[{"name":"Group"}]}"#.utf8
            )
            let selection = try JSONDecoder().decode(EditionSelection.self, from: bytes)
            #expect(selection == .scanlators([ScanlatorRef(name: "Group")]))
        }
    }

    @Test func boundIDSurvivesRenameButCannotFallBackToSameNameOrMissingID() throws {
        let bound = EditionSelection.scanlators([ScanlatorRef(id: "g1", name: "Old")])
        let renamed = [ScanlatorRef(id: "g1", name: "Current")]
        #expect(bound.resolved(in: renamed) == .scanlators([ScanlatorRef(id: "g1", name: "Current")]))
        let resolved = try #require(ScanlatorCatalogIndex(renamed).resolve(bound))
        #expect(resolved.admits(scanlator: "Current", groupID: "g1"))
        #expect(!resolved.admits(scanlator: "Old", groupID: "g2"))
        #expect(!resolved.admits(scanlator: "Old", groupID: nil))
        #expect(bound.resolved(in: [ScanlatorRef(id: "g2", name: "Old")]) == nil)
        #expect(bound.resolved(in: [ScanlatorRef(name: "Old")]) == nil)
    }

    @Test func legacyNameResolvesOnlyWhenCatalogWideIdentityIsUnique() {
        let legacy = EditionSelection.scanlators([ScanlatorRef(name: "Group")])
        #expect(legacy.resolved(in: [ScanlatorRef(id: "g1", name: "Group")]) ==
                .scanlators([ScanlatorRef(id: "g1", name: "Group")]))
        let idlessCatalog = [ScanlatorRef(name: "Group", binding: .exactIDless)]
        #expect(legacy.resolved(in: [ScanlatorRef(name: "Group")]) == .scanlators(idlessCatalog))
        #expect(legacy.resolved(in: [ScanlatorRef(id: "g1", name: "Group"), ScanlatorRef(id: "g2", name: "Group")]) == nil)
        #expect(legacy.resolved(in: [ScanlatorRef(id: "g1", name: "Group"), ScanlatorRef(name: "Group")]) == nil)
        #expect(EditionSelection.scanlators([ScanlatorRef(name: nil)]).resolved(
            in: [ScanlatorRef(id: "g1", name: nil)]
        ) == nil)
    }

    @Test func exactIDlessBindingIsVersionedAndNeverUpgradesToANameMatch() throws {
        let legacy = ScanlatorRef(name: "Group")
        let explicitIDless = ScanlatorRef(name: "Group", binding: .exactIDless)
        #expect(legacy == ScanlatorRef(name: "Group", binding: .legacyName))
        #expect(legacy != explicitIDless)
        #expect(Set([legacy, explicitIDless]).count == 2)

        let mixed = [ScanlatorRef(name: "Group"), ScanlatorRef(id: "g1", name: "Group")]
        let resolved = try #require(ScanlatorCatalogIndex(mixed).resolve(.scanlators([explicitIDless])))
        #expect(resolved.selection == .scanlators([explicitIDless]))
        #expect(resolved.admits(scanlator: "Group", groupID: nil))
        #expect(!resolved.admits(scanlator: "Group", groupID: "g1"))
        #expect(ScanlatorCatalogIndex([ScanlatorRef(id: "g1", name: "Group")])
            .resolve(.scanlators([explicitIDless])) == nil)

        let v1Tag = Data(
            #"{"formatVersion":1,"kind":"scanlators","scanlators":[{"name":"Group","binding":"exactIDless"}]}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditionSelection.self, from: v1Tag)
        }
        let v2 = try EditionSelection.scanlators([explicitIDless]).storageData()
        #expect(try JSONDecoder().decode(EditionSelection.self, from: v2) == .scanlators([explicitIDless]))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EditionSelection.self,
                from: Data(#"{"formatVersion":2,"kind":"scanlators","scanlators":[{"id":"g1","name":"Group","binding":"exactIDless"}]}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EditionSelection.self,
                from: Data(#"{"formatVersion":2,"kind":"scanlators","scanlators":[{"name":"Group","binding":"future"}]}"#.utf8)
            )
        }
    }

    @Test func groupDiagnosticsUseIDIdentityRatherThanCachedLabels() {
        let duplicateIDs = [
            DownloadPlanRow(facts: ChapterFacts(key: "old", number: 1, scanlator: "Old label", scanlatorID: "same-id")),
            DownloadPlanRow(facts: ChapterFacts(key: "new", number: 1, scanlator: "Current label", scanlatorID: "same-id"))
        ]
        let sameID = DownloadPresetResolver.plan(
            rows: duplicateIDs, preset: .all, selection: .sourceList, anchorKey: nil
        )
        #expect(!sameID.issues.contains(.multipleScanlators))
        #expect(!sameID.issues.contains(.alternativeUploads))

        let differentIDs = [
            DownloadPlanRow(facts: ChapterFacts(key: "a", number: 1, scanlator: "Shared", scanlatorID: "id-a")),
            DownloadPlanRow(facts: ChapterFacts(key: "b", number: 1, scanlator: "Shared", scanlatorID: "id-b"))
        ]
        let sameLabel = DownloadPresetResolver.plan(
            rows: differentIDs, preset: .all, selection: .sourceList, anchorKey: nil
        )
        #expect(sameLabel.issues.contains(.multipleScanlators))
        #expect(sameLabel.issues.contains(.alternativeUploads))

        let byteDistinctNames = [
            DownloadPlanRow(facts: ChapterFacts(key: "c", number: 1, scanlator: "é")),
            DownloadPlanRow(facts: ChapterFacts(key: "d", number: 1, scanlator: "e\u{301}"))
        ]
        let exactLabels = DownloadPresetResolver.plan(
            rows: byteDistinctNames, preset: .all, selection: .sourceList, anchorKey: nil
        )
        #expect(exactLabels.issues.contains(.multipleScanlators))
        #expect(exactLabels.issues.contains(.alternativeUploads))
    }

    @MainActor @Test func scanlatorIdentityUsesExactUTF8AndIgnoresBoundLabels() {
        let composed = ScanlatorRef(id: "é", name: "Old")
        let decomposed = ScanlatorRef(id: "e\u{301}", name: "New")
        #expect(composed == ScanlatorRef(id: "é", name: "Renamed"))
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(ScanlatorRef(name: nil) != ScanlatorRef(name: ""))
        #expect(ScanlatorOption(ref: composed, chapterCount: 1).id != ScanlatorOption(ref: decomposed, chapterCount: 1).id)
        #expect(
            ScanlatorOption(ref: ScanlatorRef(name: nil, binding: .exactIDless), chapterCount: 1).id
                != ScanlatorOption(ref: ScanlatorRef(name: "", binding: .exactIDless), chapterCount: 1).id
        )
    }

    @Test func ambiguityIsResolvedBeforeReadAndLockFiltering() {
        let rows = [
            DownloadPlanRow(facts: ChapterFacts(key: "locked", number: 1, scanlator: "Group", scanlatorID: "g1", isLocked: true)),
            DownloadPlanRow(facts: ChapterFacts(key: "read", number: 2, scanlator: "Group", scanlatorID: "g2"), isRead: true)
        ]
        let result = DownloadPresetResolver.plan(
            rows: rows,
            preset: .all,
            selection: .scanlators([ScanlatorRef(name: "Group")]),
            anchorKey: nil
        )
        #expect(result.toQueue.isEmpty)
        #expect(result.satisfied.isEmpty)
        #expect(result.locked.isEmpty)
    }

    @Test func ambiguousSavedCoverageCannotClaimEntireSeries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = [
            ChapterFacts(key: "a", number: 1, scanlator: "Group", scanlatorID: "g1"),
            ChapterFacts(key: "b", number: 1, scanlator: "Group", scanlatorID: "g2")
        ]
        let digest = String(repeating: "a", count: 64)
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: SeriesOfflineSnapshot(catalogScope: .complete, payloadSHA256: digest, refreshedAt: now),
            currentPayloadSHA256: digest,
            selection: .scanlators([ScanlatorRef(name: "Group")]),
            catalog: catalog,
            states: ["a": .downloaded, "b": .downloaded],
            now: now
        )
        #expect(result == .saved(2))
    }

    @Test func explicitIDlessCoverageDoesNotCountOrUpgradeASameNameID() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = String(repeating: "b", count: 64)
        let catalog = [
            ChapterFacts(key: "idless", number: 1, scanlator: "Group"),
            ChapterFacts(key: "identified", number: 1, scanlator: "Group", scanlatorID: "g1")
        ]
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: SeriesOfflineSnapshot(catalogScope: .complete, payloadSHA256: digest, refreshedAt: now),
            currentPayloadSHA256: digest,
            selection: .scanlators([ScanlatorRef(name: "Group", binding: .exactIDless)]),
            catalog: catalog,
            states: ["idless": .downloaded],
            now: now
        )
        #expect(result == .entireSeries)

        let noIDlessRows = SeriesOfflineCoverage.evaluate(
            snapshot: SeriesOfflineSnapshot(catalogScope: .complete, payloadSHA256: digest, refreshedAt: now),
            currentPayloadSHA256: digest,
            selection: .scanlators([ScanlatorRef(name: "Group", binding: .exactIDless)]),
            catalog: [catalog[1]],
            states: ["identified": .downloaded],
            now: now
        )
        #expect(noIDlessRows == .saved(1))
    }
}
