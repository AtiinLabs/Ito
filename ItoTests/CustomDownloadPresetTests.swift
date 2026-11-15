import Foundation
import Testing
@testable import Ito

struct CustomDownloadPresetTests {
    @Test func positionCountAcceptsOnlyOneThroughOneThousand() {
        #expect(DownloadPositionCount(0) == nil)
        #expect(DownloadPositionCount(1)?.value == 1)
        #expect(DownloadPositionCount(1000)?.value == 1000)
        #expect(DownloadPositionCount(1001) == nil)
    }

    @Test func nameIsTrimmedAndCaseIsPreserved() {
        #expect(CustomPresetName(validating: "  Weekly Catch-Up \n")?.value == "Weekly Catch-Up")
        #expect(CustomPresetName(validating: "MiXed")?.value == "MiXed")
    }

    @Test func emptyOrWhitespaceOnlyNamesAreRejected() {
        #expect(CustomPresetName(validating: "") == nil)
        #expect(CustomPresetName(validating: " \t  ") == nil)
    }

    @Test func controlLineAndParagraphSeparatorsInsideANameAreRejected() {
        #expect(CustomPresetName(validating: "a\nb") == nil)
        #expect(CustomPresetName(validating: "a\tb") == nil)
        #expect(CustomPresetName(validating: "a\u{2028}b") == nil)
        #expect(CustomPresetName(validating: "a\u{0007}b") == nil)
    }

    @Test func nameLengthCountsCharactersUpToFortyAndBytesUpToTwoFiftySix() {
        #expect(CustomPresetName(validating: String(repeating: "a", count: 40)) != nil)
        #expect(CustomPresetName(validating: String(repeating: "a", count: 41)) == nil)
        // One ZWJ family emoji is one Character of 18 UTF-8 bytes; forty of them exceed the byte limit.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(CustomPresetName(validating: family) != nil)
        #expect(CustomPresetName(validating: String(repeating: family, count: 40)) == nil)
    }

    @Test func nfcAndNfdNamesStayDistinctBytes() throws {
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        let nfc = try #require(CustomPresetName(validating: composed))
        let nfd = try #require(CustomPresetName(validating: decomposed))
        #expect(Array(nfc.value.utf8) != Array(nfd.value.utf8))
        #expect(Array(nfc.value.utf8) == Array(composed.utf8))
    }

    @Test func actionsMapToWindowsAndProvenance() throws {
        let count = try #require(DownloadPositionCount(7))
        let custom = CustomDownloadPreset(
            id: UUID(), name: nil, rule: .more(count)
        )

        #expect(DownloadAction.builtIn(.next5).window == .next(.builtIn(5)))
        #expect(DownloadAction.builtIn(.all).window == .all)
        #expect(DownloadAction.more(count).window == .more(count))
        #expect(DownloadAction.custom(custom).window == .more(count))
        #expect(DownloadAction.builtIn(.next10).provenance == .builtIn(.next10))
        #expect(DownloadAction.more(count).provenance == DownloadBatchProvenance(
            preset: .more, windowKind: .more, positionCount: 7, customPresetId: nil
        ))
        #expect(DownloadAction.custom(custom).provenance == DownloadBatchProvenance(
            preset: .custom, windowKind: .more, positionCount: 7, customPresetId: custom.id.uuidString
        ))
    }

    @Test func provenanceConsistencyFollowsTheStoredCheckRules() {
        let id = UUID().uuidString
        #expect(DownloadBatchProvenance.single.isConsistent)
        #expect(DownloadBatchProvenance.builtIn(.next).isConsistent)
        #expect(DownloadBatchProvenance(preset: .more, windowKind: .more, positionCount: 3, customPresetId: nil).isConsistent)
        #expect(DownloadBatchProvenance(preset: .custom, windowKind: .next, positionCount: 3, customPresetId: id).isConsistent)

        // Built-ins never carry a count or a custom id.
        #expect(!DownloadBatchProvenance(preset: .next, windowKind: nil, positionCount: 3, customPresetId: nil).isConsistent)
        // More must be a more window; custom needs an id.
        #expect(!DownloadBatchProvenance(preset: .more, windowKind: .next, positionCount: 3, customPresetId: nil).isConsistent)
        #expect(!DownloadBatchProvenance(preset: .custom, windowKind: .next, positionCount: 3, customPresetId: nil).isConsistent)
        // Counts outside 1...1000 are refused.
        #expect(!DownloadBatchProvenance(preset: .more, windowKind: .more, positionCount: 0, customPresetId: nil).isConsistent)
        #expect(!DownloadBatchProvenance(preset: .more, windowKind: .more, positionCount: 1001, customPresetId: nil).isConsistent)
    }

    @Test func storedRowsValidateStrictlyOnRead() throws {
        let id = UUID()
        let good = DownloadPresetDefinitionRecord(
            id: id.uuidString, name: "Name", windowKind: "more", positionCount: 3, sortIndex: 0
        )
        #expect(try good.validated().rule == .more(try #require(DownloadPositionCount(3))))

        let lowercaseID = DownloadPresetDefinitionRecord(
            id: id.uuidString.lowercased(), name: nil, windowKind: "next", positionCount: 3, sortIndex: 0
        )
        #expect(throws: CustomDownloadPresetError.invalidRecord) { try lowercaseID.validated() }

        let paddedName = DownloadPresetDefinitionRecord(
            id: id.uuidString, name: " Name", windowKind: "next", positionCount: 3, sortIndex: 0
        )
        #expect(throws: CustomDownloadPresetError.invalidRecord) { try paddedName.validated() }

        let unknownKind = DownloadPresetDefinitionRecord(
            id: id.uuidString, name: nil, windowKind: "unread", positionCount: 3, sortIndex: 0
        )
        #expect(throws: CustomDownloadPresetError.invalidRecord) { try unknownKind.validated() }
    }
}
