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

    /// The chooser this sheet shows; nil for any other sheet.
    var chooserID: UUID? {
        guard case .chooser(let presentation) = self else { return nil }
        return presentation.id
    }
}

/// One exact upload an explicit "Find All Uploads" listing found. The row holds only what the sheet shows;
/// the frozen chapter it queues stays with the model that listed it.
struct EnumeratedEditionRow: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    /// The source's group name for this upload, or nil for an upload that names none. Source content.
    let scanlator: String?
    /// For uploads that are already saved or queued: which of the two. Read from the live states.
    let stored: StoredEditionState
    /// A failed job still holds its upload; it is listed as failed, never as queued. Read from the live states.
    let isFailed: Bool
    /// The source marks the upload locked, so it can never be queued from here.
    let isLocked: Bool

    var id: String { key }
    /// A locked upload is blocked, and an upload that already has a copy or job needs nothing queued.
    var isSelectable: Bool { !isLocked && stored == .none }

    func with(stored: StoredEditionState, isFailed: Bool) -> EnumeratedEditionRow {
        EnumeratedEditionRow(
            key: key, title: title, scanlator: scanlator, stored: stored, isFailed: isFailed, isLocked: isLocked
        )
    }
}

/// The uploads the source declares to be one reading position, or one upload that declares none.
struct EnumeratedEditionGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let rows: [EnumeratedEditionRow]
}

/// What a listing does and does not claim, in the order the sheet says it. The sheet turns each line into
/// localized text; this type only decides which claims are true.
struct EditionEnumerationDisclosure: Equatable, Sendable {
    enum Line: Equatable, Sendable {
        /// The source reports the list covers every upload it offers for the account and settings in effect.
        case coversEveryUploadOffered
        /// Only what the source shows by default was listed, even if the source reports that part complete.
        case visibleUploadsOnly
        /// The source did not say which uploads the list covers.
        case scopeNotStated
        /// The source reports the list is incomplete.
        case someUploadsMayBeMissing
        /// The source did not say whether the list is complete.
        case completenessNotStated
        /// Ito stopped listing at its own cap on uploads, with this many listed. More may exist.
        case stoppedAtUploadLimit(Int)
        /// Ito stopped listing at its own cap on pages. More may exist.
        case stoppedAtPageLimit(Int)
        /// Ito stopped listing at its own cap on data. More may exist.
        case stoppedAtSizeLimit
    }

    let lines: [Line]

    /// `listedCount` is how many uploads the listing holds; a cap that stopped the traversal is reported with
    /// that number, never with the cap's own value, because a page that would pass the cap is left out whole.
    init(
        scope: CatalogScope,
        completeness: CatalogCompleteness,
        termination: ChapterEditionsResult.Termination,
        listedCount: Int
    ) {
        var lines: [Line] = []
        switch termination {
        case .bounded(.rows): lines.append(.stoppedAtUploadLimit(listedCount))
        case .bounded(.pages): lines.append(.stoppedAtPageLimit(ChapterEditionsLimits.maxPages))
        case .bounded(.bytes): lines.append(.stoppedAtSizeLimit)
        case .exhausted:
            switch completeness {
            case .complete:
                if scope == .allEligible { lines.append(.coversEveryUploadOffered) }
            case .partial: lines.append(.someUploadsMayBeMissing)
            case .unknown: lines.append(.completenessNotStated)
            }
        }
        // A bounded listing is never exhaustive, so its scope never turns it into a claim of coverage.
        switch scope {
        case .visible: lines.append(.visibleUploadsOnly)
        case .unknown: lines.append(.scopeNotStated)
        case .allEligible: break
        }
        self.lines = lines
    }
}

/// What an explicit listing found, grouped by reading position, with what it does and does not claim. Its
/// `id` names one listing: a refresh of the rows' saved and queued status keeps it, a new listing does not.
struct EditionEnumerationResult: Equatable, Sendable {
    let id: UUID
    /// Uploads the source listed in total.
    let totalCount: Int
    /// Listed uploads the series' current chapter list does not have; the groups hold these.
    let additionalCount: Int
    let groups: [EnumeratedEditionGroup]
    let disclosure: EditionEnumerationDisclosure

    init(
        id: UUID = UUID(),
        totalCount: Int,
        additionalCount: Int,
        groups: [EnumeratedEditionGroup],
        disclosure: EditionEnumerationDisclosure
    ) {
        self.id = id
        self.totalCount = totalCount
        self.additionalCount = additionalCount
        self.groups = groups
        self.disclosure = disclosure
    }

    /// The same listing with every row's saved, queued and failed status read again.
    func updatingStatus(_ status: (String) -> (stored: StoredEditionState, isFailed: Bool)) -> EditionEnumerationResult {
        EditionEnumerationResult(
            id: id,
            totalCount: totalCount,
            additionalCount: additionalCount,
            groups: groups.map { group in
                EnumeratedEditionGroup(
                    id: group.id,
                    title: group.title,
                    rows: group.rows.map { row in
                        let current = status(row.key)
                        return row.with(stored: current.stored, isFailed: current.isFailed)
                    }
                )
            },
            disclosure: disclosure
        )
    }
}

/// The explicit "Find All Uploads" action of the scanlator sheet. The listing belongs to that sheet alone.
enum EditionEnumerationState: Equatable {
    case idle
    case loading
    /// The source does not list uploads. The chapter list is unchanged.
    case unsupported
    /// The listing failed; no upload from it was kept. `message` is the user-facing reason.
    case failed(message: String)
    case loaded(EditionEnumerationResult)
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
