import Foundation
import GRDB
import ito_runner

/// The part of an automatic download rule that a backup carries: which series, and what the user chose for it. Ids,
/// generations, tickets, attempts, baselines, events, owners, grants and source epochs never travel: a restored rule is
/// a new paused rule that has to be reviewed and then learns its own catalog.
///
/// It is read from a backup by column name, not through `SeriesSubscriptionRecord`, so a backup stays readable when the
/// local record grows or loses columns.
nonisolated public struct PortableSubscriptionRule: Sendable, Equatable {
    /// The most rules a backup may carry; also the bound the importer checks in SQL before loading any row.
    static let maximumCount = 10_000
    /// The largest stored `EditionSelection` a backup may carry, in bytes.
    static let maximumSelectionByteCount = 65_536
    /// The most stored selection bytes all rules of one backup may carry together; checked in SQL before any row
    /// loads, on import and on export.
    static let maximumTotalSelectionByteCount = 16 * 1_024 * 1_024

    static let columnNames = [
        "pluginId", "mediaKind", "canonicalMediaId", "mode", "windowSize", "perRunPositionCap", "selection",
        "replacementRule"
    ]

    let pluginId: String
    let mediaKind: MediaKind
    let canonicalMediaId: String
    let mode: SubscriptionMode
    let windowSize: Int?
    let perRunPositionCap: Int
    /// `EditionSelection.storageData()` as stored. A selection this build cannot decode is carried as it is and
    /// skipped at restore, so an unknown future format is never read as another choice.
    let selection: Data
    let replacementRule: SubscriptionReplacementRule

    var media: MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: canonicalMediaId, mediaKind: mediaKind)
    }

    init(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String,
        mode: SubscriptionMode,
        windowSize: Int?,
        perRunPositionCap: Int,
        selection: Data,
        replacementRule: SubscriptionReplacementRule
    ) {
        self.pluginId = pluginId
        self.mediaKind = mediaKind
        self.canonicalMediaId = canonicalMediaId
        self.mode = mode
        self.windowSize = windowSize
        self.perRunPositionCap = perRunPositionCap
        self.selection = selection
        self.replacementRule = replacementRule
    }

    init(record: SeriesSubscriptionRecord) {
        self.init(
            pluginId: record.pluginId,
            mediaKind: record.mediaKind,
            canonicalMediaId: record.canonicalMediaId,
            mode: record.mode,
            windowSize: record.windowSize,
            perRunPositionCap: record.perRunPositionCap,
            selection: record.selection,
            replacementRule: record.replacementRule
        )
    }

    /// The user-chosen behaviour, or nil when the selection is not one this build reads.
    var configuration: SubscriptionConfiguration? {
        guard let selection = try? SeriesEditionPreferenceRecord.decodeSelection(selection) else { return nil }
        return SubscriptionConfiguration(
            mode: mode,
            windowSize: windowSize,
            perRunPositionCap: perRunPositionCap,
            selection: selection,
            replacementRule: replacementRule
        )
    }

    /// Whether the fixed parts of the rule are ones the database would accept. The selection is judged separately:
    /// an unreadable one is not invalid, only unusable.
    var isStructurallyValid: Bool {
        guard !pluginId.isEmpty, !canonicalMediaId.isEmpty,
              mediaKind == .manga || mediaKind == .novel,
              selection.count <= Self.maximumSelectionByteCount else { return false }
        return SubscriptionConfiguration(
            mode: mode, windowSize: windowSize, perRunPositionCap: perRunPositionCap, replacementRule: replacementRule
        ).isValid
    }

    /// Reads one row of a backup's rule table, or nil when any value is missing, mistyped or outside its closed list.
    init?(row: Row) {
        func text(_ column: String) -> String? { String.fromDatabaseValue(row[column] as DatabaseValue) }
        func integer(_ column: String) -> Int? {
            guard case .int64(let value) = (row[column] as DatabaseValue).storage else { return nil }
            return Int(exactly: value)
        }
        guard let pluginId = text("pluginId"),
              let kind = text("mediaKind").flatMap(MediaKind.init(rawValue:)),
              let canonicalMediaId = text("canonicalMediaId"),
              let mode = text("mode").flatMap(SubscriptionMode.init(rawValue:)),
              let perRunPositionCap = integer("perRunPositionCap"),
              case .blob(let selection) = (row["selection"] as DatabaseValue).storage,
              let replacementRule = text("replacementRule").flatMap(SubscriptionReplacementRule.init(rawValue:))
        else { return nil }
        let windowValue = row["windowSize"] as DatabaseValue
        let windowSize: Int?
        if windowValue.isNull {
            windowSize = nil
        } else if let value = integer("windowSize") {
            windowSize = value
        } else {
            return nil
        }
        self.init(
            pluginId: pluginId,
            mediaKind: kind,
            canonicalMediaId: canonicalMediaId,
            mode: mode,
            windowSize: windowSize,
            perRunPositionCap: perRunPositionCap,
            selection: selection,
            replacementRule: replacementRule
        )
    }
}
