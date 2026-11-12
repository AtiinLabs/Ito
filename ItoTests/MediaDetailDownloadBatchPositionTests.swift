import XCTest
import ito_runner
@testable import Ito

/// The batch downloads over a catalog whose source declares logical units: one upload per position, saved
/// positions counting toward N, and a plan that never outlives the catalog it was made from.
extension MediaDetailDownloadBatchTests {
    private static let positionSeries = MediaIdentity(
        pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga
    )

    /// Groups A and B each upload positions `numbers`; B skips any listed in `without`. A1 and B1 share a unit.
    private static func overlapping(_ numbers: ClosedRange<Int>, bWithout: Set<Int> = []) -> [Chapter] {
        numbers.flatMap { number -> [Chapter] in
            var rows = [Chapter(key: "a\(number)", chapter: Double(number), scanlator: "A", logicalUnitID: "u\(number)")]
            if !bWithout.contains(number) {
                rows.append(Chapter(key: "b\(number)", chapter: Double(number), scanlator: "B", logicalUnitID: "u\(number)"))
            }
            return rows
        }
    }

    private static func choice(_ groups: String...) -> EditionSelection {
        .scanlators(groups.map { ScanlatorRef(name: $0, binding: .exactIDless) })
    }

    private static func previewSheet(of viewModel: MediaDetailViewModel<Manga>) -> DownloadPreview? {
        guard case .preview(let preview)? = viewModel.downloadSheet else { return nil }
        return preview
    }

    func testAllQueuesOneSelectedUploadPerLogicalUnitAndAllEditionsQueuesEvery() async throws {
        let subject = await makeSubject(chapters: Self.overlapping(1...3))

        await subject.viewModel.downloadBatch
            .applyEditionChoice(Self.choice("B", "A"), remember: false, then: .all).value

        XCTAssertEqual(subject.downloads.batchRequests.first?.chapters.map(\.key), ["b1", "b2", "b3"])

        let everything = await makeSubject(chapters: Self.overlapping(1...3))
        await everything.viewModel.downloadBatch
            .applyEditionChoice(.allUploads, remember: false, then: .all).value
        let preview = try XCTUnwrap(Self.previewSheet(of: everything.viewModel))
        XCTAssertEqual(Set(preview.toQueue.map(\.key)), ["a1", "a2", "a3", "b1", "b2", "b3"])
        await everything.viewModel.downloadBatch.confirmDownloadPreview().value
        XCTAssertEqual(everything.downloads.batchRequests.first?.chapters.count, 6)
    }

    func testNextFiveCountsPositionsSavedUnderAPermittedGroupAndTransfersOnlyTheMissingOne() async throws {
        let subject = await makeSubject(chapters: Self.overlapping(21...25, bWithout: [25]))
        for number in 21...24 { subject.downloads.set(.downloaded, chapterKey: "b\(number)") }

        await subject.viewModel.downloadBatch
            .applyEditionChoice(Self.choice("A", "B"), remember: false, then: .next5).value

        XCTAssertEqual(subject.downloads.batchRequests.first?.chapters.map(\.key), ["a25"])
        XCTAssertEqual(subject.messages.messages, [.downloadsQueued(queued: 1, alreadyStored: 4)])
    }

    func testAStrictGroupIsNotSatisfiedByASavedCopyFromAnotherGroup() async throws {
        let subject = await makeSubject(chapters: Self.overlapping(21...25))
        for number in 21...24 { subject.downloads.set(.downloaded, chapterKey: "b\(number)") }

        await subject.viewModel.downloadBatch
            .applyEditionChoice(Self.choice("A"), remember: false, then: .next5).value

        XCTAssertEqual(
            subject.downloads.batchRequests.first?.chapters.map(\.key),
            ["a21", "a22", "a23", "a24", "a25"]
        )
    }

    func testANumberThatRoundsToOneFloatKeepsBothUploadsWhileTheReadMarkerKeepsItsParity() async throws {
        let rows = [
            Chapter(key: "first", chapter: 16.0, logicalUnitID: "u1"),
            Chapter(key: "second", chapter: 16.000000001, logicalUnitID: "u2")
        ]
        XCTAssertEqual(Float(rows[0].chapter ?? 0), Float(rows[1].chapter ?? 1))

        let all = await makeSubject(chapters: rows)
        await all.viewModel.downloadBatch.startDownload(.all).value
        let preview = try XCTUnwrap(Self.previewSheet(of: all.viewModel))
        XCTAssertEqual(Set(preview.toQueue.map(\.key)), ["first", "second"])
        await all.viewModel.downloadBatch.confirmDownloadPreview().value
        XCTAssertEqual(Set(all.downloads.batchRequests.first?.chapters.map(\.key) ?? []), ["first", "second"])

        // The legacy number marker reads both, so Unread leaves both out; All still takes them.
        let unread = await makeSubject(chapters: rows)
        unread.progress.readChapterNumbers[Self.positionSeries] = [16]
        await unread.viewModel.downloadBatch.startDownload(.unread).value
        let skipped = try XCTUnwrap(Self.previewSheet(of: unread.viewModel))
        XCTAssertTrue(skipped.toQueue.isEmpty)
        XCTAssertEqual(skipped.skippedReadCount, 2)
        XCTAssertTrue(unread.downloads.batchRequests.isEmpty)
    }

    func testALogicalIDChangeBetweenPreviewAndConfirmQueuesNothingUntilTheNewPlanIsConfirmed() async throws {
        func catalog(sharing: Bool) -> [Chapter] {
            (1...12).map { number in
                Chapter(
                    key: "c\(number)", chapter: Double(number),
                    logicalUnitID: sharing && number <= 2 ? "shared" : nil
                )
            }
        }
        let subject = await makeSubject(chapters: catalog(sharing: false))
        await subject.viewModel.downloadBatch.startDownload(.all).value
        let before = try XCTUnwrap(Self.previewSheet(of: subject.viewModel))
        XCTAssertEqual(before.toQueue.count, 12)

        subject.catalog.chapters = catalog(sharing: true)
        await subject.viewModel.refresh()

        let after = try XCTUnwrap(Self.previewSheet(of: subject.viewModel))
        XCTAssertNotEqual(after.catalogDigest, before.catalogDigest, "The unit IDs are part of the catalog's digest")
        XCTAssertEqual(after.toQueue.count, 11)

        // The refresh already replaced the sheet with a plan for the new catalog, so the stale preview is
        // refused by its identity and nothing is queued from it.
        await subject.viewModel.downloadBatch.confirmDownloadPreview(previewID: before.id).value
        XCTAssertTrue(subject.downloads.batchRequests.isEmpty)

        await subject.viewModel.downloadBatch.confirmDownloadPreview(previewID: after.id).value
        let keys = try XCTUnwrap(subject.downloads.batchRequests.first).chapters.map(\.key)
        XCTAssertEqual(keys.count, 11)
        XCTAssertTrue(keys.contains("c1"))
        XCTAssertFalse(keys.contains("c2"), "One upload per position")
    }

    func testASourceReadingOrderOnlyOrdersWithinTheResponseItCameWith() async throws {
        func catalog(_ orders: [Int64]) -> [Chapter] {
            orders.enumerated().map { offset, order in
                Chapter(key: "c\(offset + 1)", chapter: Double(offset + 1), readingOrder: order)
            }
        }
        let subject = await makeSubject(chapters: catalog([1, 2, 3]))
        await subject.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertEqual(subject.downloads.batchRequests.last?.chapters.map(\.key), ["c1"])

        // The refreshed response numbers the same chapters the other way round; nothing carries over.
        subject.catalog.chapters = catalog([3, 2, 1])
        await subject.viewModel.refresh()
        await subject.viewModel.downloadBatch.startDownload(.next).value
        XCTAssertEqual(subject.downloads.batchRequests.last?.chapters.map(\.key), ["c3"])
        XCTAssertEqual(subject.downloads.batchRequests.count, 2)
    }
}
