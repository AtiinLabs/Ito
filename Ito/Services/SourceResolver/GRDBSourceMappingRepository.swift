import Foundation
import GRDB

public protocol SourceMappingRepository: Sendable {
    func fetchConfirmed(canonicalProvider: String, canonicalMediaId: String, mediaType: PluginMediaType) async throws -> [SourceMappingRecord]
    func fetchAll(canonicalProvider: String, canonicalMediaId: String, mediaType: PluginMediaType) async throws -> [SourceMappingRecord]
    func find(pluginId: String, pluginMediaKey: String) async throws -> [SourceMappingRecord]
    func upsert(_ record: SourceMappingRecord) async throws
    func persistRejection(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws
    func unlink(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws
}

public final class GRDBSourceMappingRepository: SourceMappingRepository {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func fetchConfirmed(canonicalProvider: String, canonicalMediaId: String, mediaType: PluginMediaType) async throws -> [SourceMappingRecord] {
        try await dbWriter.read { db in
            try SourceMappingRecord
                .filter(Column("canonicalProvider") == canonicalProvider)
                .filter(Column("canonicalMediaId") == canonicalMediaId)
                .filter(Column("mediaType") == mediaType)
                .filter(Column("decision") != MatchDecision.discard)
                .fetchAll(db)
        }
    }

    public func fetchAll(canonicalProvider: String, canonicalMediaId: String, mediaType: PluginMediaType) async throws -> [SourceMappingRecord] {
        try await dbWriter.read { db in
            try SourceMappingRecord
                .filter(Column("canonicalProvider") == canonicalProvider)
                .filter(Column("canonicalMediaId") == canonicalMediaId)
                .filter(Column("mediaType") == mediaType)
                .fetchAll(db)
        }
    }

    public func find(pluginId: String, pluginMediaKey: String) async throws -> [SourceMappingRecord] {
        try await dbWriter.read { db in
            try SourceMappingRecord
                .filter(Column("pluginId") == pluginId)
                .filter(Column("pluginMediaKey") == pluginMediaKey)
                .fetchAll(db)
        }
    }

    public func upsert(_ record: SourceMappingRecord) async throws {
        try await dbWriter.write { db in
            let existing = try SourceMappingRecord
                .filter(Column("canonicalProvider") == record.canonicalProvider)
                .filter(Column("canonicalMediaId") == record.canonicalMediaId)
                .filter(Column("mediaType") == record.mediaType)
                .filter(Column("pluginId") == record.pluginId)
                .filter(Column("pluginMediaKey") == record.pluginMediaKey)
                .fetchOne(db)

            let now = Date()

            if let existing = existing {
                let updatedRecord = SourceMappingRecord(
                    canonicalProvider: record.canonicalProvider,
                    canonicalMediaId: record.canonicalMediaId,
                    mediaType: record.mediaType,
                    pluginId: record.pluginId,
                    pluginMediaKey: record.pluginMediaKey,
                    decision: record.decision,
                    matchMethod: record.matchMethod,
                    confidence: record.confidence,
                    titleSnapshot: record.titleSnapshot,
                    createdAt: existing.createdAt, // Preserve createdAt
                    updatedAt: now,
                    coverURLSnapshot: record.coverURLSnapshot,
                    encodedPayload: record.encodedPayload,
                    payloadVersion: record.payloadVersion,
                    pluginVersion: record.pluginVersion,
                    lastVerifiedAt: record.lastVerifiedAt
                )
                try updatedRecord.update(db)
            } else {
                let updatedRecord = SourceMappingRecord(
                    canonicalProvider: record.canonicalProvider,
                    canonicalMediaId: record.canonicalMediaId,
                    mediaType: record.mediaType,
                    pluginId: record.pluginId,
                    pluginMediaKey: record.pluginMediaKey,
                    decision: record.decision,
                    matchMethod: record.matchMethod,
                    confidence: record.confidence,
                    titleSnapshot: record.titleSnapshot,
                    createdAt: record.createdAt,
                    updatedAt: now,
                    coverURLSnapshot: record.coverURLSnapshot,
                    encodedPayload: record.encodedPayload,
                    payloadVersion: record.payloadVersion,
                    pluginVersion: record.pluginVersion,
                    lastVerifiedAt: record.lastVerifiedAt
                )
                try updatedRecord.insert(db)
            }
        }
    }

    public func persistRejection(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        let now = Date()
        let rejection = SourceMappingRecord(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: mediaType,
            pluginId: pluginId,
            pluginMediaKey: pluginMediaKey,
            decision: .discard,
            matchMethod: .none,
            confidence: 1.0,
            titleSnapshot: "",
            createdAt: now,
            updatedAt: now,
            coverURLSnapshot: nil,
            encodedPayload: nil,
            payloadVersion: nil,
            pluginVersion: nil,
            lastVerifiedAt: nil
        )
        try await upsert(rejection)
    }

    public func unlink(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        _ = try await dbWriter.write { db in
            try SourceMappingRecord
                .filter(Column("canonicalProvider") == canonicalProvider)
                .filter(Column("canonicalMediaId") == canonicalMediaId)
                .filter(Column("mediaType") == mediaType)
                .filter(Column("pluginId") == pluginId)
                .filter(Column("pluginMediaKey") == pluginMediaKey)
                .deleteAll(db)
        }
    }
}
