import CoreFoundation
import CryptoKit
import Foundation
import GRDB
import ito_runner

// swiftlint:disable file_length

nonisolated public protocol LegacyDefaultsDomain: Sendable {
    var domainName: String { get }
    func persistentDomain() -> [String: Any]
    func removeObject(forKey key: String)
}

nonisolated public final class UserDefaultsLegacyDomain: LegacyDefaultsDomain, @unchecked Sendable {
    public let domainName: String
    private let defaults: UserDefaults

    public init(defaults: UserDefaults, domainName: String) {
        self.defaults = defaults
        self.domainName = domainName
    }

    public func persistentDomain() -> [String: Any] {
        defaults.persistentDomain(forName: domainName) ?? [:]
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public enum LegacyMigrationFaultPoint: String, CaseIterable, Sendable {
    case beforeDatabaseWrite
    case duringInboxTransaction
    case afterInboxCommitBeforeReadback
    case afterInboxReadbackBeforeRemoval
    case afterRemovalBeforeVerification
    case duringRemovalVerification
    case afterCleanupBeforeNormalization
    case duringNormalizationTransaction
    case afterNormalizationCommit
}

nonisolated public struct CanonicalPropertyListCapture: Equatable, Sendable {
    public let valueType: String
    public let payload: Data
    public let fingerprint: String

    public static func make(value: Any, normalizeSet: Bool = false) throws -> Self {
        if let data = value as? Data {
            return Self(valueType: "data", payload: data, fingerprint: digest(data))
        }

        let node = try CanonicalPropertyListCodec.node(from: value, normalizeSet: normalizeSet)
        let payload = try PropertyListSerialization.data(
            fromPropertyList: ["ito-canonical-plist-v1", node],
            format: .binary,
            options: 0
        )
        return Self(
            valueType: try CanonicalPropertyListCodec.typeName(of: node),
            payload: payload,
            fingerprint: digest(payload)
        )
    }

    public func decodedValue() throws -> Any {
        if valueType == "data" { return payload }
        let root = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        guard let envelope = root as? [Any], envelope.count == 2,
              envelope[0] as? String == "ito-canonical-plist-v1" else {
            throw LegacyDefaultsMigrationError.invalidCanonicalPayload
        }
        return try CanonicalPropertyListCodec.value(from: envelope[1])
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private enum CanonicalPropertyListCodec {
    static func node(from value: Any, normalizeSet: Bool) throws -> Any {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["bool", number.boolValue]
            }
            if isInteger(number) {
                return ["integer", number.stringValue]
            }
            let double = number.doubleValue
            let tag = double.isFinite ? "double" : "nonfiniteDouble"
            return [tag, floatingBytes(double)]
        }
        if let string = value as? String { return ["string", string] }
        if let date = value as? Date { return ["date", floatingBytes(date.timeIntervalSinceReferenceDate)] }
        if let data = value as? Data { return ["data", data] }
        if let array = value as? [Any] {
            return ["array", try array.map { try node(from: $0, normalizeSet: normalizeSet) }]
        }
        if let dictionary = value as? [String: Any] {
            let pairs = try dictionary.keys.sorted().map { key -> Any in
                [key, try node(from: dictionary[key]!, normalizeSet: normalizeSet)]
            }
            return ["dictionary", pairs]
        }
        if normalizeSet, let set = value as? NSSet {
            let nodes = try set.map { try node(from: $0, normalizeSet: true) }
            let sorted = try nodes.sorted {
                try encodedNode($0).lexicographicallyPrecedes(encodedNode($1))
            }
            return ["set", sorted]
        }
        throw LegacyDefaultsMigrationError.unsupportedPropertyListType(String(describing: type(of: value)))
    }

    static func typeName(of node: Any) throws -> String {
        guard let typeName = (node as? [Any])?.first as? String else {
            throw LegacyDefaultsMigrationError.invalidCanonicalPayload
        }
        return typeName
    }

    static func value(from rawNode: Any) throws -> Any {
        guard let node = rawNode as? [Any], node.count == 2, let tag = node[0] as? String else {
            throw LegacyDefaultsMigrationError.invalidCanonicalPayload
        }
        switch tag {
        case "bool":
            guard let value = node[1] as? Bool else { throw LegacyDefaultsMigrationError.invalidCanonicalPayload }
            return NSNumber(value: value)
        case "integer":
            guard let value = node[1] as? String, let integer = Int64(value) else {
                throw LegacyDefaultsMigrationError.invalidCanonicalPayload
            }
            return NSNumber(value: integer)
        case "double", "nonfiniteDouble":
            return NSNumber(value: try floatingValue(node[1]))
        case "string":
            guard let value = node[1] as? String else { throw LegacyDefaultsMigrationError.invalidCanonicalPayload }
            return value
        case "date":
            return Date(timeIntervalSinceReferenceDate: try floatingValue(node[1]))
        case "data":
            guard let value = node[1] as? Data else { throw LegacyDefaultsMigrationError.invalidCanonicalPayload }
            return value
        case "array", "set":
            guard let values = node[1] as? [Any] else { throw LegacyDefaultsMigrationError.invalidCanonicalPayload }
            return try values.map(value(from:))
        case "dictionary":
            guard let pairs = node[1] as? [Any] else { throw LegacyDefaultsMigrationError.invalidCanonicalPayload }
            return try Dictionary(uniqueKeysWithValues: pairs.map { rawPair in
                guard let pair = rawPair as? [Any], pair.count == 2, let key = pair[0] as? String else {
                    throw LegacyDefaultsMigrationError.invalidCanonicalPayload
                }
                return (key, try value(from: pair[1]))
            })
        default:
            throw LegacyDefaultsMigrationError.invalidCanonicalPayload
        }
    }

    private static func isInteger(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q": true
        default: false
        }
    }

    private static func floatingBytes(_ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }

    private static func floatingValue(_ value: Any) throws -> Double {
        guard let data = value as? Data, data.count == MemoryLayout<UInt64>.size else {
            throw LegacyDefaultsMigrationError.invalidCanonicalPayload
        }
        let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(bitPattern: bits)
    }

    private static func encodedNode(_ node: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: node, format: .binary, options: 0)
    }
}

public enum LegacyDefaultsMigrationError: Error, Equatable {
    case unsupportedPropertyListType(String)
    case invalidCanonicalPayload
    case canonicalReadbackFailed(domain: String, key: String)
    case persistentCleanupFailed(domain: String, key: String)
    case incompleteOutcomeCoverage(domain: String, key: String)
    case missingMigrationStatus(domain: String, key: String, fingerprint: String)
    case unknownMigrationStatus(domain: String, key: String, fingerprint: String, status: String)
    case legacyStateArchiveReadbackFailed(domain: String, key: String, fingerprint: String)
    case invalidStatusTransition(from: LegacyMigrationStatus, to: LegacyMigrationStatus)
}

public struct LegacyMigrationEvent: Equatable, Sendable {
    public let sourceDomain: String
    public let sourceKey: String
    public let outcome: String

    public init(sourceDomain: String, sourceKey: String, outcome: String) {
        self.sourceDomain = sourceDomain
        self.sourceKey = sourceKey
        self.outcome = outcome
    }
}

public final class LegacyDefaultsMigrator: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date
    public typealias FaultHandler = @Sendable (LegacyMigrationFaultPoint, LegacyDefaultsSourceTuple) throws -> Void
    public typealias EventObserver = @Sendable (LegacyMigrationEvent) -> Void

    private let dbPool: DatabasePool
    private let domain: any LegacyDefaultsDomain
    private let clock: Clock
    private let faultHandler: FaultHandler
    private let eventObserver: EventObserver

    public init(
        dbPool: DatabasePool,
        domain: any LegacyDefaultsDomain,
        clock: @escaping Clock = Date.init,
        faultHandler: @escaping FaultHandler = { _, _ in },
        eventObserver: @escaping EventObserver = { _ in }
    ) {
        self.dbPool = dbPool
        self.domain = domain
        self.clock = clock
        self.faultHandler = faultHandler
        self.eventObserver = eventObserver
    }

    public func migrate() throws {
        for source in StandardSource.orderedSources {
            try migrate(source)
        }
        try materializeMissingScalarDefaults()
    }

    private func migrate(_ source: StandardSource) throws {
        let tuple = LegacyDefaultsSourceTuple(sourceDomain: domain.domainName, sourceKey: source.key)
        guard tuple.classification(standardApplicationDomain: domain.domainName) != .appManagedCredential else { return }
        try validateMigrationStatuses(sourceKey: source.key)

        let persistentValue = domain.persistentDomain()[source.key]
        var authoritativeFingerprint: String?

        if let persistentValue {
            try faultHandler(.beforeDatabaseWrite, tuple)
            let capture = try CanonicalPropertyListCapture.make(
                value: persistentValue,
                normalizeSet: source.usesSetSemantics
            )
            authoritativeFingerprint = capture.fingerprint
            let expectedPaths = source.elementPaths(from: persistentValue)

            try dbPool.write { db in
                try faultHandler(.duringInboxTransaction, tuple)
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO legacyDefaultsInbox
                            (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                             expectedElementCount, capturedAt, lifecycleStatus)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'captured')
                        """,
                    arguments: [domain.domainName, source.key, capture.valueType, capture.payload,
                                capture.fingerprint, expectedPaths.count, clock()]
                )
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO legacyStateMigration
                            (sourceDomain, sourceKey, fingerprint, status, updatedAt)
                        VALUES (?, ?, ?, 'captured', ?)
                        """,
                    arguments: [domain.domainName, source.key, capture.fingerprint, clock()]
                )
            }
            observe(source: source, outcome: LegacyMigrationStatus.captured.rawValue)

            try faultHandler(.afterInboxCommitBeforeReadback, tuple)
            guard try verifiedCapture(capture, source: source) else {
                throw LegacyDefaultsMigrationError.canonicalReadbackFailed(domain: domain.domainName, key: source.key)
            }
            try faultHandler(.afterInboxReadbackBeforeRemoval, tuple)

            try advanceStatus(.cleanupPending, source: source, fingerprint: capture.fingerprint)
            domain.removeObject(forKey: source.key)
            try faultHandler(.afterRemovalBeforeVerification, tuple)
            try faultHandler(.duringRemovalVerification, tuple)
            guard domain.persistentDomain()[source.key] == nil else {
                throw LegacyDefaultsMigrationError.persistentCleanupFailed(domain: domain.domainName, key: source.key)
            }
            try advanceStatus(.cleanupVerified, source: source, fingerprint: capture.fingerprint)
        }

        if authoritativeFingerprint == nil {
            authoritativeFingerprint = try latestUnresolvedFingerprint(for: source)
        }
        if let authoritativeFingerprint {
            try resolveSupersededCaptures(
                for: source,
                authoritativeFingerprint: authoritativeFingerprint
            )
        }

        let pending = try unresolvedCaptures(for: source)
        for capture in pending {
            if domain.persistentDomain()[source.key] == nil {
                try advanceToCleanupVerified(source: source, fingerprint: capture.fingerprint)
            }
            try faultHandler(.afterCleanupBeforeNormalization, tuple)
            try normalize(capture, source: source)
            try faultHandler(.afterNormalizationCommit, tuple)
        }
    }

    private func verifiedCapture(_ capture: CanonicalPropertyListCapture, source: StandardSource) throws -> Bool {
        try dbPool.read { db in
            guard let row = try LegacyDefaultsInboxRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain.domainName, source.key, capture.fingerprint]
            ) else { return false }
            return row.valueType == capture.valueType
                && row.canonicalPayload == capture.payload
                && row.fingerprint == CanonicalPropertyListCapture.digest(row.canonicalPayload)
        }
    }

    private func unresolvedCaptures(for source: StandardSource) throws -> [LegacyDefaultsInboxRecord] {
        try dbPool.read { db in
            try LegacyDefaultsInboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ? AND lifecycleStatus = 'captured'
                    ORDER BY capturedAt, fingerprint
                    """,
                arguments: [domain.domainName, source.key]
            )
        }
    }

    private func latestUnresolvedFingerprint(for source: StandardSource) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(db, sql: """
                SELECT fingerprint FROM legacyDefaultsInbox
                WHERE sourceDomain = ? AND sourceKey = ? AND lifecycleStatus = 'captured'
                ORDER BY capturedAt DESC, rowid DESC LIMIT 1
                """, arguments: [domain.domainName, source.key])
        }
    }

    private func resolveSupersededCaptures(
        for source: StandardSource,
        authoritativeFingerprint: String
    ) throws {
        let superseded = try dbPool.read { db in
            try LegacyDefaultsInboxRecord.fetchAll(db, sql: """
                SELECT * FROM legacyDefaultsInbox
                WHERE sourceDomain = ? AND sourceKey = ?
                    AND lifecycleStatus = 'captured' AND fingerprint != ?
                ORDER BY capturedAt, rowid
                """, arguments: [domain.domainName, source.key, authoritativeFingerprint])
        }
        guard !superseded.isEmpty else { return }

        try dbPool.write { db in
            for capture in superseded {
                let value = try CanonicalPropertyListCapture(
                    valueType: capture.valueType, payload: capture.canonicalPayload,
                    fingerprint: capture.fingerprint
                ).decodedValue()
                let archiveID = try archive(capture, reason: "supersededByNewerSourceGeneration", in: db)
                for path in source.elementPaths(from: value) {
                    try recordOutcome(
                        path: path, disposition: .archived, targetKind: "legacyStateArchive",
                        targetIdentity: archiveID, targetFingerprint: capture.fingerprint,
                        capture: capture, in: db
                    )
                }
                let covered = try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT elementPath) FROM legacyDefaultsOutcome
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """, arguments: [
                        capture.sourceDomain, capture.sourceKey, capture.fingerprint
                    ]) ?? 0
                guard covered == capture.expectedElementCount else {
                    throw LegacyDefaultsMigrationError.incompleteOutcomeCoverage(
                        domain: capture.sourceDomain, key: capture.sourceKey
                    )
                }
                try db.execute(sql: """
                    UPDATE legacyDefaultsInbox SET lifecycleStatus = 'resolved'
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """, arguments: [capture.sourceDomain, capture.sourceKey, capture.fingerprint])
                try db.execute(sql: """
                    UPDATE legacyStateMigration SET status = 'resolved', updatedAt = ?
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """, arguments: [
                        clock(), capture.sourceDomain, capture.sourceKey, capture.fingerprint
                    ])
            }
        }
        superseded.forEach { _ in observe(source: source, outcome: LegacyMigrationStatus.resolved.rawValue) }
    }

    private func validateMigrationStatuses(sourceKey: String) throws {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT inbox.fingerprint, ledger.status
                    FROM legacyDefaultsInbox inbox
                    LEFT JOIN legacyStateMigration ledger
                      ON ledger.sourceDomain = inbox.sourceDomain
                     AND ledger.sourceKey = inbox.sourceKey
                     AND ledger.fingerprint = inbox.fingerprint
                    WHERE inbox.sourceDomain = ? AND inbox.sourceKey = ?
                    """,
                arguments: [domain.domainName, sourceKey]
            )
            for row in rows {
                let fingerprint: String = row["fingerprint"]
                guard let status: String = row["status"] else {
                    throw LegacyDefaultsMigrationError.missingMigrationStatus(
                        domain: domain.domainName,
                        key: sourceKey,
                        fingerprint: fingerprint
                    )
                }
                guard LegacyMigrationStatus(rawValue: status) != nil else {
                    throw LegacyDefaultsMigrationError.unknownMigrationStatus(
                        domain: domain.domainName,
                        key: sourceKey,
                        fingerprint: fingerprint,
                        status: status
                    )
                }
            }
        }
    }

    private func advanceStatus(
        _ status: LegacyMigrationStatus,
        source: StandardSource,
        fingerprint: String
    ) throws {
        try dbPool.write { db in
            let current = try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain.domainName, source.key, fingerprint]
            )
            guard let current else {
                throw LegacyDefaultsMigrationError.missingMigrationStatus(
                    domain: domain.domainName,
                    key: source.key,
                    fingerprint: fingerprint
                )
            }
            guard let currentStatus = LegacyMigrationStatus(rawValue: current) else {
                throw LegacyDefaultsMigrationError.unknownMigrationStatus(
                    domain: domain.domainName,
                    key: source.key,
                    fingerprint: fingerprint,
                    status: current
                )
            }
            if currentStatus == status { return }
            guard status.rank == currentStatus.rank + 1 else {
                throw LegacyDefaultsMigrationError.invalidStatusTransition(from: currentStatus, to: status)
            }
            try db.execute(
                sql: """
                    UPDATE legacyStateMigration SET status = ?, updatedAt = ?
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [status.rawValue, clock(), domain.domainName, source.key, fingerprint]
            )
        }
        observe(source: source, outcome: status.rawValue)
    }

    private func advanceToCleanupVerified(source: StandardSource, fingerprint: String) throws {
        let current = try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain.domainName, source.key, fingerprint]
            )
        }
        if current == LegacyMigrationStatus.captured.rawValue {
            try advanceStatus(.cleanupPending, source: source, fingerprint: fingerprint)
        }
        try advanceStatus(.cleanupVerified, source: source, fingerprint: fingerprint)
    }

    private func normalize(
        _ capture: LegacyDefaultsInboxRecord,
        source: StandardSource
    ) throws {
        let tuple = LegacyDefaultsSourceTuple(sourceDomain: domain.domainName, sourceKey: source.key)
        let value = try CanonicalPropertyListCapture(
            valueType: capture.valueType,
            payload: capture.canonicalPayload,
            fingerprint: capture.fingerprint
        ).decodedValue()

        try dbPool.write { db in
            try normalize(value, capture: capture, source: source, in: db)

            try faultHandler(.duringNormalizationTransaction, tuple)
            let covered = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT elementPath) FROM legacyDefaultsOutcome
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [capture.sourceDomain, capture.sourceKey, capture.fingerprint]
            ) ?? 0
            guard covered == capture.expectedElementCount else {
                throw LegacyDefaultsMigrationError.incompleteOutcomeCoverage(
                    domain: capture.sourceDomain,
                    key: capture.sourceKey
                )
            }
            let ledgerStatus = try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [capture.sourceDomain, capture.sourceKey, capture.fingerprint]
            )
            guard let ledgerStatus else {
                throw LegacyDefaultsMigrationError.missingMigrationStatus(
                    domain: capture.sourceDomain,
                    key: capture.sourceKey,
                    fingerprint: capture.fingerprint
                )
            }
            guard let status = LegacyMigrationStatus(rawValue: ledgerStatus) else {
                throw LegacyDefaultsMigrationError.unknownMigrationStatus(
                    domain: capture.sourceDomain,
                    key: capture.sourceKey,
                    fingerprint: capture.fingerprint,
                    status: ledgerStatus
                )
            }
            guard status == .cleanupVerified else {
                throw LegacyDefaultsMigrationError.invalidStatusTransition(
                    from: status,
                    to: .resolved
                )
            }
            try db.execute(
                sql: """
                    UPDATE legacyDefaultsInbox SET lifecycleStatus = 'resolved'
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [capture.sourceDomain, capture.sourceKey, capture.fingerprint]
            )
            try db.execute(
                sql: """
                    UPDATE legacyStateMigration SET status = 'resolved', updatedAt = ?
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [clock(), capture.sourceDomain, capture.sourceKey, capture.fingerprint]
            )
        }
        observe(source: source, outcome: LegacyMigrationStatus.resolved.rawValue)
    }

    private func normalize(
        _ value: Any,
        capture: LegacyDefaultsInboxRecord,
        source: StandardSource,
        in db: Database
    ) throws {
        switch source {
        case .scalar(let entry):
            try normalizeScalar(value, entry: entry, capture: capture, in: db)
        case .library, .libraryBackup:
            try normalizeLibrary(value, capture: capture, isBackup: source == .libraryBackup, in: db)
        case .history:
            try normalizeHistory(value, capture: capture, in: db)
        case .readKeys:
            try normalizeReadKeys(value, capture: capture, in: db)
        case .readNumbers:
            try normalizeReadNumbers(value, capture: capture, in: db)
        case .lastRead:
            try normalizeLastRead(value, capture: capture, in: db)
        case .multiTrackerMappings:
            try normalizeMultiTracker(value, capture: capture, in: db)
        case .legacyTrackerMappings:
            try normalizeLegacyTracker(value, capture: capture, in: db)
        case .badges:
            try normalizeBadges(value, capture: capture, in: db)
        case .repositories:
            try normalizeRepositories(value, capture: capture, in: db)
        case .aliases:
            try normalizeAliases(value, capture: capture, in: db)
        }
    }

    private func normalizeScalar(
        _ value: Any,
        entry: AppPreferenceCatalogEntry,
        capture: LegacyDefaultsInboxRecord,
        in db: Database
    ) throws {
        guard let json = entry.canonicalJSON(forLegacyValue: value) else {
            let archiveID = try archive(capture, reason: "invalidCatalogValue", in: db)
            try recordOutcome(path: "$", disposition: .archived, targetKind: "legacyStateArchive",
                              targetIdentity: archiveID, targetFingerprint: capture.fingerprint,
                              capture: capture, in: db)
            return
        }
        if let existing = try AppPreference.fetchOne(db, key: entry.rawValue) {
            if existing.value == json {
                try recordOutcome(path: "$", disposition: .normalized, targetKind: "appPreference",
                                  targetIdentity: entry.rawValue, targetFingerprint: Self.digest(json),
                                  capture: capture, in: db)
            } else {
                let archiveID = try archive(capture, reason: "destinationConflict", in: db)
                try recordOutcome(path: "$", disposition: .archived, targetKind: "legacyStateArchive",
                                  targetIdentity: archiveID, targetFingerprint: capture.fingerprint,
                                  capture: capture, in: db)
            }
        } else {
            try AppPreference(key: entry.rawValue, value: json).insert(db)
            try recordOutcome(path: "$", disposition: .normalized, targetKind: "appPreference",
                              targetIdentity: entry.rawValue, targetFingerprint: Self.digest(json),
                              capture: capture, in: db)
        }
    }

    private func normalizeLibrary(
        _ value: Any,
        capture: LegacyDefaultsInboxRecord,
        isBackup: Bool,
        in db: Database
    ) throws {
        guard let data = value as? Data,
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            try archiveMalformed(capture, in: db)
            return
        }
        let category = try ensureUncategorizedCategory(in: db)
        for (index, item) in items.enumerated() {
            let path = "$[\(index)]"
            if let existing = try LibraryItem.fetchOne(db, key: item.id) {
                if Self.semanticallyEqual(existing, item) {
                    try ItemCategoryLink(itemId: item.id, categoryId: category.id).insert(db, onConflict: .ignore)
                    try normalizedOutcome(path: path, kind: "libraryItem", identity: item.id,
                                          payload: try Self.sortedJSON(item), capture: capture, in: db)
                } else {
                    try archivedOutcome(path: path, capture: capture,
                                        reason: isBackup ? "backupLibraryConflict" : "libraryConflict", in: db)
                }
            } else {
                try item.insert(db)
                try ItemCategoryLink(itemId: item.id, categoryId: category.id).insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "libraryItem", identity: item.id,
                                      payload: try Self.sortedJSON(item), capture: capture, in: db)
            }
        }
    }

    private func normalizeHistory(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let entries = try? JSONDecoder().decode([LegacyHistoryEntry].self, from: data) else {
            try archiveMalformed(capture, in: db)
            return
        }
        for (index, entry) in entries.enumerated() {
            let elementData = try Self.sortedJSON(entry)
            let elementFingerprint = Self.digest(elementData)
            let idMaterial = "ito-history-v1\u{0}\(capture.sourceDomain)\u{0}\(capture.sourceKey)\u{0}\(index)\u{0}\(elementFingerprint)"
            let historyID = Self.digest(Data(idMaterial.utf8))
            let canonicalMediaID = ImportedMediaIdentity.canonicalMediaId(
                itemId: entry.item.id,
                pluginId: entry.item.pluginId,
                mediaKind: entry.item.effectiveType
            )
            let record = ReadingHistoryRecord(
                id: historyID,
                libraryItemId: try LibraryItem.fetchOne(db, key: entry.item.id) == nil ? nil : entry.item.id,
                mediaKey: canonicalMediaID,
                title: entry.item.title,
                coverUrl: entry.item.coverUrl,
                pluginId: entry.item.pluginId,
                mediaKind: entry.item.effectiveType,
                chapterKey: entry.chapterTitle ?? "legacy-history-\(historyID)",
                chapterTitle: entry.chapterTitle,
                readAt: entry.lastReadAt
            )
            if let existing = try ReadingHistoryRecord.fetchOne(db, key: historyID) {
                if existing == record {
                    try normalizedOutcome(path: "$[\(index)]", kind: "readingHistory", identity: historyID,
                                          payload: elementData, capture: capture, in: db)
                } else {
                    try archivedOutcome(path: "$[\(index)]", capture: capture, reason: "historyConflict", in: db)
                }
            } else {
                try record.insert(db)
                try normalizedOutcome(path: "$[\(index)]", kind: "readingHistory", identity: historyID,
                                      payload: elementData, capture: capture, in: db)
            }
        }
    }

    private func normalizeReadKeys(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: Set<String>].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            for (index, chapter) in (dictionary[mediaID] ?? []).sorted().enumerated() {
                let path = "$[\(Self.pathComponent(mediaID))][\(index)]"
                guard let identity = try uniqueIdentity(for: mediaID, in: db) else {
                    try unscopedOutcome(path: path, mediaID: mediaID, payload: try Self.sortedJSON(chapter),
                                        capture: capture, in: db); continue
                }
                let record = ReadProgressKeyRecord(pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId,
                                                   mediaKind: identity.mediaKind, chapterKey: chapter, markedAt: nil,
                                                   provenance: .legacyUnknownTime)
                try record.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "readProgressKey",
                                      identity: "\(identity.pluginId)/\(identity.canonicalMediaId)/\(identity.mediaKind.rawValue)/\(chapter)",
                                      payload: Data(chapter.utf8), capture: capture, in: db)
            }
        }
    }

    private func normalizeReadNumbers(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: Set<Float>].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            for (index, number) in (dictionary[mediaID] ?? []).sorted().enumerated() {
                let path = "$[\(Self.pathComponent(mediaID))][\(index)]"
                guard number.isFinite, let identity = try uniqueIdentity(for: mediaID, in: db) else {
                    try unscopedOutcome(path: path, mediaID: mediaID, payload: try Self.sortedJSON(number),
                                        capture: capture, in: db); continue
                }
                let record = ReadProgressNumberRecord(pluginId: identity.pluginId,
                                                      canonicalMediaId: identity.canonicalMediaId,
                                                      mediaKind: identity.mediaKind,
                                                      chapterNumber: Double(number), markedAt: nil,
                                                      provenance: .legacyUnknownTime)
                try record.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "readProgressNumber",
                                      identity: "\(identity.pluginId)/\(identity.canonicalMediaId)/\(identity.mediaKind.rawValue)/\(number)",
                                      payload: try Self.sortedJSON(number), capture: capture, in: db)
            }
        }
    }

    private func normalizeLastRead(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            let path = "$[\(Self.pathComponent(mediaID))]"
            guard let chapter = dictionary[mediaID], let identity = try uniqueIdentity(for: mediaID, in: db) else {
                try unscopedOutcome(path: path, mediaID: mediaID,
                                    payload: try Self.sortedJSON(dictionary[mediaID] ?? ""), capture: capture, in: db)
                continue
            }
            let incoming = MediaReadProgressRecord(pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId,
                                                   mediaKind: identity.mediaKind, lastReadChapterKey: chapter, updatedAt: nil,
                                                   provenance: .legacyUnknownTime)
            if let existing = try MediaReadProgressRecord.fetchOne(
                db,
                sql: "SELECT * FROM mediaReadProgress WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?",
                arguments: [identity.pluginId, identity.canonicalMediaId, identity.mediaKind.rawValue]
            ), existing.lastReadChapterKey != chapter {
                try archivedOutcome(path: path, capture: capture, reason: "resumeConflict", in: db)
            } else {
                try incoming.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "mediaReadProgress",
                                      identity: "\(identity.pluginId)/\(identity.canonicalMediaId)/\(identity.mediaKind.rawValue)",
                                      payload: Data(chapter.utf8), capture: capture, in: db)
            }
        }
    }

    private func normalizeMultiTracker(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            for provider in (dictionary[mediaID] ?? [:]).keys.sorted() {
                guard let remoteID = dictionary[mediaID]?[provider] else { continue }
                let path = "$[\(Self.pathComponent(mediaID))][\(Self.pathComponent(provider))]"
                try normalizeTracker(mediaID: mediaID, provider: provider, remoteID: remoteID,
                                     path: path, capture: capture, in: db)
            }
        }
    }

    private func normalizeLegacyTracker(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: Int].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            guard let remoteID = dictionary[mediaID] else { continue }
            try normalizeTracker(mediaID: mediaID, provider: "anilist", remoteID: String(remoteID),
                                 path: "$[\(Self.pathComponent(mediaID))]", capture: capture, in: db)
        }
    }

    private func normalizeTracker(
        mediaID: String,
        provider: String,
        remoteID: String,
        path: String,
        capture: LegacyDefaultsInboxRecord,
        in db: Database
    ) throws {
        guard let identity = try uniqueIdentity(for: mediaID, in: db) else {
            try unscopedOutcome(path: path, mediaID: mediaID, payload: Data(remoteID.utf8), capture: capture, in: db)
            return
        }
        let existing = try TrackerLinkRecord.fetchOne(
            db,
            sql: "SELECT * FROM trackerLink WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ? AND providerId = ?",
            arguments: [identity.pluginId, identity.canonicalMediaId, identity.mediaKind.rawValue, provider]
        )
        if let existing, existing.remoteMediaId != remoteID {
            try archivedOutcome(path: path, capture: capture, reason: "trackerConflict", in: db)
        } else {
            let record = TrackerLinkRecord(pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId,
                                           mediaKind: identity.mediaKind, providerId: provider, remoteMediaId: remoteID,
                                           updatedAt: nil, provenance: .legacyUnknownTime)
            try record.insert(db, onConflict: .ignore)
            try normalizedOutcome(path: path, kind: "trackerLink",
                                  identity: "\(identity.pluginId)/\(identity.canonicalMediaId)/\(identity.mediaKind.rawValue)/\(provider)",
                                  payload: Data(remoteID.utf8), capture: capture, in: db)
        }
    }

    private func normalizeBadges(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let dictionary = try? JSONDecoder().decode([String: Int].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for mediaID in dictionary.keys.sorted() {
            let path = "$[\(Self.pathComponent(mediaID))]"
            guard let count = dictionary[mediaID], count >= 0 else {
                try archivedOutcome(path: path, capture: capture, reason: "invalidBadge", in: db); continue
            }
            guard let identity = try uniqueIdentity(for: mediaID, in: db) else {
                try unscopedOutcome(path: path, mediaID: mediaID, payload: try Self.sortedJSON(count),
                                    capture: capture, in: db); continue
            }
            let existing = try UpdateBadgeRecord.fetchOne(
                db,
                sql: "SELECT * FROM updateBadge WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?",
                arguments: [identity.pluginId, identity.canonicalMediaId, identity.mediaKind.rawValue]
            )
            if let existing, existing.count != count {
                try archivedOutcome(path: path, capture: capture, reason: "badgeConflict", in: db)
            } else {
                let record = UpdateBadgeRecord(pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId,
                                               mediaKind: identity.mediaKind, count: count, updatedAt: nil,
                                               provenance: .legacyUnknownTime)
                try record.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "updateBadge",
                                      identity: "\(identity.pluginId)/\(identity.canonicalMediaId)/\(identity.mediaKind.rawValue)",
                                      payload: try Self.sortedJSON(count), capture: capture, in: db)
            }
        }
    }

    private func normalizeRepositories(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let repositories = try? JSONDecoder().decode([Repository].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for (index, repository) in repositories.enumerated() {
            let normalizedURL = Self.normalizedRepositoryURL(repository.url)
            guard !normalizedURL.isEmpty else {
                try archivedOutcome(path: "$[\(index)]", capture: capture, reason: "invalidRepositoryURL", in: db)
                continue
            }
            let record = RepositoryRecord(
                url: normalizedURL,
                lastFetched: repository.lastFetched,
                indexPayload: try repository.index.map { try Self.sortedJSON($0) }
            )
            if let existing = try RepositoryRecord.fetchOne(db, key: normalizedURL), existing != record {
                try archivedOutcome(path: "$[\(index)]", capture: capture, reason: "repositoryConflict", in: db)
            } else {
                try record.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: "$[\(index)]", kind: "repository", identity: normalizedURL,
                                      payload: try Self.sortedJSON(repository), capture: capture, in: db)
            }
        }
    }

    private func normalizeAliases(_ value: Any, capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        guard let data = value as? Data,
              let aliases = try? JSONDecoder().decode([String: String].self, from: data) else {
            try archiveMalformed(capture, in: db); return
        }
        for foreignID in aliases.keys.sorted() {
            guard let pluginID = aliases[foreignID] else { continue }
            let path = "$[\(Self.pathComponent(foreignID))]"
            if let existing = try PluginMigrationAliasRecord.fetchOne(db, key: foreignID), existing.pluginId != pluginID {
                try archivedOutcome(path: path, capture: capture, reason: "aliasConflict", in: db)
            } else {
                let record = PluginMigrationAliasRecord(foreignId: foreignID, pluginId: pluginID, updatedAt: clock())
                try record.insert(db, onConflict: .ignore)
                try normalizedOutcome(path: path, kind: "pluginMigrationAlias", identity: foreignID,
                                      payload: Data(pluginID.utf8), capture: capture, in: db)
            }
        }
    }

    private func materializeMissingScalarDefaults() throws {
        try dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                if try AppPreference.fetchOne(db, key: entry.rawValue) == nil {
                    try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
                }
            }
        }
    }

    private func ensureUncategorizedCategory(in db: Database) throws -> LibraryCategory {
        if let category = try LibraryCategory.filter(Column("isSystemCategory") == true).fetchOne(db) {
            return category
        }
        let category = LibraryCategory(name: "Uncategorized", sortOrder: 0, isSystemCategory: true, createdAt: clock())
        try category.insert(db)
        return category
    }

    private func uniqueIdentity(for legacyMediaID: String, in db: Database) throws -> MediaIdentity? {
        let candidates = try identityCandidates(for: legacyMediaID, in: db)
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    private func identityCandidates(
        for legacyMediaID: String,
        in db: Database
    ) throws -> Set<MediaIdentity> {
        var candidates: Set<MediaIdentity> = []

        func addMatchingMediaEvidence(pluginID: String, mediaID: String, mediaKind: MediaKind) {
            let evidenceCanonical = ImportedMediaIdentity.canonicalMediaId(
                itemId: mediaID,
                pluginId: pluginID,
                mediaKind: mediaKind
            )
            let legacyCanonical = ImportedMediaIdentity.canonicalMediaId(
                itemId: legacyMediaID,
                pluginId: pluginID,
                mediaKind: mediaKind
            )
            guard evidenceCanonical == legacyCanonical else { return }
            candidates.insert(MediaIdentity(pluginId: pluginID, canonicalMediaId: evidenceCanonical, mediaKind: mediaKind))
        }

        for item in try LibraryItem.fetchAll(db) {
            addMatchingMediaEvidence(pluginID: item.pluginId, mediaID: item.id, mediaKind: item.effectiveType)
        }
        for history in try ReadingHistoryRecord.fetchAll(db) {
            addMatchingMediaEvidence(pluginID: history.pluginId, mediaID: history.mediaKey, mediaKind: history.mediaKind)
            if let libraryItemID = history.libraryItemId {
                addMatchingMediaEvidence(pluginID: history.pluginId, mediaID: libraryItemID, mediaKind: history.mediaKind)
            }
        }
        if try db.tableExists(SourceMappingRecord.databaseTableName) {
            for mapping in try SourceMappingRecord.fetchAll(db) {
                addMatchingMediaEvidence(
                    pluginID: mapping.pluginId,
                    mediaID: mapping.pluginMediaKey,
                    mediaKind: mapping.mediaType.mediaKind
                )
            }
        }

        if !candidates.isEmpty {
            return candidates
        }

        // Prefix evidence names the plugin only; its kind is known only when the plugin declares exactly one.
        let kindResolver = try LegacyMediaKindResolver(db: db)
        func kinds(of pluginID: String) -> [MediaKind] {
            kindResolver.declaredKind(ofPlugin: pluginID).map { [$0] } ?? MediaKind.allCases
        }
        let identities = try PluginIdentityRecord.fetchAll(db)
        let aliases = try PluginIdentityAliasRecord.fetchAll(db)
        let aliasesByPlugin = Dictionary(grouping: aliases, by: \.pluginId)
        for identity in identities {
            var prefixes = Set([identity.pluginId])
            if let manifestID = identity.manifestId {
                prefixes.insert(manifestID)
            }
            prefixes.formUnion((aliasesByPlugin[identity.pluginId] ?? []).map(\.aliasValue))
            for prefix in prefixes {
                if let canonicalMediaID = Self.prefixedMediaID(legacyMediaID, prefix: prefix) {
                    for kind in kinds(of: identity.pluginId) {
                        candidates.insert(MediaIdentity(
                            pluginId: identity.pluginId,
                            canonicalMediaId: canonicalMediaID,
                            mediaKind: kind
                        ))
                    }
                }
            }
        }

        for alias in try PluginMigrationAliasRecord.fetchAll(db) {
            if let canonicalMediaID = Self.prefixedMediaID(legacyMediaID, prefix: alias.foreignId) {
                for kind in kinds(of: alias.pluginId) {
                    candidates.insert(MediaIdentity(
                        pluginId: alias.pluginId,
                        canonicalMediaId: canonicalMediaID,
                        mediaKind: kind
                    ))
                }
            }
        }
        return candidates
    }

    private func archiveMalformed(_ capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        let identity = try archive(capture, reason: "malformedOrUnsupported", in: db)
        try recordOutcome(path: "$", disposition: .archived, targetKind: "legacyStateArchive",
                          targetIdentity: identity, targetFingerprint: capture.fingerprint,
                          capture: capture, in: db)
    }

    private func archivedOutcome(
        path: String,
        capture: LegacyDefaultsInboxRecord,
        reason: String,
        in db: Database
    ) throws {
        let identity = try archive(capture, reason: reason, in: db)
        try recordOutcome(path: path, disposition: .archived, targetKind: "legacyStateArchive",
                          targetIdentity: identity, targetFingerprint: capture.fingerprint,
                          capture: capture, in: db)
    }

    private func archive(_ capture: LegacyDefaultsInboxRecord, reason: String, in db: Database) throws -> String {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO legacyStateArchive
                    (sourceDomain, sourceKey, contentClass, valueType, valuePayload, fingerprint, reason, createdAt)
                VALUES (?, ?, 'appNonSecret', ?, ?, ?, ?, ?)
                """,
            arguments: [capture.sourceDomain, capture.sourceKey, capture.valueType,
                        capture.canonicalPayload, capture.fingerprint, reason, clock()]
        )
        guard let id = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM legacyStateArchive
                WHERE sourceDomain = ? AND sourceKey = ? AND contentClass = 'appNonSecret'
                    AND valueType = ? AND fingerprint = ?
                """,
            arguments: [capture.sourceDomain, capture.sourceKey, capture.valueType, capture.fingerprint]
        ) else {
            throw LegacyDefaultsMigrationError.legacyStateArchiveReadbackFailed(
                domain: capture.sourceDomain,
                key: capture.sourceKey,
                fingerprint: capture.fingerprint
            )
        }
        return String(id)
    }

    private func unscopedOutcome(
        path: String,
        mediaID: String,
        payload: Data,
        capture: LegacyDefaultsInboxRecord,
        in db: Database
    ) throws {
        let candidates = try candidateData(for: mediaID, in: db)
        let fingerprint = Self.digest(payload)
        let record = LegacyUnscopedMediaStateRecord(
            sourceKey: capture.sourceKey,
            legacyMediaId: mediaID,
            canonicalPayload: payload,
            candidates: candidates,
            fingerprint: fingerprint
        )
        try record.insert(db, onConflict: .ignore)
        try recordOutcome(path: path, disposition: .unscoped, targetKind: "legacyUnscopedMediaState",
                          targetIdentity: "\(mediaID)/\(fingerprint)", targetFingerprint: fingerprint,
                          capture: capture, in: db)
    }

    private func candidateData(for legacyMediaID: String, in db: Database) throws -> Data {
        let candidates = try identityCandidates(for: legacyMediaID, in: db).sorted {
            ($0.pluginId, $0.canonicalMediaId, $0.mediaKind.rawValue) < ($1.pluginId, $1.canonicalMediaId, $1.mediaKind.rawValue)
        }
        return try Self.sortedJSON(candidates)
    }

    private func normalizedOutcome(
        path: String,
        kind: String,
        identity: String,
        payload: Data,
        capture: LegacyDefaultsInboxRecord,
        in db: Database
    ) throws {
        try recordOutcome(path: path, disposition: .normalized, targetKind: kind,
                          targetIdentity: identity, targetFingerprint: Self.digest(payload),
                          capture: capture, in: db)
    }

    private func recordOutcome(
        path: String,
        disposition: LegacyDefaultsDisposition,
        targetKind: String,
        targetIdentity: String,
        targetFingerprint: String,
        capture: LegacyDefaultsInboxRecord,
        in db: Database
    ) throws {
        let record = LegacyDefaultsOutcomeRecord(
            sourceDomain: capture.sourceDomain,
            sourceKey: capture.sourceKey,
            fingerprint: capture.fingerprint,
            elementPath: path,
            disposition: disposition,
            targetKind: targetKind,
            targetIdentity: targetIdentity,
            targetFingerprint: targetFingerprint
        )
        try record.insert(db, onConflict: .ignore)
    }

    private static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func semanticallyEqual(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.coverUrl == rhs.coverUrl
            && lhs.pluginId == rhs.pluginId && lhs.isAnime == rhs.isAnime
            && lhs.pluginType == rhs.pluginType && lhs.rawPayload == rhs.rawPayload
            && lhs.anilistId == rhs.anilistId && lhs.status == rhs.status
            && lhs.lastCheckedAt == rhs.lastCheckedAt && lhs.lastUpdatedAt == rhs.lastUpdatedAt
            && lhs.knownChapterCount == rhs.knownChapterCount
    }

    private static func normalizedRepositoryURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("/index.json") { result.removeLast("/index.json".count) }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    fileprivate static func pathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "]", with: "~1")
    }

    private static func prefixedMediaID(_ mediaID: String, prefix: String) -> String? {
        let marker = "\(prefix)_"
        guard mediaID.hasPrefix(marker) else { return nil }
        let suffix = String(mediaID.dropFirst(marker.count))
        return suffix.isEmpty ? nil : suffix
    }

    private static func digest(_ data: Data) -> String {
        CanonicalPropertyListCapture.digest(data)
    }

    private func observe(source: StandardSource, outcome: String) {
        eventObserver(LegacyMigrationEvent(
            sourceDomain: domain.domainName,
            sourceKey: source.key,
            outcome: outcome
        ))
    }
}

private struct LegacyHistoryEntry: Codable {
    let item: LibraryItem
    var lastReadAt: Date
    var chapterTitle: String?
}

private enum StandardSource: Equatable {
    case library
    case libraryBackup
    case history
    case readKeys
    case readNumbers
    case lastRead
    case multiTrackerMappings
    case legacyTrackerMappings
    case badges
    case repositories
    case aliases
    case scalar(AppPreferenceCatalogEntry)

    static let orderedSources: [Self] = [
        .library, .libraryBackup, .history, .readKeys, .readNumbers, .lastRead,
        .multiTrackerMappings, .legacyTrackerMappings, .badges, .repositories, .aliases
    ] + AppPreferenceCatalogEntry.allCases.map(Self.scalar)

    var key: String {
        switch self {
        case .library: "ito_library_items"
        case .libraryBackup: "ito_library_items_backup"
        case .history: "ito_reading_history"
        case .readKeys: "Ito.ReadChapters"
        case .readNumbers: "Ito.ReadChapterNumbers"
        case .lastRead: "Ito.LastReadChapter"
        case .multiTrackerMappings: "Ito.MultiTrackerMappings"
        case .legacyTrackerMappings: "Ito.TrackerMappings"
        case .badges: "Ito.NewChapterCounts"
        case .repositories: "ito_repositories"
        case .aliases: "ito_user_migration_aliases"
        case .scalar(let entry): entry.rawValue
        }
    }

    var usesSetSemantics: Bool {
        self == .readKeys || self == .readNumbers
    }

    func elementPaths(from value: Any) -> [String] {
        guard let data = value as? Data else { return ["$"] }
        switch self {
        case .library, .libraryBackup:
            return (try? JSONDecoder().decode([LibraryItem].self, from: data))?.indices.map { "$[\($0)]" } ?? ["$"]
        case .history:
            return (try? JSONDecoder().decode([LegacyHistoryEntry].self, from: data))?.indices.map { "$[\($0)]" } ?? ["$"]
        case .readKeys:
            guard let dictionary = try? JSONDecoder().decode([String: Set<String>].self, from: data) else { return ["$"] }
            return dictionary.keys.sorted().flatMap { mediaID in
                (dictionary[mediaID] ?? []).sorted().indices.map { "$[\(LegacyDefaultsMigrator.pathComponent(mediaID))][\($0)]" }
            }
        case .readNumbers:
            guard let dictionary = try? JSONDecoder().decode([String: Set<Float>].self, from: data) else { return ["$"] }
            return dictionary.keys.sorted().flatMap { mediaID in
                (dictionary[mediaID] ?? []).sorted().indices.map { "$[\(LegacyDefaultsMigrator.pathComponent(mediaID))][\($0)]" }
            }
        case .multiTrackerMappings:
            guard let dictionary = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return ["$"] }
            return dictionary.keys.sorted().flatMap { mediaID in
                (dictionary[mediaID] ?? [:]).keys.sorted().map {
                    "$[\(LegacyDefaultsMigrator.pathComponent(mediaID))][\(LegacyDefaultsMigrator.pathComponent($0))]"
                }
            }
        case .lastRead, .legacyTrackerMappings, .badges:
            guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["$"] }
            return dictionary.keys.sorted().map { "$[\(LegacyDefaultsMigrator.pathComponent($0))]" }
        case .repositories:
            return (try? JSONDecoder().decode([Repository].self, from: data))?.indices.map { "$[\($0)]" } ?? ["$"]
        case .aliases:
            guard let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else { return ["$"] }
            return dictionary.keys.sorted().map { "$[\(LegacyDefaultsMigrator.pathComponent($0))]" }
        case .scalar:
            return ["$"]
        }
    }
}

private extension LegacyMigrationStatus {
    var rank: Int {
        switch self {
        case .captured: 0
        case .cleanupPending: 1
        case .cleanupVerified: 2
        case .resolved: 3
        }
    }
}
