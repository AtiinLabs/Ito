import Foundation

/// The semantics of an ID-less descriptor. Untagged legacy descriptors retain name intent.
nonisolated enum ScanlatorRefBinding: String, Codable, Hashable, Sendable {
    case legacyName
    case exactIDless
}

/// A source group descriptor. Bound IDs exclude the cached display name from identity.
nonisolated struct ScanlatorRef: Codable, Hashable, Sendable {
    var id: String?
    var name: String?
    var binding: ScanlatorRefBinding?

    init(id: String? = nil, name: String? = nil, binding: ScanlatorRefBinding? = nil) {
        self.id = id
        self.name = name
        self.binding = binding
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.id, rhs.id) {
        case let (left?, right?): left.utf8.elementsEqual(right.utf8)
        case (nil, nil):
            effectiveBinding(lhs.binding) == effectiveBinding(rhs.binding)
                && optionalNameEquals(lhs.name, rhs.name)
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        if let id {
            hasher.combine(1)
            Self.hashUTF8(id, into: &hasher)
        } else {
            hasher.combine(0)
            hasher.combine(Self.effectiveBinding(binding))
            if let name {
                hasher.combine(1)
                Self.hashUTF8(name, into: &hasher)
            } else {
                hasher.combine(0)
            }
        }
    }

    private static func effectiveBinding(_ binding: ScanlatorRefBinding?) -> ScanlatorRefBinding {
        binding ?? .legacyName
    }

    private static func optionalNameEquals(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    private static func hashUTF8(_ value: String, into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
    }

    private enum CodingKeys: String, CodingKey { case id, name, binding }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        binding = try container.decodeIfPresent(ScanlatorRefBinding.self, forKey: .binding)
        guard id == nil || binding == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .binding,
                in: container,
                debugDescription: "A bound scanlator ID cannot have an ID-less binding."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        guard id == nil || binding == nil else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "A bound scanlator ID cannot have an ID-less binding.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(binding, forKey: .binding)
    }
}

nonisolated struct ScanlatorUTF8: Hashable, Sendable {
    let value: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
    }
}

nonisolated struct ScanlatorNameKey: Hashable, Sendable {
    let value: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil): true
        case let (left?, right?): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        if let value {
            hasher.combine(1)
            for byte in value.utf8 { hasher.combine(byte) }
        } else {
            hasher.combine(0)
        }
    }
}

nonisolated enum ScanlatorGroupKey: Hashable, Sendable {
    case id(ScanlatorUTF8)
    case idless(ScanlatorNameKey)

    init(id: String?, name: String?) {
        if let id {
            self = .id(ScanlatorUTF8(value: id))
        } else {
            self = .idless(ScanlatorNameKey(value: name))
        }
    }
}

nonisolated struct ResolvedEditionSelection: Sendable {
    let selection: EditionSelection
    /// Each selected group's place in the user's order; nil when every group is admitted.
    fileprivate let groupRanks: [ScanlatorGroupKey: Int]?

    func admits(scanlator name: String?, groupID: String?) -> Bool {
        rank(scanlator: name, groupID: groupID) != nil
    }

    /// The place of a group in the user's selected order, or nil when the selection does not admit it.
    /// An unrestricted selection ranks every group equally, so source order decides.
    func rank(scanlator name: String?, groupID: String?) -> Int? {
        guard let groupRanks else { return 0 }
        return groupRanks[ScanlatorGroupKey(id: groupID, name: name)]
    }
}

/// The groups a strict selection resolved to, remembering the order each was first selected in.
nonisolated private struct SelectedGroupRanks {
    private(set) var ranks: [ScanlatorGroupKey: Int] = [:]

    mutating func insert(_ key: ScanlatorGroupKey) {
        if ranks[key] == nil { ranks[key] = ranks.count }
    }
}

/// One catalog-local identity index shared by the planner, chooser preflight and offline coverage.
nonisolated struct ScanlatorCatalogIndex: Sendable {
    private struct NameGroups: Sendable {
        var firstID: ScanlatorUTF8?
        var hasMultipleIDs = false
        var hasIDless = false
    }

    private let groupKeys: Set<ScanlatorGroupKey>
    private let groupsByID: [ScanlatorUTF8: ScanlatorRef]
    private let groupsByName: [ScanlatorNameKey: NameGroups]

    init(_ catalog: [ScanlatorRef]) {
        self.init(catalog, id: { $0.id }, name: { $0.name })
    }

    init<C: Sequence>(
        _ catalog: C,
        id: (C.Element) -> String?,
        name: (C.Element) -> String?
    ) {
        var groupKeys = Set<ScanlatorGroupKey>()
        var groupsByID: [ScanlatorUTF8: ScanlatorRef] = [:]
        var groupsByName: [ScanlatorNameKey: NameGroups] = [:]
        for row in catalog {
            let id = id(row)
            let name = name(row)
            groupKeys.insert(ScanlatorGroupKey(id: id, name: name))
            let nameKey = ScanlatorNameKey(value: name)
            var nameGroups = groupsByName[nameKey, default: NameGroups()]
            if let id {
                let exactID = ScanlatorUTF8(value: id)
                if let firstID = nameGroups.firstID, firstID != exactID {
                    nameGroups.hasMultipleIDs = true
                } else {
                    nameGroups.firstID = exactID
                }
                groupsByID[exactID] = ScanlatorRef(id: id, name: name)
            } else {
                nameGroups.hasIDless = true
            }
            groupsByName[nameKey] = nameGroups
        }
        self.groupKeys = groupKeys
        self.groupsByID = groupsByID
        self.groupsByName = groupsByName
    }

    func resolve(_ selection: EditionSelection) -> ResolvedEditionSelection? {
        switch selection {
        case .sourceList, .allUploads:
            return ResolvedEditionSelection(selection: selection, groupRanks: nil)
        case .scanlators(let references):
            var resolvedReferences: [ScanlatorRef] = []
            var selectedGroups = SelectedGroupRanks()
            for reference in references {
                if let id = reference.id {
                    let exactID = ScanlatorUTF8(value: id)
                    guard let current = groupsByID[exactID] else { return nil }
                    resolvedReferences.append(current)
                    selectedGroups.insert(.id(exactID))
                    continue
                }

                let nameKey = ScanlatorNameKey(value: reference.name)
                guard let nameGroups = groupsByName[nameKey] else { return nil }
                if reference.binding == .exactIDless {
                    let groupKey = ScanlatorGroupKey.idless(nameKey)
                    guard groupKeys.contains(groupKey) else { return nil }
                    resolvedReferences.append(reference)
                    selectedGroups.insert(groupKey)
                    continue
                }

                if reference.name == nil {
                    guard nameGroups.hasIDless else { return nil }
                    let groupKey = ScanlatorGroupKey.idless(nameKey)
                    resolvedReferences.append(ScanlatorRef(name: nil, binding: .exactIDless))
                    selectedGroups.insert(groupKey)
                    continue
                }

                guard !nameGroups.hasMultipleIDs,
                      !(nameGroups.hasIDless && nameGroups.firstID != nil) else { return nil }
                if let uniqueID = nameGroups.firstID {
                    guard let current = groupsByID[uniqueID] else { return nil }
                    resolvedReferences.append(current)
                    selectedGroups.insert(.id(uniqueID))
                } else if nameGroups.hasIDless {
                    let groupKey = ScanlatorGroupKey.idless(nameKey)
                    resolvedReferences.append(ScanlatorRef(name: reference.name, binding: .exactIDless))
                    selectedGroups.insert(groupKey)
                } else {
                    return nil
                }
            }
            return ResolvedEditionSelection(
                selection: .scanlators(resolvedReferences), groupRanks: selectedGroups.ranks
            )
        }
    }
}

nonisolated enum EditionSelection: Hashable, Sendable {
    case sourceList
    case scanlators([ScanlatorRef])
    case allUploads

    func resolve(in catalog: [ScanlatorRef]) -> ResolvedEditionSelection? {
        switch self {
        case .sourceList, .allUploads:
            return ResolvedEditionSelection(selection: self, groupRanks: nil)
        case .scanlators:
            return ScanlatorCatalogIndex(catalog).resolve(self)
        }
    }

    func resolved(in catalog: [ScanlatorRef]) -> Self? {
        resolve(in: catalog)?.selection
    }
}

nonisolated extension EditionSelection: Codable {
    static let formatVersion = 2

    func storageData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, kind, scanlators }
    private enum Kind: String { case sourceList, scanlators, allUploads }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == 1 || version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: container, debugDescription: "Unsupported edition selection format version \(version).")
        }
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown edition selection kind \(rawKind).")
        }
        switch kind {
        case .sourceList: self = .sourceList
        case .allUploads: self = .allUploads
        case .scanlators:
            let references = try container.decode([ScanlatorRef].self, forKey: .scanlators)
            guard version != 1 || references.allSatisfy({ $0.binding != .exactIDless }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .scanlators, in: container, debugDescription: "Version 1 cannot contain explicit ID-less bindings."
                )
            }
            self = .scanlators(references)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .formatVersion)
        switch self {
        case .sourceList: try container.encode(Kind.sourceList.rawValue, forKey: .kind)
        case .allUploads: try container.encode(Kind.allUploads.rawValue, forKey: .kind)
        case .scanlators(let references):
            try container.encode(Kind.scanlators.rawValue, forKey: .kind)
            try container.encode(references, forKey: .scanlators)
        }
    }
}
