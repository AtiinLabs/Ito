import Foundation
import OSLog

public enum PresentationFeature: String, Equatable, Sendable {
    case search
    case trackingSettings = "tracking_settings"
    case trackerSearch = "tracker_search"
    case trackerDetails = "tracker_details"
    case mediaDetail = "media_detail"
    case library
    case deferredPlugin = "deferred_plugin"
    case categorySettings = "category_settings"
    case categoryAssignment = "category_assignment"
    case history
    case mangaReader = "manga_reader"
    case novelReader = "novel_reader"
    case videoPlayer = "video_player"
    case backupSettings = "backup_settings"
    case migrationReport = "migration_report"
}

public enum PresentationEventKind: String, Equatable, Sendable {
    case operation
    case pluginExecution = "plugin_execution"
    case authentication
    case logout
    case preferenceWrite = "preference_write"
    case trackerSearch = "tracker_search"
    case remoteLoad = "remote_load"
    case remoteUpdate = "remote_update"
    case link
    case unlink
    case externalURL = "external_url"
    case detailLoad = "detail_load"
    case libraryMutation = "library_mutation"
    case relinkSearch = "relink_search"
    case relink
    case baseline
    case backupExport = "backup_export"
    case backupMergeAnalysis = "backup_merge_analysis"
    case backupRestore = "backup_restore"
    case backupRefresh = "backup_refresh"
    case backupReportAcknowledgment = "backup_report_acknowledgment"
    case pluginInstall = "plugin_install"
    case runnerLoad = "runner_load"
    case payloadDecode = "payload_decode"
    case categoryCreate = "category_create"
    case categoryRename = "category_rename"
    case categoryDelete = "category_delete"
    case categoryReorder = "category_reorder"
    case categoryAssignment = "category_assignment"
    case categoryCreateAndAssign = "category_create_and_assign"
    case historyDelete = "history_delete"
    case historyClear = "history_clear"
    case chapterPrefetch = "chapter_prefetch"
    case chapterAppend = "chapter_append"
    case chapterPrepend = "chapter_prepend"
    case chapterEffects = "chapter_effects"
    case streamLoad = "stream_load"
    case subtitleLoad = "subtitle_load"
    case playerPreparation = "player_preparation"
    case playbackProgress = "playback_progress"
}

public enum PresentationEventPhase: String, Equatable, Sendable {
    case started
    case finished
}

public enum PresentationErrorCategory: String, Equatable, Sendable {
    case pluginUnavailable = "plugin_unavailable"
    case pluginExecution = "plugin_execution"
    case pluginTrap = "plugin_trap"
    case authentication
    case logout
    case network
    case persistence
    case externalURL = "external_url"
    case unknown
}

public enum PresentationEventOutcome: Equatable, Sendable {
    case succeeded
    case partiallySucceeded(PresentationErrorCategory)
    case failed(PresentationErrorCategory)
    case cancelled
    case ignoredStale

    fileprivate var formattedValue: String {
        switch self {
        case .succeeded:
            return "succeeded"
        case .partiallySucceeded:
            return "partial_failure"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        case .ignoredStale:
            return "ignored_stale"
        }
    }

    fileprivate var errorCategory: PresentationErrorCategory? {
        switch self {
        case .partiallySucceeded(let category), .failed(let category):
            return category
        case .succeeded, .cancelled, .ignoredStale:
            return nil
        }
    }
}

public struct PresentationLogEvent: Equatable, Sendable {
    public let feature: PresentationFeature
    public let kind: PresentationEventKind
    public let operationID: UUID
    public let phase: PresentationEventPhase
    public let outcome: PresentationEventOutcome?

    private init(
        feature: PresentationFeature,
        kind: PresentationEventKind,
        operationID: UUID,
        phase: PresentationEventPhase,
        outcome: PresentationEventOutcome?
    ) {
        self.feature = feature
        self.kind = kind
        self.operationID = operationID
        self.phase = phase
        self.outcome = outcome
    }

    public static func started(
        feature: PresentationFeature,
        kind: PresentationEventKind = .operation,
        operationID: UUID
    ) -> Self {
        Self(
            feature: feature,
            kind: kind,
            operationID: operationID,
            phase: .started,
            outcome: nil
        )
    }

    public static func finished(
        feature: PresentationFeature,
        kind: PresentationEventKind = .operation,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) -> Self {
        Self(
            feature: feature,
            kind: kind,
            operationID: operationID,
            phase: .finished,
            outcome: outcome
        )
    }
}

public protocol PresentationEventLogging {
    func log(_ event: PresentationLogEvent)
}

public enum PresentationLogFormatter {
    public static func format(_ event: PresentationLogEvent) -> String {
        let outcome = event.outcome?.formattedValue ?? "none"
        let errorCategory = event.outcome?.errorCategory?.rawValue ?? "none"
        let operationID = event.operationID.uuidString.lowercased()

        return "presentation feature=\(event.feature.rawValue) kind=\(event.kind.rawValue) operation_id=\(operationID) phase=\(event.phase.rawValue) outcome=\(outcome) error_category=\(errorCategory)"
    }
}

public struct OSLogPresentationEventLogger: PresentationEventLogging {
    private let logger: Logger

    public init(logger: Logger = AppLogger.ui) {
        self.logger = logger
    }

    public func log(_ event: PresentationLogEvent) {
        let message = PresentationLogFormatter.format(event)
        logger.info("\(message, privacy: .public)")
    }
}
