import Foundation
import GRDB

/// How many reading positions a window selects: 1 to 1000.
nonisolated struct DownloadPositionCount: Hashable, Sendable {
    static let range = 1...1000

    let value: Int

    /// nil outside `range`.
    init?(_ value: Int) {
        guard Self.range.contains(value) else { return nil }
        self.value = value
    }

    private init(validated value: Int) {
        self.value = value
    }

    /// The fixed count of a built-in preset. Only the built-in presets call this, with constants in `range`.
    static func builtIn(_ value: Int) -> DownloadPositionCount {
        precondition(range.contains(value), "Built-in download counts stay within the custom range")
        return DownloadPositionCount(validated: value)
    }
}

/// What a custom preset downloads. Unread and All are built-in only (owner decision D1).
nonisolated enum CustomDownloadRule: Hashable, Sendable {
    /// Like Next N: covered, damaged and missing positions count toward N.
    case next(DownloadPositionCount)
    /// N positions that get newly queued rows after the last read one. Covered positions do not count.
    case more(DownloadPositionCount)

    var windowKind: DownloadWindowKind {
        switch self {
        case .next: .next
        case .more: .more
        }
    }

    var positionCount: DownloadPositionCount {
        switch self {
        case .next(let count), .more(let count): count
        }
    }
}

/// A user-chosen name for a custom preset. Stored exactly as accepted: no Unicode normalization, never
/// translated, never logged.
nonisolated struct CustomPresetName: Hashable, Sendable {
    static let maximumCharacters = 40
    static let maximumUTF8Bytes = 256

    let value: String

    /// Trims leading and trailing whitespace. Rejects a name that is empty after trimming, one with a control,
    /// line or paragraph separator scalar (general categories Cc, Zl and Zp), one longer than 40 characters, and
    /// one longer than 256 UTF-8 bytes.
    init?(validating raw: String) {
        var trimmed = Substring(raw)
        while let first = trimmed.first, first.isWhitespace { trimmed.removeFirst() }
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let rejectedCategories: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        for scalar in trimmed.unicodeScalars where rejectedCategories.contains(scalar.properties.generalCategory) {
            return nil
        }
        guard trimmed.count <= Self.maximumCharacters, trimmed.utf8.count <= Self.maximumUTF8Bytes else { return nil }
        value = String(trimmed)
    }
}

nonisolated struct CustomDownloadPreset: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: CustomPresetName?
    let rule: CustomDownloadRule
}

/// Why a stored custom preset row was not accepted.
nonisolated enum CustomDownloadPresetError: Error, Equatable, Sendable {
    /// A stored row is not a definition this build can read.
    case invalidRecord
}

/// One row of `downloadPresetDefinition`. Writes and reads use the same strict validator
/// (`validated()`), and restore and export use it too; it is never relaxed on the read path.
public nonisolated struct DownloadPresetDefinitionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "downloadPresetDefinition"
    /// At most this many definitions exist.
    public static let maximumCount = 20

    public var id: String
    public var name: String?
    public var windowKind: String
    public var positionCount: Int
    public var sortIndex: Int

    public init(id: String, name: String?, windowKind: String, positionCount: Int, sortIndex: Int) {
        self.id = id
        self.name = name
        self.windowKind = windowKind
        self.positionCount = positionCount
        self.sortIndex = sortIndex
    }

    init(_ preset: CustomDownloadPreset, sortIndex: Int) {
        self.init(
            id: preset.id.uuidString,
            name: preset.name?.value,
            windowKind: preset.rule.windowKind.rawValue,
            positionCount: preset.rule.positionCount.value,
            sortIndex: sortIndex
        )
    }

    /// The definition this row holds. Throws `invalidRecord` for anything the validator refuses: a non-canonical
    /// id, a name that is not accepted exactly as stored, an unknown window kind, or a count out of range.
    func validated() throws -> CustomDownloadPreset {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else {
            throw CustomDownloadPresetError.invalidRecord
        }
        let name: CustomPresetName?
        if let stored = self.name {
            guard let accepted = CustomPresetName(validating: stored), accepted.value == stored else {
                throw CustomDownloadPresetError.invalidRecord
            }
            name = accepted
        } else {
            name = nil
        }
        guard let count = DownloadPositionCount(positionCount) else {
            throw CustomDownloadPresetError.invalidRecord
        }
        let rule: CustomDownloadRule
        switch windowKind {
        case DownloadWindowKind.next.rawValue: rule = .next(count)
        case DownloadWindowKind.more.rawValue: rule = .more(count)
        default: throw CustomDownloadPresetError.invalidRecord
        }
        return CustomDownloadPreset(id: uuid, name: name, rule: rule)
    }
}
