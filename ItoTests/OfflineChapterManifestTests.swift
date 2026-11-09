import Foundation
import Testing
import ito_runner
@testable import Ito

struct OfflineChapterManifestTests {
    private static let edition = OfflineChapterEdition(
        pluginId: "plugin.test",
        mediaKind: .manga,
        canonicalMediaId: "series-1",
        chapterKey: "chapter-1"
    )
    private static let versionId = "11111111-2222-3333-4444-555555555555"

    private static func page(_ index: Int, kind: OfflinePageKind = .image, file: String? = nil) -> OfflineManifestPage {
        OfflineManifestPage(
            index: index,
            sourceIndex: Int32(index),
            kind: kind,
            file: file ?? OfflinePageFileName.make(index: index, fileExtension: kind == .text ? "txt" : "webp"),
            mediaType: kind == .text ? "text/plain; charset=utf-8" : "image/webp",
            byteCount: 10,
            sha256: String(repeating: "a", count: 64),
            description: nil
        )
    }

    private static func manifest(pages: [OfflineManifestPage]) -> OfflineChapterManifest {
        OfflineChapterManifest(
            versionId: versionId,
            identity: edition,
            createdAt: Date(timeIntervalSince1970: 0),
            pages: pages
        )
    }

    private static func allKeys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { [$0.key] + allKeys(in: $0.value) }
        }
        if let array = value as? [Any] {
            return array.flatMap { allKeys(in: $0) }
        }
        return []
    }

    @Test func manifestRoundTripsAndValidatesAgainstItsIdentity() throws {
        let original = Self.manifest(pages: [Self.page(0), Self.page(1)])
        let decoded = try OfflineChapterManifest.decode(try original.encoded())

        #expect(decoded == original)
        try decoded.validate(edition: Self.edition, versionId: Self.versionId)
        #expect(decoded.totalBytes == 20)
        #expect(decoded.contentKind == .images)
    }

    @Test func validationRejectsIdentityAndVersionMismatches() throws {
        let manifest = Self.manifest(pages: [Self.page(0)])
        let otherChapter = OfflineChapterEdition(
            pluginId: "plugin.test",
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: "chapter-2"
        )

        #expect(throws: OfflineManifestError.identityMismatch) {
            try manifest.validate(edition: otherChapter, versionId: Self.versionId)
        }
        #expect(throws: OfflineManifestError.versionMismatch) {
            try manifest.validate(edition: Self.edition, versionId: "other-version")
        }
    }

    @Test func validationRejectsGapsForeignFileNamesAndKindMismatches() throws {
        #expect(throws: OfflineManifestError.indexNotDense) {
            try Self.manifest(pages: [Self.page(0), Self.page(2)])
                .validate(edition: Self.edition, versionId: Self.versionId)
        }
        #expect(throws: OfflineManifestError.invalidFileName) {
            try Self.manifest(pages: [Self.page(0, file: "../p0000.webp")])
                .validate(edition: Self.edition, versionId: Self.versionId)
        }
        #expect(throws: OfflineManifestError.pageKindMismatch) {
            try Self.manifest(pages: [Self.page(0, kind: .text, file: "p0000.webp")])
                .validate(edition: Self.edition, versionId: Self.versionId)
        }
    }

    @Test func pageFileNamesAreHostGeneratedOnly() {
        #expect(OfflinePageFileName.make(index: 7, fileExtension: "jpg") == "p0007.jpg")
        #expect(OfflinePageFileName.isValid("p0000.webp"))
        #expect(OfflinePageFileName.isValid("p00001.txt"))
        #expect(!OfflinePageFileName.isValid("p000.webp"))
        #expect(!OfflinePageFileName.isValid("p0000.exe"))
        #expect(!OfflinePageFileName.isValid("../p0000.webp"))
        #expect(!OfflinePageFileName.isValid("image.webp"))
    }

    @Test func encodedManifestCarriesNoRequestMaterial() throws {
        let data = try Self.manifest(pages: [Self.page(0), Self.page(1, kind: .text)]).encoded()
        let keys = Self.allKeys(in: try JSONSerialization.jsonObject(with: data))
        let forbidden = ["url", "header", "cookie", "referer", "token", "signature", "authorization", "locator"]

        #expect(!keys.isEmpty)
        for key in keys {
            #expect(!forbidden.contains(where: { key.lowercased().contains($0) }), "Unexpected manifest key \(key)")
        }
    }

    @Test func streamedDigestMatchesTheInMemoryDigestAcrossChunks() throws {
        let fileSystem = FakeOfflineFileSystem()
        let directory = URL(fileURLWithPath: "/ito-offline-tests/digest", isDirectory: true)
        let file = directory.appendingPathComponent("page.bin")
        let payload = Data(repeating: 0x41, count: OfflineDigest.chunkSize + 17)
        try fileSystem.createDirectory(directory)
        try fileSystem.writeFile(payload, to: file)

        let streamed = try OfflineDigest.streamedFile(at: file, fileSystem: fileSystem)

        #expect(streamed.byteCount == Int64(payload.count))
        #expect(streamed.sha256 == OfflineDigest.sha256Hex(payload))
        #expect(streamed.head.count == OfflineDigest.chunkSize)
    }
}
