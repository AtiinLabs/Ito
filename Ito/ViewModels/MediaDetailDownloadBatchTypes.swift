import Foundation
import ito_runner

/// One scanlator the chooser offers, with the number of catalog rows it has.
struct ScanlatorOption: Identifiable, Hashable, Sendable {
    let ref: ScanlatorRef
    let chapterCount: Int

    var id: ScanlatorRef { ref }

    /// The name to show, or nil for a row whose source lists no group (or an empty name).
    var displayName: String? {
        guard let name = ref.name, !name.isEmpty else { return nil }
        return name
    }
}

/// What the scanlator chooser shows. `preset` is the download that asked for the choice, if one did.
struct EditionChooserPresentation: Equatable {
    let id = UUID()
    let identity: MediaIdentity
    let scopeGeneration: Int
    let catalogDigest: String
    var sourceEpoch = ""
    var policy: RememberedEditionChoice = .unknown
    let options: [ScanlatorOption]
    let initialSelection: EditionSelection
    /// Whether "Remember for this series" starts on. Only a choice made for a download can be left unremembered.
    let remember: Bool
    /// Whether the choice may be left unremembered. Without a download behind it, the choice has nothing else to
    /// apply to, so it is always remembered and the toggle is not shown.
    let offersRemember: Bool
    let preset: DownloadPreset?
    /// Why the stored choice is not shown, when it is not.
    let storedChoiceProblem: StoredChoiceProblem?
}

/// Why a series' remembered scanlator choice could not be used.
enum StoredChoiceProblem: Equatable {
    /// A choice is stored, but this build cannot read it; saving a new one replaces it.
    case unreadable
    /// Reading the store failed this time. Whatever is stored is untouched and may be fine.
    case readFailed
    case needsReview
}

/// One catalog row as the preview lists it.
struct DownloadPreviewRow: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let scanlator: String?
    /// For rows that are already saved or queued: which of the two.
    let stored: StoredEditionState
    /// A failed job still holds its position; it is listed as failed, never as queued.
    let isFailed: Bool

    var id: String { key }
}

/// What a preset would do, shown before anything is queued. It holds exact catalog keys: the chapters
/// themselves are read from the list at confirm, and only while the list is still the one this was made from.
struct DownloadPreview: Identifiable, Equatable {
    let id: UUID
    let preset: DownloadPreset
    let selection: EditionSelection
    let identity: MediaIdentity
    let scopeGeneration: Int
    /// The digest of the chapter list this was made from.
    let catalogDigest: String
    var sourceEpoch = ""
    var policy: RememberedEditionChoice = .unknown
    let toQueue: [DownloadPreviewRow]
    /// Positions already saved or queued; they count toward the preset's N.
    let satisfied: [DownloadPreviewRow]
    let damaged: [DownloadPreviewRow]
    let locked: [DownloadPreviewRow]
    /// Other uploads inside the preset's range, from any group: extra uploads of chosen positions and rows the
    /// selection does not supply. Never queued unless the user ticks them.
    let alternatives: [DownloadPreviewRow]
    let skippedReadCount: Int
    var missingPositionCount = 0
    let issues: Set<DownloadPlanIssue>
    /// The chapter list changed while the preview was open, so this replaced the one the user was reading.
    let listChanged: Bool

    var savedCount: Int { satisfied.filter { $0.stored == .verified }.count }
    var queuedCount: Int { satisfied.filter { $0.stored == .queued && !$0.isFailed }.count }
    var failedCount: Int { satisfied.filter(\.isFailed).count }
    /// The positions that are already saved or queued, which failed ones are not.
    var storedCount: Int { savedCount + queuedCount }
}

/// The one sheet the download controls present. Its content changes in place, so a choice followed by a
/// preview is one presentation, not a sheet dismissed and shown again.
enum DownloadSheet: Identifiable, Equatable {
    case chooser(EditionChooserPresentation)
    case preview(DownloadPreview)

    var id: String { "download" }
}

/// What the series has stored as its remembered scanlator choice.
enum RememberedEditionChoice: Equatable {
    /// Not asked for yet, or being read.
    case unknown
    /// Nothing was remembered.
    case none
    case chosen(EditionSelection)
    /// A choice is stored, but this build cannot read it. It is not "none": it is neither used nor
    /// overwritten without telling the user.
    case unreadable
}

nonisolated extension DownloadBatchPreset {
    /// The preset a stored batch records for a menu preset.
    init(_ preset: DownloadPreset) {
        switch preset {
        case .next: self = .next
        case .next5: self = .next5
        case .next10: self = .next10
        case .unread: self = .unread
        case .all: self = .all
        }
    }
}
