import CryptoKit
import Foundation

nonisolated enum OfflinePageKind: String, Codable, CaseIterable, Sendable {
    case image
    case text
}

/// One stored page. The file name is host-generated (`p0000.webp`), so nothing here derives from
/// plugin keys, URLs or titles.
nonisolated struct OfflineManifestPage: Codable, Equatable, Sendable {
    let index: Int
    /// The plugin's `Page.index`, kept for diagnostics only.
    let sourceIndex: Int32
    let kind: OfflinePageKind
    let file: String
    let mediaType: String
    let byteCount: Int64
    let sha256: String
    let description: String?
}

nonisolated enum OfflineManifestError: Error, Equatable, Sendable {
    case unsupportedFormat
    case versionMismatch
    case identityMismatch
    case emptyPages
    case indexNotDense
    case invalidFileName
    case duplicateFileName
    case pageKindMismatch
    case invalidDigest
    case byteCountMismatch
    case contentKindMismatch
}

/// Immutable description of one published version (`versions/<id>/manifest.json`).
///
/// The schema has no fields for URLs, headers, cookies or signed locators, so a manifest cannot
/// carry request material even when the source supplied it.
nonisolated struct OfflineChapterManifest: Codable, Equatable, Sendable {
    static let format = "ito.offline-chapter"
    static let currentFormatVersion = 1
    static let fileName = "manifest.json"

    let format: String
    let formatVersion: Int
    let versionId: String
    let identity: OfflineChapterEdition
    let contentKind: OfflineContentKind
    let createdAt: Date
    let totalBytes: Int64
    let pages: [OfflineManifestPage]

    init(
        versionId: String,
        identity: OfflineChapterEdition,
        createdAt: Date,
        pages: [OfflineManifestPage]
    ) {
        self.format = Self.format
        self.formatVersion = Self.currentFormatVersion
        self.versionId = versionId
        self.identity = identity
        self.contentKind = Self.contentKind(for: pages)
        self.createdAt = createdAt
        self.totalBytes = pages.reduce(Int64(0)) { $0 + $1.byteCount }
        self.pages = pages
    }

    static func contentKind(for pages: [OfflineManifestPage]) -> OfflineContentKind {
        let kinds = Set(pages.map(\.kind))
        if kinds == [.text] { return .text }
        if kinds == [.image] { return .images }
        return .mixed
    }

    /// Checks the manifest against the expected identity and version id before it is trusted.
    func validate(edition: OfflineChapterEdition, versionId expectedVersionId: String) throws {
        guard format == Self.format, formatVersion == Self.currentFormatVersion else {
            throw OfflineManifestError.unsupportedFormat
        }
        guard versionId == expectedVersionId else { throw OfflineManifestError.versionMismatch }
        guard identity == edition else { throw OfflineManifestError.identityMismatch }
        guard !pages.isEmpty else { throw OfflineManifestError.emptyPages }

        var fileNames = Set<String>()
        var total: Int64 = 0
        for (position, page) in pages.enumerated() {
            guard page.index == position else { throw OfflineManifestError.indexNotDense }
            guard OfflinePageFileName.isValid(page.file) else { throw OfflineManifestError.invalidFileName }
            guard fileNames.insert(page.file).inserted else { throw OfflineManifestError.duplicateFileName }
            guard (page.kind == .text) == page.file.hasSuffix(".txt") else {
                throw OfflineManifestError.pageKindMismatch
            }
            guard OfflineDigest.isHexDigest(page.sha256) else { throw OfflineManifestError.invalidDigest }
            guard page.byteCount >= 0 else { throw OfflineManifestError.byteCountMismatch }
            total += page.byteCount
        }
        guard total == totalBytes else { throw OfflineManifestError.byteCountMismatch }
        guard Self.contentKind(for: pages) == contentKind else { throw OfflineManifestError.contentKindMismatch }
    }

    /// Sorted keys and ISO-8601 dates keep the encoding, and so its digest, stable.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> OfflineChapterManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OfflineChapterManifest.self, from: data)
    }
}

/// Host-generated page file names: `p` + 4 or 5 digits + `.` + a known extension.
nonisolated enum OfflinePageFileName {
    static let allowedExtensions: Set<String> = ["jpg", "png", "gif", "webp", "avif", "heic", "txt"]

    static func make(index: Int, fileExtension: String) -> String {
        let digits = String(index)
        return "p" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "." + fileExtension
    }

    static func isValid(_ name: String) -> Bool {
        guard name.first == "p", let dot = name.firstIndex(of: ".") else { return false }
        let digits = name[name.index(after: name.startIndex)..<dot]
        let fileExtension = String(name[name.index(after: dot)...])
        return (4...5).contains(digits.count)
            && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
            && allowedExtensions.contains(fileExtension)
    }
}

nonisolated struct OfflineStreamedFile: Sendable {
    let sha256: String
    let byteCount: Int64
    /// The first chunk, enough to recognise an image signature.
    let head: Data
}

nonisolated enum OfflineDigest {
    static let chunkSize = 1 << 20

    static func sha256Hex(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// Hashes a file from disk in 1 MiB chunks, so memory stays bounded by the chunk size.
    static func streamedFile(at url: URL, fileSystem: any OfflineFileSystem) throws -> OfflineStreamedFile {
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var head = Data()
        try fileSystem.forEachChunk(of: url, chunkSize: chunkSize) { chunk in
            if head.isEmpty { head = chunk }
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        return OfflineStreamedFile(sha256: hexString(hasher.finalize()), byteCount: byteCount, head: head)
    }

    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }

    private static func hexString<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
