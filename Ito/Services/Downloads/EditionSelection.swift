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
        if case .preferred(let primary, .anyAvailable) = selection {
            return ScanlatorGroupKey(id: primary.id, name: primary.name)
                == ScanlatorGroupKey(id: groupID, name: name) ? 0 : 1
        }
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

    /// Missing bound IDs retain their identity. An ID-less same-label replacement needs review.
    private func preferredReference(_ reference: ScanlatorRef) -> ScanlatorRef? {
        if let resolved = resolve(.scanlators([reference])),
           case .scanlators(let refs) = resolved.selection { return refs.first }
        if reference.binding == .exactIDless,
           groupsByName[ScanlatorNameKey(value: reference.name)] == nil { return reference }
        guard reference.id != nil,
              groupsByName[ScanlatorNameKey(value: reference.name)]?.hasIDless != true else { return nil }
        return reference
    }

    func resolve(_ selection: EditionSelection) -> ResolvedEditionSelection? {
        switch selection {
        case .sourceList, .allUploads:
            return ResolvedEditionSelection(selection: selection, groupRanks: nil)
        case .preferred(let primary, let fallback):
            guard let primary = preferredReference(primary) else { return nil }
            var references = [primary]
            var resolvedFallback = fallback
            if case .approved(let approved) = fallback {
                var seen: Set<ScanlatorRef> = [primary]
                var resolved: [ScanlatorRef] = []
                for reference in approved {
                    guard let current = preferredReference(reference), seen.insert(current).inserted else { return nil }
                    resolved.append(current)
                }
                references += resolved
                resolvedFallback = .approved(resolved)
            }
            var ranks = SelectedGroupRanks()
            for reference in references {
                ranks.insert(ScanlatorGroupKey(id: reference.id, name: reference.name))
            }
            return ResolvedEditionSelection(
                selection: .preferred(primary: primary, fallback: resolvedFallback),
                groupRanks: fallback == .anyAvailable ? nil : ranks.ranks
            )
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

nonisolated enum EditionFallback: Hashable, Sendable {
    case strict
    case ask
    case approved([ScanlatorRef])
    case anyAvailable
}

nonisolated enum EditionSelection: Hashable, Sendable {
    case sourceList
    case scanlators([ScanlatorRef])
    case allUploads
    case preferred(primary: ScanlatorRef, fallback: EditionFallback)

    var references: [ScanlatorRef] {
        switch self {
        case .sourceList, .allUploads: return []
        case .scanlators(let refs): return refs
        case .preferred(let primary, let fallback):
            if case .approved(let refs) = fallback { return [primary] + refs }
            return [primary]
        }
    }

    var asksBeforeSwitching: Bool {
        if case .preferred(_, .ask) = self { return true }
        return false
    }

    func resolve(in catalog: [ScanlatorRef]) -> ResolvedEditionSelection? {
        switch self {
        case .sourceList, .allUploads:
            return ResolvedEditionSelection(selection: self, groupRanks: nil)
        case .scanlators, .preferred:
            return ScanlatorCatalogIndex(catalog).resolve(self)
        }
    }

    func resolved(in catalog: [ScanlatorRef]) -> Self? {
        resolve(in: catalog)?.selection
    }
}

nonisolated extension EditionSelection: Codable {
    /// The newest format this build reads. Format 1 and 2 decode exactly as shipped. Only the primary/fallback
    /// policy needs format 3; every earlier kind keeps writing format 2 so older builds still read it.
    static let formatVersion = 3
    private static let legacyWriteVersion = 2

    func storageData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, kind, scanlators, primary, fallback, approved }
    private enum Kind: String { case sourceList, scanlators, allUploads, preferred }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.formatVersion).contains(version) else {
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
        case .preferred:
            guard version == Self.formatVersion else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Preferred policy requires format 3.")
            }
            let primary = try container.decode(ScanlatorRef.self, forKey: .primary)
            let mode = try container.decode(String.self, forKey: .fallback)
            let fallback: EditionFallback
            switch mode {
            case "strict": fallback = .strict
            case "ask": fallback = .ask
            case "anyAvailable": fallback = .anyAvailable
            case "approved":
                let refs = try container.decode([ScanlatorRef].self, forKey: .approved)
                guard !refs.contains(primary), Set(refs).count == refs.count else {
                    throw DecodingError.dataCorruptedError(forKey: .approved, in: container, debugDescription: "Duplicate approved groups.")
                }
                fallback = .approved(refs)
            default:
                throw DecodingError.dataCorruptedError(forKey: .fallback, in: container, debugDescription: "Unknown fallback mode.")
            }
            self = .preferred(primary: primary, fallback: fallback)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let writtenVersion: Int
        if case .preferred = self { writtenVersion = Self.formatVersion } else { writtenVersion = Self.legacyWriteVersion }
        try container.encode(writtenVersion, forKey: .formatVersion)
        switch self {
        case .sourceList: try container.encode(Kind.sourceList.rawValue, forKey: .kind)
        case .allUploads: try container.encode(Kind.allUploads.rawValue, forKey: .kind)
        case .scanlators(let references):
            try container.encode(Kind.scanlators.rawValue, forKey: .kind)
            try container.encode(references, forKey: .scanlators)
        case .preferred(let primary, let fallback):
            try container.encode(Kind.preferred.rawValue, forKey: .kind)
            try container.encode(primary, forKey: .primary)
            let mode: String
            switch fallback {
            case .strict: mode = "strict"
            case .ask: mode = "ask"
            case .anyAvailable: mode = "anyAvailable"
            case .approved(let refs):
                guard !refs.contains(primary), Set(refs).count == refs.count else {
                    throw EncodingError.invalidValue(refs, .init(codingPath: encoder.codingPath, debugDescription: "Duplicate approved groups."))
                }
                mode = "approved"
                try container.encode(refs, forKey: .approved)
            }
            try container.encode(mode, forKey: .fallback)
        }
    }
}
