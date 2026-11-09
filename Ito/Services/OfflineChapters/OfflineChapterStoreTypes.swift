import Foundation

/// Checks that only live in memory: trust generation and plugin publication revision. It is called
/// inside the commit transaction, so it must be synchronous and must not touch the database. The
/// source epoch is not checked here; the store reads it from `pluginCompletionScope` in the same
/// transaction.
typealias OfflineCommitGuard = @Sendable (DownloadJobRecord) -> Bool

nonisolated enum OfflineStoreError: Error, Equatable, Sendable {
    /// Queueing and attempts need a completed reconciliation first. A new process reconciles once
    /// at launch, so jobs without a store binding can only come from a restore.
    case reconciliationPending
    /// The attempt cannot start now. The job is left waiting with this reason.
    case blocked(DownloadWaitingReason)
    /// The job is missing, or not in a state that allows the operation.
    case jobUnavailable
    case notVerified
    case damaged(DamageReason)
    /// The verified row points at a version directory that is not on disk.
    case versionUnavailable
    case protectedDataUnavailable
}

nonisolated enum OfflineStagingError: Error, Equatable, Sendable {
    case sealed
    case unsupportedImageFormat
}

nonisolated enum OfflinePublishError: Error, Equatable, Sendable {
    /// A staged page no longer matches what was written.
    case integrityMismatch
}

/// One page to store. `text` is UTF-8 data; `image` is complete image bytes; `imageFile` is a temp
/// file the store moves into the staging directory.
nonisolated struct OfflinePageInput: Sendable {
    nonisolated enum Content: Sendable {
        case text(Data)
        case image(Data)
        case imageFile(URL)
    }

    let content: Content
    let sourceIndex: Int32
    let description: String?

    init(content: Content, sourceIndex: Int32, description: String? = nil) {
        self.content = content
        self.sourceIndex = sourceIndex
        self.description = description
    }
}

nonisolated struct OfflineStagedVersion: Sendable {
    let manifest: OfflineChapterManifest
    /// The manifest file bytes. Their digest is stored in the inventory row.
    let manifestData: Data
}

nonisolated enum OfflinePublishRefusal: Equatable, Sendable {
    /// The job was cancelled or deleted before the commit.
    case jobGone
    /// The source epoch changed since the job was queued. The job waits for an explicit Retry.
    case configurationChanged
    /// The plugin or its trust changed under the attempt. The job is queued again.
    case staleRuntime
    /// The edition already has a verified copy. M0 never replaces one.
    case alreadyVerified
}

nonisolated enum OfflinePublishOutcome: Equatable, Sendable {
    case published(versionId: String)
    /// Nothing was committed. The version was discarded unless a row still references it.
    case refused(OfflinePublishRefusal)
    /// The attempt failed before commit, so its artifacts were removed and the job moved to `outcome`.
    case discarded(DownloadAttemptOutcome)
}

/// The publish protocol's steps P1 to P5. Crash tests stop after one of them.
nonisolated enum OfflinePublishStep: CaseIterable, Sendable {
    /// P1: the job references the staging version id.
    case stagingIntent
    /// P2: every page is written into the staging directory.
    case stream
    /// P3: pages are re-read and hashed, and the manifest is written.
    case verify
    /// P4: the staging directory is renamed into `versions/`.
    case rename
    /// P5: the inventory row is inserted and the job deleted, in one transaction.
    case commit
}

/// The delete protocol's steps D1 to D3.
nonisolated enum OfflineDeleteStep: CaseIterable, Sendable {
    /// D1: the inventory row and any job for the edition are deleted.
    case commitRow
    /// D2: an unleased version is renamed into `trash/`.
    case detach
    /// D3: the trash item is removed.
    case removeTrash
}

/// Where a crash-injected operation stops. Production always runs `.all`.
nonisolated enum OfflineStepLimit: Equatable, Sendable {
    case all
    case publish(OfflinePublishStep)
    case delete(OfflineDeleteStep)
}

nonisolated enum OfflineStoreOperation: Sendable {
    case publish(jobID: String, pages: [OfflinePageInput], commitGuard: OfflineCommitGuard)
    case delete(OfflineChapterEdition)
}

/// What a reconciliation run did. `discardedVersions` counts roll-forwards that could not complete.
nonisolated struct OfflineReconcileDetails: Equatable, Sendable {
    var restoredJobs = 0
    var rolledForward = 0
    var requeuedJobs = 0
    var discardedVersions = 0
    var removedRows = 0
    var damagedRows = 0
    var removedStagingDirectories = 0
    var removedTrashItems = 0
    var reclaimedVersions = 0
}

/// What a garbage-collection pass removed.
nonisolated struct OfflineCollectionReport: Equatable, Sendable {
    var removedStagingDirectories = 0
    var removedTrashItems = 0
    var reclaimedVersions = 0
}

/// `.deferred` is returned before any change when protected data is unavailable at entry. A
/// filesystem denial later in the run stops the run; the changes already made in that run each
/// had their precondition confirmed (an interrupted attempt requeued, a row whose directory is
/// confirmed absent removed, a manifest confirmed mismatched marked damaged). No version that could
/// be read is deleted or marked.
nonisolated enum OfflineReconcileReport: Equatable, Sendable {
    case deferred
    case completed(OfflineReconcileDetails)
}

extension OfflineChapterStore {
    /// Where a failed attempt or publish goes. Full storage and a locked device wait for those
    /// conditions to clear. A corrupt or missing staged file, a bad manifest and any other
    /// filesystem failure fail the job, so it is not retried without an explicit Retry. Re-queueing
    /// is reserved for crash recovery and stale runtimes.
    nonisolated static func outcome(for error: Error) -> DownloadAttemptOutcome {
        if let fileError = error as? OfflineFileSystemError {
            switch fileError {
            case .noSpace:
                return .waiting(.insufficientStorage)
            case .permissionDenied:
                return .waiting(.protectedDataUnavailable)
            case .notFound, .other:
                return .failed(.fileSystem)
            }
        }
        if error is OfflineManifestError || error is OfflinePublishError || error is DecodingError {
            return .failed(.integrityMismatch)
        }
        return .failed(.fileSystem)
    }
}
