import Foundation
import GRDB
import ito_runner

/// Frozen approval for replacing one exact installed version, never whichever copy exists later. Its job ends
/// with it: a replacement that ends as a failure has its intent removed.
nonisolated struct DownloadReplacementIntent: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "downloadReplacementIntent"
    var jobId: String
    var expectedVersionId: String
    var expectedRevision: String?
    var targetRevision: String?
    var sourceEpoch: String
    /// A per-confirmation UUID that records the manual decision. It is not a network grant.
    var authorizationId: String

    static func revision(_ chapter: Chapter) -> String? {
        guard let revision = chapter.revision, !revision.isEmpty else { return nil }
        return revision
    }
}

/// A confirmation freezes both the installed pointer and the source's exact target snapshot.
nonisolated struct DownloadReplacementRequest: Sendable {
    let download: DownloadEnqueueRequest
    let expectedVersionId: String
    let expectedRevision: String?
    let authorizationId: String
}

/// Why a saved copy cannot be offered for replacement right now.
nonisolated enum DownloadReplacementRefusal: Equatable, Sendable {
    /// The saved copy is kept, but its source settings changed after it was saved, or it was saved under another
    /// series. Deleting and downloading again is the way to get a current copy.
    case copyCannotBeReplaced
    /// Nothing can be replaced: no verified copy, a locked chapter, or the copy is damaged.
    case unavailable
}

/// What a replacement confirmation can start from: a frozen preview, or the reason none exists.
nonisolated enum DownloadReplacementAccess: Sendable {
    case preview(DownloadReplacementPreview)
    case refused(DownloadReplacementRefusal)

    var preview: DownloadReplacementPreview? {
        if case .preview(let preview) = self { return preview }
        return nil
    }

    var refusal: DownloadReplacementRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// Presentation freezes the exact installed copy and target, but grants no network authority.
nonisolated struct DownloadReplacementPreview: Identifiable, Sendable {
    let id = UUID()
    let download: DownloadEnqueueRequest
    let installed: Chapter
    let expectedVersionId: String

    var hasChangedRevision: Bool {
        guard let old = DownloadReplacementIntent.revision(installed),
              let target = DownloadReplacementIntent.revision(download.chapter) else { return false }
        return old != target
    }

    var title: String {
        hasChangedRevision
            ? String(localized: "Replace download", comment: "Manual replacement confirmation title")
            : String(localized: "Download again", comment: "Manual refresh; source revision is unchanged or unknown")
    }

    var message: String {
        let savedTitle = Self.displayTitle(installed)
        let newTitle = Self.displayTitle(download.chapter)
        let savedGroup = installed.scanlator ?? Self.unknownGroup
        let newGroup = download.chapter.scanlator ?? Self.unknownGroup
        let savedRevision = DownloadReplacementIntent.revision(installed) ?? Self.unknownRevision
        let newRevision = DownloadReplacementIntent.revision(download.chapter) ?? Self.unknownRevision
        return String(
            localized: "Saved copy: \(savedTitle), group \(savedGroup), revision \(savedRevision).\nNew copy: \(newTitle), group \(newGroup), revision \(newRevision).\nThe saved copy stays available until the new copy is verified. If a revision is unknown, this is a manual refresh, not evidence of newer content. Downloads wait on metered networks and in Low Data Mode.",
            comment: "Manual replacement confirmation. The chapter titles, group names and revisions are untranslated source data; each one is shown as its own value."
        )
    }

    /// The chapter's title, or its source key when the source gave no title.
    private static func displayTitle(_ chapter: Chapter) -> String {
        guard let title = chapter.title, !title.isEmpty else { return chapter.key }
        return title
    }

    private static var unknownRevision: String {
        String(localized: "Unknown revision", comment: "Replacement confirmation: the source does not provide a revision for this chapter")
    }

    private static var unknownGroup: String {
        String(localized: "Unknown group", comment: "Replacement confirmation: the source gave this chapter no scanlator group")
    }
}
