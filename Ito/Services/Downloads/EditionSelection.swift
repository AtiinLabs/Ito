import Foundation

/// A scanlator as the source shows it. `id` stays nil until the source reports group identifiers (ABI 3);
/// `name` is nil for "no group listed". The two sit side by side so a stored selection can later gain an
/// id without a schema change.
nonisolated struct ScanlatorRef: Codable, Hashable, Sendable {
    var id: String?
    var name: String?

    init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// Which uploads of a series a download request may select. It is a user-chosen filter: it never
/// identifies a stored edition, never dedupes, and never decides that a position is satisfied.
nonisolated enum EditionSelection: Hashable, Sendable {
    /// Follow the source's list: every row it returns (the default).
    case sourceList
    /// A strict set of scanlators. The order is the user's and is kept for ordered fallback later.
    case scanlators([ScanlatorRef])
    /// Every upload, including several translations of the same chapter (an explicit advanced action).
    case allUploads

    /// Whether a chapter from `name` (and, when the source reports one, group `groupID`) is selected.
    ///
    /// A reference matches by id when both sides carry one. Otherwise it matches by exact display name:
    /// no trimming and no case folding, so a renamed group stops matching rather than matching loosely.
    func admits(scanlator name: String?, groupID: String? = nil) -> Bool {
        switch self {
        case .sourceList, .allUploads:
            return true
        case .scanlators(let references):
            return references.contains { reference in
                if let referenceID = reference.id, let groupID {
                    return referenceID == groupID
                }
                return reference.name == name
            }
        }
    }
}

/// The stored form is versioned: `{"formatVersion":1,"kind":"scanlators","scanlators":[…]}`. An unknown
/// version or kind fails to decode instead of being read as something else.
nonisolated extension EditionSelection: Codable {
    static let formatVersion = 1

    /// The bytes a store persists for this selection. Keys are sorted, so equal selections always
    /// produce equal bytes; this is the only producer of the stored form.
    func storageData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, kind, scanlators
    }

    private enum Kind: String {
        case sourceList, scanlators, allUploads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported edition selection format version \(version)."
            )
        }
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown edition selection kind \(rawKind)."
            )
        }
        switch kind {
        case .sourceList:
            self = .sourceList
        case .allUploads:
            self = .allUploads
        case .scanlators:
            self = .scanlators(try container.decode([ScanlatorRef].self, forKey: .scanlators))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        switch self {
        case .sourceList:
            try container.encode(Kind.sourceList.rawValue, forKey: .kind)
        case .allUploads:
            try container.encode(Kind.allUploads.rawValue, forKey: .kind)
        case .scanlators(let references):
            try container.encode(Kind.scanlators.rawValue, forKey: .kind)
            try container.encode(references, forKey: .scanlators)
        }
    }
}
