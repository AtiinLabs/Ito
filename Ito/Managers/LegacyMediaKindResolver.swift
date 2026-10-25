import CryptoKit
import Foundation
import GRDB
import ito_runner

nonisolated public enum TaggedDatabaseValue: Codable, Equatable, Sendable {
    case null
    case integer(Int64)
    case float(Double)
    case text(String)
    case blob(String) // Base64 encoded

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .integer(let v):
            try container.encode("integer", forKey: .type)
            try container.encode(v, forKey: .value)
        case .float(let v):
            try container.encode("float", forKey: .type)
            try container.encode(v, forKey: .value)
        case .text(let v):
            try container.encode("text", forKey: .type)
            try container.encode(v, forKey: .value)
        case .blob(let v):
            try container.encode("blob", forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "null":
            self = .null
        case "integer":
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case "float":
            self = .float(try container.decode(Double.self, forKey: .value))
        case "text":
            self = .text(try container.decode(String.self, forKey: .value))
        case "blob":
            let encoded = try container.decode(String.self, forKey: .value)
            guard Data(base64Encoded: encoded) != nil else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid base64 blob")
            }
            self = .blob(encoded)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value type")
        }
    }
}

nonisolated public struct LegacyMediaKindResolver: Sendable {
    /// The tables whose rows v15 keys by kind, and whose kindless rows may be archived as `kindUnknown`.
    public static let kindScopedTables: Set<String> = [
        "readProgressKey", "readProgressNumber", "mediaReadProgress", "trackerLink", "updateBadge", "readingHistory"
    ]

    private struct EvidenceKey: Hashable {
        let pluginId: String
        let mediaId: String
    }

    private let libraryItemsById: [String: (pluginId: String, kind: MediaKind)]
    private let evidence: [EvidenceKey: Set<MediaKind>]
    private let declaredPluginKinds: [String: MediaKind]

    public init(db: Database) throws {
        var itemsById: [String: (pluginId: String, kind: MediaKind)] = [:]
        var gatheredEvidence: [EvidenceKey: Set<MediaKind>] = [:]
        var observedPluginKinds: [String: Set<MediaKind>] = [:]

        func addEvidence(pluginId: String, mediaId: String, kind: MediaKind) {
            guard !pluginId.isEmpty, !mediaId.isEmpty else { return }
            observedPluginKinds[pluginId, default: []].insert(kind)
            gatheredEvidence[EvidenceKey(pluginId: pluginId, mediaId: mediaId), default: []].insert(kind)
            let canonical = Self.canonicalize(id: mediaId, pluginId: pluginId)
            if canonical != mediaId, !canonical.isEmpty {
                gatheredEvidence[EvidenceKey(pluginId: pluginId, mediaId: canonical), default: []].insert(kind)
            }
        }

        // 1. Snapshot libraryItem if present
        if try db.tableExists("libraryItem") {
            let rows = try Row.fetchAll(db, sql: "SELECT id, pluginId, pluginType, isAnime FROM libraryItem")
            for row in rows {
                guard let id: String = Self.value(row, "id"),
                      let pluginId: String = Self.value(row, "pluginId") else { continue }
                let pluginType: String? = Self.value(row, "pluginType")
                let isAnime: Int = Self.value(row, "isAnime") ?? 0
                let kind: MediaKind = (pluginType.flatMap { MediaKind(rawValue: $0) }) ?? (isAnime != 0 ? .anime : .manga)
                itemsById[id] = (pluginId: pluginId, kind: kind)
                addEvidence(pluginId: pluginId, mediaId: id, kind: kind)
                let canonical = ImportedMediaIdentity.canonicalMediaId(itemId: id, pluginId: pluginId, mediaKind: kind)
                if canonical != id {
                    addEvidence(pluginId: pluginId, mediaId: canonical, kind: kind)
                }
            }
        }

        // 2. Snapshot sourceMapping if present
        if try db.tableExists("sourceMapping") {
            let rows = try Row.fetchAll(db, sql: "SELECT pluginId, pluginMediaKey, mediaType FROM sourceMapping")
            for row in rows {
                guard let pluginId: String = Self.value(row, "pluginId"),
                      let pluginMediaKey: String = Self.value(row, "pluginMediaKey"),
                      let mediaType: String = Self.value(row, "mediaType"),
                      let kind = MediaKind(rawValue: mediaType) else { continue }
                addEvidence(pluginId: pluginId, mediaId: pluginMediaKey, kind: kind)
            }
        }

        // 3. Snapshot pluginCompletionOutbox if present
        if try db.tableExists("pluginCompletionOutbox") {
            let rows = try Row.fetchAll(db, sql: "SELECT pluginId, canonicalMediaId, mediaKey, kind FROM pluginCompletionOutbox")
            for row in rows {
                guard let pluginId: String = Self.value(row, "pluginId"),
                      let kindStr: String = Self.value(row, "kind"),
                      let kind = MediaKind(rawValue: kindStr) else { continue }
                if let canonicalMediaId: String = Self.value(row, "canonicalMediaId") {
                    addEvidence(pluginId: pluginId, mediaId: canonicalMediaId, kind: kind)
                }
                if let mediaKey: String = Self.value(row, "mediaKey") {
                    addEvidence(pluginId: pluginId, mediaId: mediaKey, kind: kind)
                }
            }
        }

        self.libraryItemsById = itemsById
        self.evidence = gatheredEvidence
        // A declaration contradicted by the plugin's own recorded media (for example a plugin whose type changed
        // between versions) does not say which kind its other state was written as.
        self.declaredPluginKinds = try Self.declaredPluginKinds(in: db).filter { pluginId, kind in
            observedPluginKinds[pluginId, default: []].isSubset(of: [kind])
        }
    }

    /// The kind a plugin's state must have when nothing about the media itself says: the one kind the plugin
    /// declares, agreed with by everything recorded for it. Before kind-aware identity the app only ever handled a
    /// plugin as its declared type, so that declaration is exact for state written then.
    public func declaredKind(ofPlugin pluginID: String) -> MediaKind? {
        declaredPluginKinds[pluginID]
    }

    /// The one kind each plugin declares across every cached repository index. Plugins declaring several kinds,
    /// conflicting kinds across repositories, or an unknown kind are left out.
    private static func declaredPluginKinds(in db: Database) throws -> [String: MediaKind] {
        guard try db.tableExists("repository") else { return [:] }
        var declared: [String: Set<MediaKind>] = [:]
        var unusable: Set<String> = []
        let payloads = try Data.fetchAll(db, sql: "SELECT indexPayload FROM repository WHERE indexPayload IS NOT NULL")
        for payload in payloads {
            guard let index = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let packages = index["packages"] as? [[String: Any]] else { continue }
            for package in packages {
                guard let pluginId = package["id"] as? String, !pluginId.isEmpty else { continue }
                var names: [Any] = [package["type"] as Any]
                if let kinds = package["kinds"] { names.append(contentsOf: kinds as? [Any] ?? [kinds]) }
                for name in names {
                    if let raw = name as? String, let kind = MediaKind(rawValue: raw) {
                        declared[pluginId, default: []].insert(kind)
                    } else {
                        unusable.insert(pluginId)
                    }
                }
            }
        }
        return declared.reduce(into: [:]) { result, entry in
            guard !unusable.contains(entry.key), entry.value.count == 1, let kind = entry.value.first else { return }
            result[entry.key] = kind
        }
    }

    /// The column's value when present and of type `T`; nil for a missing column, NULL, or another type, where
    /// GRDB's `row[column] as T?` would trap on backup data.
    public static func value<T: DatabaseValueConvertible>(_ row: Row, _ column: String) -> T? {
        guard row.hasColumn(column) else { return nil }
        let databaseValue: DatabaseValue = row[column]
        return T.fromDatabaseValue(databaseValue)
    }

    public static func canonicalize(id: String, pluginId: String) -> String {
        let prefix1F = "\(pluginId)\u{1F}"
        if id.hasPrefix(prefix1F) {
            let remainder = id.dropFirst(prefix1F.count)
            if let idx = remainder.firstIndex(of: "\u{1F}") {
                return String(remainder[remainder.index(after: idx)...])
            }
        }
        let prefixUnder = "\(pluginId)_"
        if id.hasPrefix(prefixUnder) {
            return String(id.dropFirst(prefixUnder.count))
        }
        return id
    }

    public func resolve(pluginID: String, canonicalMediaID: String) -> MediaKind? {
        guard !pluginID.isEmpty, !canonicalMediaID.isEmpty else { return nil }
        let normalized = Self.canonicalize(id: canonicalMediaID, pluginId: pluginID)
        var kinds = Set<MediaKind>()
        if let exact = evidence[EvidenceKey(pluginId: pluginID, mediaId: canonicalMediaID)] {
            kinds.formUnion(exact)
        }
        if normalized != canonicalMediaID,
           let norm = evidence[EvidenceKey(pluginId: pluginID, mediaId: normalized)] {
            kinds.formUnion(norm)
        }
        if kinds.isEmpty { return declaredPluginKinds[pluginID] }
        return kinds.count == 1 ? kinds.first : nil
    }

    public func resolveHistory(_ row: Row) -> MediaKind? {
        if let raw: String = Self.value(row, "mediaKind"), let kind = MediaKind(rawValue: raw) {
            return kind
        }
        guard let pluginId: String = Self.value(row, "pluginId"), !pluginId.isEmpty else { return nil }
        if let libraryItemId: String = Self.value(row, "libraryItemId"),
           !libraryItemId.isEmpty,
           let item = libraryItemsById[libraryItemId],
           item.pluginId == pluginId {
            return item.kind
        }
        if let mediaKey: String = Self.value(row, "mediaKey"), !mediaKey.isEmpty {
            return resolve(pluginID: pluginId, canonicalMediaID: mediaKey)
        }
        return nil
    }

    public static func archiveRecord(
        table: String,
        row: Row,
        capturedAt: Date
    ) throws -> LegacyStateArchiveRecord {
        let columnNames = row.columnNames.sorted()
        var taggedFields: [String: TaggedDatabaseValue] = [:]
        for column in columnNames {
            let dbValue: DatabaseValue = row[column]
            let tagged: TaggedDatabaseValue
            switch dbValue.storage {
            case .null:
                tagged = .null
            case .int64(let v):
                tagged = .integer(v)
            case .double(let v):
                tagged = .float(v)
            case .string(let v):
                tagged = .text(v)
            case .blob(let v):
                tagged = .blob(v.base64EncodedString())
            }
            taggedFields[column] = tagged
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(taggedFields)
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let sourceKey: String
        if table == "readingHistory", let id: String = value(row, "id"), !id.isEmpty {
            sourceKey = id
        } else if row.hasColumn("pluginId"), row.hasColumn("canonicalMediaId") {
            let pId: String = value(row, "pluginId") ?? ""
            let cId: String = value(row, "canonicalMediaId") ?? ""
            if table == "readProgressKey", row.hasColumn("chapterKey") {
                let ch: String = value(row, "chapterKey") ?? ""
                sourceKey = "\(pId)/\(cId)/\(ch)"
            } else if table == "readProgressNumber", row.hasColumn("chapterNumber") {
                let num: String = (value(row, "chapterNumber") as Double?).map { String($0) } ?? ""
                sourceKey = "\(pId)/\(cId)/\(num)"
            } else if table == "trackerLink", row.hasColumn("providerId") {
                let prov: String = value(row, "providerId") ?? ""
                sourceKey = "\(pId)/\(cId)/\(prov)"
            } else {
                sourceKey = "\(pId)/\(cId)"
            }
        } else if let id: String = value(row, "id"), !id.isEmpty {
            sourceKey = id
        } else {
            let components = columnNames.compactMap { col -> String? in
                let dbVal: DatabaseValue = row[col]
                if dbVal.isNull { return nil }
                return "\(col)=\(dbVal)"
            }
            sourceKey = components.isEmpty ? fingerprint : components.joined(separator: ";")
        }

        return LegacyStateArchiveRecord(
            id: nil,
            sourceDomain: table,
            sourceKey: sourceKey,
            contentClass: .appNonSecret,
            valueType: "databaseRow",
            valuePayload: payload,
            fingerprint: fingerprint,
            reason: "kindUnknown",
            createdAt: capturedAt
        )
    }

    public static func decodeFields(from archive: LegacyStateArchiveRecord) throws -> [String: TaggedDatabaseValue] {
        try JSONDecoder().decode([String: TaggedDatabaseValue].self, from: archive.valuePayload)
    }
}
