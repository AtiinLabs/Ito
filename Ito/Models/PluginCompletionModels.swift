import Foundation
import GRDB

nonisolated enum PluginCompletionKind: String, Codable, Sendable, CaseIterable {
    case manga, novel, anime
}

nonisolated struct PluginCompletionContext: Hashable, Sendable {
    let media: MediaIdentity
    /// The original source key, not a canonical local library row ID.
    let mediaKey: String
    let kind: PluginCompletionKind
    /// Nil is an unverified origin and must never mean "use current configuration".
    let originatingEpoch: String?
}

nonisolated enum PluginCompletionStatus: String, Codable, Sendable {
    case pending, paused
}

nonisolated enum PluginCompletionPauseReason: String, Codable, Sendable, CaseIterable, Hashable {
    case configurationChanged, unknownOrigin, credentials, missingRemote
    case sourceUnavailable, incompatible, sourceError, retryLimit
}

nonisolated enum PluginCompletionFailureCategory: String, Codable, Sendable {
    case network, server, credentials, missingRemote, sourceUnavailable
    case incompatible, sourceError, configurationChanged, unknownOrigin
}

nonisolated struct PluginCompletionIntent: Decodable, FetchableRecord, TableRecord, Sendable {
    static let databaseTableName = "pluginCompletionOutbox"

    let id: Int64
    let pluginId: String
    let canonicalMediaId: String
    let mediaKey: String
    let unitKey: String
    let kind: PluginCompletionKind
    let originatingEpoch: String?
    let revision: Int64
    let status: PluginCompletionStatus
    let pauseReason: PluginCompletionPauseReason?
    let attemptCount: Int
    let createdAt: Date
    let nextAttemptAt: Date
    let lastAttemptAt: Date?
    let lastErrorCategory: PluginCompletionFailureCategory?
}

/// Immutable optimistic identity; stale responses cannot acknowledge a replacement row or account.
nonisolated struct PluginCompletionAttempt: Hashable, Sendable {
    let id: Int64
    let revision: Int64
    let pluginID: String
    let originatingEpoch: String

    init?(_ intent: PluginCompletionIntent) {
        guard intent.status == .pending, let epoch = intent.originatingEpoch else { return nil }
        id = intent.id
        revision = intent.revision
        pluginID = intent.pluginId
        originatingEpoch = epoch
    }
}

nonisolated struct PluginCompletionSnapshot: Sendable {
    let intent: PluginCompletionIntent
    /// Volatile execution settings. Never persisted, logged, or handed to a shared browsing runner.
    let settings: [String: String]
}

nonisolated enum PluginCompletionOutcome: Sendable {
    case acknowledged
    case unsupported
    case cancelled
    case retryable(PluginCompletionFailureCategory)
    case paused(PluginCompletionPauseReason, PluginCompletionFailureCategory?)
}

nonisolated struct PluginCompletionSummary: Equatable, Sendable, Identifiable {
    let pluginID: String
    let pendingCount: Int
    let pausedCount: Int
    let pauseReasons: Set<PluginCompletionPauseReason>
    var id: String { pluginID }
}

@MainActor
protocol PluginCompletionScopeCapturing {
    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String,
        kind: PluginCompletionKind
    ) -> PluginCompletionContext
}
