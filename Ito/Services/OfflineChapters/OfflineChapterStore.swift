import Foundation
import GRDB
import OSLog
import ito_runner

/// One download attempt's staging directory. Pages are written in order, and each one's size and
/// digest are recorded as it is written. The store publishes the attempt with `publish`.
actor OfflineStagingAttempt {
    nonisolated let jobID: String
    nonisolated let versionId: String
    nonisolated let directory: URL

    private let fileSystem: any OfflineFileSystem
    private var pages: [OfflineManifestPage] = []
    private var isSealed = false

    init(jobID: String, versionId: String, directory: URL, fileSystem: any OfflineFileSystem) {
        self.jobID = jobID
        self.versionId = versionId
        self.directory = directory
        self.fileSystem = fileSystem
    }

    func append(_ input: OfflinePageInput) throws {
        guard !isSealed else { throw OfflineStagingError.sealed }
        let index = pages.count
        let stored: OfflineManifestPage
        switch input.content {
        case .text(let data):
            let name = OfflinePageFileName.make(index: index, fileExtension: "txt")
            try fileSystem.writeFile(data, to: directory.appendingPathComponent(name))
            stored = OfflineManifestPage(
                index: index,
                sourceIndex: input.sourceIndex,
                kind: .text,
                file: name,
                mediaType: "text/plain; charset=utf-8",
                byteCount: Int64(data.count),
                sha256: OfflineDigest.sha256Hex(data),
                description: input.description
            )
        case .image(let data):
            guard let detection = ImageSignature.detect(data) else {
                throw OfflineStagingError.unsupportedImageFormat
            }
            let name = OfflinePageFileName.make(index: index, fileExtension: detection.fileExtension)
            try fileSystem.writeFile(data, to: directory.appendingPathComponent(name))
            stored = OfflineManifestPage(
                index: index,
                sourceIndex: input.sourceIndex,
                kind: .image,
                file: name,
                mediaType: detection.mediaType,
                byteCount: Int64(data.count),
                sha256: OfflineDigest.sha256Hex(data),
                description: input.description
            )
        case .imageFile(let source):
            let streamed = try OfflineDigest.streamedFile(at: source, fileSystem: fileSystem)
            guard let detection = ImageSignature.detect(streamed.head) else {
                throw OfflineStagingError.unsupportedImageFormat
            }
            let name = OfflinePageFileName.make(index: index, fileExtension: detection.fileExtension)
            try fileSystem.moveItem(at: source, to: directory.appendingPathComponent(name))
            stored = OfflineManifestPage(
                index: index,
                sourceIndex: input.sourceIndex,
                kind: .image,
                file: name,
                mediaType: detection.mediaType,
                byteCount: streamed.byteCount,
                sha256: streamed.sha256,
                description: input.description
            )
        }
        pages.append(stored)
    }

    /// Stops further pages. Publishing seals the attempt first.
    func seal() {
        isSealed = true
    }

    /// P3: re-reads every page from disk, checks it against what was recorded, writes the
    /// manifest, and flushes the files and the directory.
    func finalize(edition: OfflineChapterEdition, createdAt: Date) throws -> OfflineStagedVersion {
        guard !pages.isEmpty else { throw OfflineManifestError.emptyPages }
        for page in pages {
            let streamed = try OfflineDigest.streamedFile(
                at: directory.appendingPathComponent(page.file),
                fileSystem: fileSystem
            )
            guard streamed.sha256 == page.sha256, streamed.byteCount == page.byteCount else {
                throw OfflinePublishError.integrityMismatch
            }
        }
        let manifest = OfflineChapterManifest(
            versionId: versionId,
            identity: edition,
            createdAt: createdAt,
            pages: pages
        )
        try manifest.validate(edition: edition, versionId: versionId)
        let data = try manifest.encoded()
        let manifestURL = directory.appendingPathComponent(OfflineChapterManifest.fileName)
        try fileSystem.writeFile(data, to: manifestURL)
        for page in pages {
            try fileSystem.synchronize(directory.appendingPathComponent(page.file))
        }
        try fileSystem.synchronize(manifestURL)
        try fileSystem.synchronize(directory)
        return OfflineStagedVersion(manifest: manifest, manifestData: data)
    }
}

/// Owns every mutation of the offline directory and of the offline tables. Publish, delete and
/// garbage collection run on this actor, so they never interleave their filesystem steps.
actor OfflineChapterStore {
    /// Free space required before an attempt starts.
    nonisolated static let reserveBytes: Int64 = 256 * 1024 * 1024

    nonisolated let root: URL
    /// Shared with the offline image loader. Leases are never persisted.
    nonisolated let leases = OfflineLeaseDirectory()

    private let database: DatabasePool
    nonisolated private let fileSystem: any OfflineFileSystem
    private let protectedData: any ProtectedDataAvailability
    private let clock: @Sendable () -> Date
    /// Set once a run completes. Crash recovery runs at most once per instance after that.
    private var completedReconciliation: OfflineReconcileReport?
    private var reconciliation: Task<OfflineReconcileReport, Never>?
    /// Versions whose attempt this instance is running. Garbage collection and recovery skip them.
    private var liveAttemptVersions: Set<String> = []

    /// - Parameter root: the `OfflineChapters` directory itself.
    init(
        root: URL,
        database: DatabasePool,
        fileSystem: any OfflineFileSystem,
        protectedData: any ProtectedDataAvailability,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.database = database
        self.fileSystem = fileSystem
        self.protectedData = protectedData
        self.clock = clock
    }

    private var isReconciled: Bool { completedReconciliation != nil }

    // MARK: - Layout

    private var versionsDirectory: URL { root.appendingPathComponent("versions", isDirectory: true) }
    private var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var trashDirectory: URL { root.appendingPathComponent("trash", isDirectory: true) }
    private var storeIdentifierMarker: URL { root.appendingPathComponent("store-id") }

    private func versionDirectory(_ versionId: String) -> URL {
        versionsDirectory.appendingPathComponent(versionId, isDirectory: true)
    }

    private func stagingDirectory(_ versionId: String) -> URL {
        stagingRoot.appendingPathComponent(versionId, isDirectory: true)
    }

    // MARK: - Reconciliation

    /// Brings the directory and the tables into agreement. Crash recovery runs at most once per
    /// instance: after a completed run this returns the cached report. Only `.deferred` runs again.
    ///
    /// - Parameter rollForwardGuard: in-memory checks for a fully staged version that is about to
    ///   commit. The source epoch is checked from the database in the same transaction. The default
    ///   refuses: the trust and publication baselines of the crashed attempt do not survive a
    ///   relaunch, so a crash between P4 and P5 requeues the chapter and it is fetched again.
    func reconcile(rollForwardGuard: @escaping OfflineCommitGuard = { _ in false }) async -> OfflineReconcileReport {
        if let completedReconciliation {
            return completedReconciliation
        }
        if let reconciliation {
            return await reconciliation.value
        }
        let task = Task { await self.runReconciliation(rollForwardGuard: rollForwardGuard) }
        reconciliation = task
        let report = await task.value
        reconciliation = nil
        if case .completed = report {
            completedReconciliation = report
        }
        return report
    }

    private func runReconciliation(rollForwardGuard: @escaping OfflineCommitGuard) async -> OfflineReconcileReport {
        guard await protectedData.isProtectedDataAvailable() else { return .deferred }
        do {
            var details = OfflineReconcileDetails()
            try fileSystem.prepareRoot(root)
            try fileSystem.createDirectory(versionsDirectory)
            try fileSystem.createDirectory(stagingRoot)
            try fileSystem.createDirectory(trashDirectory)
            try await bindInstallation(&details)
            try await settleDownloadingJobs(commitGuard: rollForwardGuard, &details)
            try await reconcileInventory(&details)
            var collection = OfflineCollectionReport()
            try await collectGarbage(into: &collection)
            details.removedStagingDirectories = collection.removedStagingDirectories
            details.removedTrashItems = collection.removedTrashItems
            details.reclaimedVersions = collection.reclaimedVersions
            return .completed(details)
        } catch OfflineFileSystemError.permissionDenied {
            return .deferred
        } catch {
            AppLogger.database.error("Offline chapter reconciliation deferred after a database error")
            return .deferred
        }
    }

    /// Removes unreferenced staging, trash and version directories at any time after reconciliation.
    /// Referenced, leased and live versions are never removed.
    func collectGarbage() async throws -> OfflineCollectionReport {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        var report = OfflineCollectionReport()
        try await collectGarbage(into: &report)
        return report
    }

    /// The `downloadStore` row and the marker file must name the same installation. A missing or
    /// different marker means the database came from elsewhere, so every job is paused.
    private func bindInstallation(_ details: inout OfflineReconcileDetails) async throws {
        let markerIdentifier = try readStoreIdentifierMarker()
        let storedIdentifier = try await database.read { db in
            try DownloadStoreRecord.fetchOne(db)?.storeId
        }
        let hasRows = try await database.read { db in
            try DownloadJobRecord.fetchCount(db) + DownloadedChapterRecord.fetchCount(db) > 0
        }
        let now = clock()

        if storedIdentifier == nil, markerIdentifier == nil, !hasRows {
            let identifier = UUID().uuidString
            try await insertStoreRecord(identifier: identifier, now: now)
            try fileSystem.writeFile(Data(identifier.utf8), to: storeIdentifierMarker)
            return
        }
        if let storedIdentifier, storedIdentifier == markerIdentifier {
            return
        }
        if storedIdentifier == nil, let markerIdentifier, !hasRows {
            try await insertStoreRecord(identifier: markerIdentifier, now: now)
            return
        }

        let identifier = storedIdentifier ?? UUID().uuidString
        if storedIdentifier == nil {
            try await insertStoreRecord(identifier: identifier, now: now)
        }
        details.restoredJobs = try await pauseJobsAfterRestore(now: now)
        try fileSystem.writeFile(Data(identifier.utf8), to: storeIdentifierMarker)
    }

    private func readStoreIdentifierMarker() throws -> String? {
        do {
            let data = try fileSystem.readData(at: storeIdentifierMarker)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineFileSystemError.permissionDenied
        } catch {
            return nil
        }
    }

    private func insertStoreRecord(identifier: String, now: Date) async throws {
        try await database.write { db in
            try DownloadStoreRecord(storeId: identifier, createdAt: now).insert(db)
        }
    }

    private func pauseJobsAfterRestore(now: Date) async throws -> Int {
        try await database.write { db -> Int in
            let jobs = try DownloadJobRecord.fetchAll(db)
            for var job in jobs {
                job.state = .waiting
                job.waitingReason = .restoredPendingReview
                job.failureReason = nil
                job.stagingVersionId = nil
                job.updatedAt = now
                try job.update(db)
            }
            return jobs.count
        }
    }

    /// Jobs left `downloading` by a crash. A version that is fully on disk and valid rolls forward
    /// through P5. Anything else is discarded and the job goes back to the queue. A roll-forward
    /// that cannot complete discards its version and moves the job to the outcome its error implies.
    private func settleDownloadingJobs(
        commitGuard: @escaping OfflineCommitGuard,
        _ details: inout OfflineReconcileDetails
    ) async throws {
        let jobs = try await database.read { db in
            try DownloadJobRecord
                .filter(Column("state") == DownloadJobState.downloading.rawValue)
                .fetchAll(db)
        }
        for job in jobs {
            guard let versionId = job.stagingVersionId, !liveAttemptVersions.contains(versionId) else {
                continue
            }
            do {
                if try fileSystem.entryExists(at: versionDirectory(versionId)),
                   let staged = try verifiedPublishedVersion(versionId: versionId, edition: job.edition) {
                    let outcome = try await commitPublish(
                        job: job,
                        versionId: versionId,
                        staged: staged,
                        commitGuard: commitGuard
                    )
                    switch outcome {
                    case .published:
                        details.rolledForward += 1
                    case .refused(.staleRuntime):
                        details.requeuedJobs += 1
                    default:
                        break
                    }
                    continue
                }
                discardArtifacts(versionId: versionId)
                try await setOutcome(jobID: job.id, versionId: versionId, outcome: .queued)
                details.requeuedJobs += 1
            } catch OfflineFileSystemError.permissionDenied {
                throw OfflineFileSystemError.permissionDenied
            } catch let error as DatabaseError {
                throw error
            } catch {
                discardArtifacts(versionId: versionId)
                try await setOutcome(jobID: job.id, versionId: versionId, outcome: Self.outcome(for: error))
                details.discardedVersions += 1
            }
        }
    }

    /// Checks a version directory that has no inventory row yet, for the roll-forward path. Returns
    /// nil for anything invalid. Permission errors propagate so nothing is decided on a locked device.
    private func verifiedPublishedVersion(
        versionId: String,
        edition: OfflineChapterEdition
    ) throws -> OfflineStagedVersion? {
        let directory = versionDirectory(versionId)
        let manifestURL = directory.appendingPathComponent(OfflineChapterManifest.fileName)
        let data: Data
        do {
            data = try fileSystem.readData(at: manifestURL)
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineFileSystemError.permissionDenied
        } catch {
            return nil
        }
        guard let manifest = try? OfflineChapterManifest.decode(data) else { return nil }
        do {
            try manifest.validate(edition: edition, versionId: versionId)
        } catch {
            return nil
        }
        for page in manifest.pages {
            let streamed: OfflineStreamedFile
            do {
                streamed = try OfflineDigest.streamedFile(
                    at: directory.appendingPathComponent(page.file),
                    fileSystem: fileSystem
                )
            } catch OfflineFileSystemError.permissionDenied {
                throw OfflineFileSystemError.permissionDenied
            } catch {
                return nil
            }
            guard streamed.sha256 == page.sha256, streamed.byteCount == page.byteCount else { return nil }
        }
        return OfflineStagedVersion(manifest: manifest, manifestData: data)
    }

    /// Checks every inventory row against its version directory. A missing directory removes the
    /// row (restored or deleted device data), and a bad manifest marks the copy damaged.
    private func reconcileInventory(_ details: inout OfflineReconcileDetails) async throws {
        let rows = try await database.read { db in
            try DownloadedChapterRecord.fetchAll(db)
        }
        for row in rows {
            guard try fileSystem.entryExists(at: versionDirectory(row.versionId)) else {
                try await database.write { db in
                    _ = try DownloadedChapterRecord
                        .filter(Column("versionId") == row.versionId)
                        .deleteAll(db)
                }
                details.removedRows += 1
                continue
            }
            guard row.state == .verified else { continue }
            if case .damaged(let reason) = try inspectManifest(of: row) {
                try await markDamaged(versionId: row.versionId, reason: reason)
                details.damagedRows += 1
            }
        }
    }

    /// Removes staging and trash entries and every version no row, job, lease or live attempt
    /// references. Live attempts' staging directories are never touched.
    private func collectGarbage(into report: inout OfflineCollectionReport) async throws {
        let referenced = try await database.read { db -> Set<String> in
            let rows = try String.fetchAll(db, sql: "SELECT versionId FROM downloadedChapter")
            let staged = try String.fetchAll(
                db,
                sql: "SELECT stagingVersionId FROM downloadJob WHERE stagingVersionId IS NOT NULL"
            )
            return Set(rows + staged)
        }
        let live = liveAttemptVersions

        for url in try fileSystem.contentsOfDirectory(stagingRoot) where !live.contains(url.lastPathComponent) {
            if (try? fileSystem.removeItem(at: url)) != nil {
                report.removedStagingDirectories += 1
            }
        }
        for url in try fileSystem.contentsOfDirectory(trashDirectory) {
            if (try? fileSystem.removeItem(at: url)) != nil {
                report.removedTrashItems += 1
            }
        }

        let leased = leases.leasedVersionIDs()
        for url in try fileSystem.contentsOfDirectory(versionsDirectory) {
            let versionId = url.lastPathComponent
            guard !referenced.contains(versionId), !leased.contains(versionId), !live.contains(versionId) else {
                continue
            }
            if let trashed = detachToTrash(versionId) {
                try? fileSystem.removeItem(at: trashed)
                report.reclaimedVersions += 1
            }
        }
    }

    // MARK: - Queue

    /// P0: queues one chapter. Refuses paywalled chapters, unsupported kinds and requests with no
    /// captured source epoch. A verified copy or an existing job for the edition wins over a new job.
    func enqueue(_ request: DownloadEnqueueRequest) async throws -> DownloadEnqueueOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        guard request.mediaKind == .manga || request.mediaKind == .novel else {
            return .refused(.unsupportedKind)
        }
        guard request.chapter.paywalled != true else { return .refused(.paywalled) }
        guard let sourceEpoch = request.sourceEpoch else { return .refused(.unavailable) }

        let edition = request.edition
        let entrySnapshot = try JSONEncoder().encode(request.entry)
        let chapterSnapshot = try JSONEncoder().encode(request.chapter)
        let seriesTitle = request.seriesTitle
        let now = clock()
        let identifier = UUID().uuidString
        return try await database.write { db -> DownloadEnqueueOutcome in
            if let existing = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) {
                return existing.state == .verified ? .alreadyDownloaded : .refused(.unavailable)
            }
            if try DownloadJobRecord.filter(edition.predicate).fetchCount(db) > 0 {
                return .alreadyQueued
            }
            try DownloadJobRecord(
                id: identifier,
                pluginId: edition.pluginId,
                mediaKind: edition.mediaKind,
                canonicalMediaId: edition.canonicalMediaId,
                chapterKey: edition.chapterKey,
                authorityScope: edition.authorityScope,
                entrySnapshot: entrySnapshot,
                chapterSnapshot: chapterSnapshot,
                seriesTitle: seriesTitle,
                sourceEpoch: sourceEpoch,
                state: .queued,
                waitingReason: nil,
                failureReason: nil,
                stagingVersionId: nil,
                attemptCount: 0,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            return .queued
        }
    }

    /// Stops a job before commit. An attempt that is running is cancelled by its caller; its staging
    /// directory is removed here, and its late commit is refused because the job is gone.
    func cancel(jobID: String) async throws {
        let removed = try await database.write { db -> DownloadJobRecord? in
            guard let job = try DownloadJobRecord.fetchOne(db, key: jobID) else { return nil }
            _ = try DownloadJobRecord.deleteOne(db, key: jobID)
            return job
        }
        if let versionId = removed?.stagingVersionId {
            liveAttemptVersions.remove(versionId)
            try? fileSystem.removeItem(at: stagingDirectory(versionId))
        }
    }

    /// Re-queues a failed or waiting job and re-freezes the source epoch the caller now reads.
    func retry(jobID: String, currentEpoch: String) async throws {
        let now = clock()
        try await database.write { db in
            guard var job = try DownloadJobRecord.fetchOne(db, key: jobID) else {
                throw OfflineStoreError.jobUnavailable
            }
            switch job.state {
            case .failed, .waiting:
                break
            case .queued:
                return
            case .downloading:
                throw OfflineStoreError.jobUnavailable
            }
            job.state = .queued
            job.waitingReason = nil
            job.failureReason = nil
            job.sourceEpoch = currentEpoch
            job.updatedAt = now
            try job.update(db)
        }
    }

    /// Pauses a queued job, or changes a waiting job's reason. A waiting job whose reason needs an
    /// explicit Retry keeps that reason. Downloading, failed and missing jobs are left alone.
    func setWaiting(jobID: String, reason: DownloadWaitingReason) async throws {
        let now = clock()
        try await database.write { db in
            guard var job = try DownloadJobRecord.fetchOne(db, key: jobID),
                  job.state == .queued || job.state == .waiting else { return }
            if job.state == .waiting, job.waitingReason?.requiresRetry == true { return }
            job.state = .waiting
            job.waitingReason = reason
            job.updatedAt = now
            try job.update(db)
        }
    }

    /// Re-queues waiting jobs whose reason has cleared. Reasons that need a user Retry are never
    /// cleared here, even when listed.
    func readmitWaiting(_ reasons: Set<DownloadWaitingReason>) async throws {
        let clearable = reasons.subtracting(DownloadWaitingReason.requiringRetry)
        guard !clearable.isEmpty else { return }
        let now = clock()
        try await database.write { db in
            let waiting = try DownloadJobRecord
                .filter(Column("state") == DownloadJobState.waiting.rawValue)
                .fetchAll(db)
            for var job in waiting where job.waitingReason.map({ clearable.contains($0) }) == true {
                job.state = .queued
                job.waitingReason = nil
                job.updatedAt = now
                try job.update(db)
            }
        }
    }

    /// Every job in queue order (oldest first).
    func jobs() async throws -> [DownloadJobRecord] {
        try await database.read { db in
            try DownloadJobRecord.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    func job(id: String) async throws -> DownloadJobRecord? {
        try await database.read { db in
            try DownloadJobRecord.fetchOne(db, key: id)
        }
    }

    /// The source's current completion epoch, or nil when it has no scope yet. A read: the pre-attempt
    /// check compares it with the job's frozen epoch, and the commit checks it again in its transaction.
    func currentSourceEpoch(pluginId: String) async throws -> String? {
        try await database.read { db in
            try PluginCompletionScope.current(pluginID: pluginId, in: db)
        }
    }

    /// Removes the edition's inventory row and job, then the version's bytes unless a lease holds
    /// them. Leased bytes are reclaimed when the last lease is released.
    func delete(_ edition: OfflineChapterEdition) async throws {
        _ = try await perform(.delete(edition), through: .all)
    }

    // MARK: - Publish

    /// P3 to P5 for a finished attempt. The caller has streamed the pages into `attempt`.
    func publish(
        _ attempt: OfflineStagingAttempt,
        commitGuard: @escaping OfflineCommitGuard
    ) async throws -> OfflinePublishOutcome {
        guard let outcome = try await runPublish(attempt, commitGuard: commitGuard, through: .all) else {
            preconditionFailure("A publish without a step limit always reaches an outcome")
        }
        return outcome
    }

    /// P1 (`beginAttempt`) through P5 for a job, stopping after `limit`. Production uses `.all`.
    /// Crash tests use it to stop after a step and then drop the store without cleanup.
    func perform(_ operation: OfflineStoreOperation, through limit: OfflineStepLimit) async throws -> OfflinePublishOutcome? {
        switch operation {
        case .publish(let jobID, let pages, let commitGuard):
            let attempt = try await beginAttempt(jobID: jobID)
            if limit == .publish(.stagingIntent) { return nil }
            for page in pages {
                try await attempt.append(page)
            }
            if limit == .publish(.stream) { return nil }
            return try await runPublish(attempt, commitGuard: commitGuard, through: limit)
        case .delete(let edition):
            try await runDelete(edition, through: limit)
            return nil
        }
    }

    /// P1: admits a queued job, reserves a staging version and creates its staging directory. Only
    /// a queued job starts; the check happens before any admission blocker. A blocked attempt
    /// leaves the job waiting with the reason and throws `OfflineStoreError.blocked`.
    func beginAttempt(jobID: String) async throws -> OfflineStagingAttempt {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let current = try await database.read { db in
            try DownloadJobRecord.fetchOne(db, key: jobID)
        }
        guard let current, current.state == .queued else { throw OfflineStoreError.jobUnavailable }

        if let blocker = await admissionBlocker() {
            try await setWaiting(jobID: jobID, reason: blocker)
            throw OfflineStoreError.blocked(blocker)
        }

        let versionId = UUID().uuidString
        let now = clock()
        try await database.write { db in
            guard var job = try DownloadJobRecord.fetchOne(db, key: jobID), job.state == .queued else {
                throw OfflineStoreError.jobUnavailable
            }
            job.state = .downloading
            job.waitingReason = nil
            job.stagingVersionId = versionId
            job.attemptCount += 1
            job.updatedAt = now
            try job.update(db)
        }
        liveAttemptVersions.insert(versionId)

        do {
            try fileSystem.createDirectory(stagingDirectory(versionId))
        } catch {
            liveAttemptVersions.remove(versionId)
            try await setOutcome(jobID: jobID, versionId: versionId, outcome: Self.outcome(for: error))
            throw error
        }
        return OfflineStagingAttempt(
            jobID: jobID,
            versionId: versionId,
            directory: stagingDirectory(versionId),
            fileSystem: fileSystem
        )
    }

    /// Ends an attempt that will not publish. Ownership is checked before any file is touched: the
    /// attempt must be live here. If the job still references its version, the version is discarded
    /// and the job moves to `outcome`. If the job was cancelled or deleted meanwhile, an unreferenced
    /// version is discarded; a published one is never touched.
    func abandonAttempt(jobID: String, versionId: String, outcome: DownloadAttemptOutcome) async throws {
        guard liveAttemptVersions.contains(versionId) else { return }
        let job = try await database.read { db in
            try DownloadJobRecord.fetchOne(db, key: jobID)
        }
        guard job?.stagingVersionId == versionId else {
            // Cancel or Delete ran while `beginAttempt` was still creating the staging directory, so its
            // cleanup could not see it. Nothing references the version now; release it here.
            let referenced = try await database.read { db in
                try Self.isReferenced(versionId: versionId, in: db)
            }
            if !referenced {
                liveAttemptVersions.remove(versionId)
                discardArtifacts(versionId: versionId)
            }
            return
        }
        liveAttemptVersions.remove(versionId)
        discardArtifacts(versionId: versionId)
        try await setOutcome(jobID: jobID, versionId: versionId, outcome: outcome)
    }

    private func admissionBlocker() async -> DownloadWaitingReason? {
        guard await protectedData.isProtectedDataAvailable() else { return .protectedDataUnavailable }
        do {
            let capacity = try fileSystem.availableCapacity(at: root)
            return capacity >= Self.reserveBytes ? nil : .insufficientStorage
        } catch OfflineFileSystemError.permissionDenied {
            return .protectedDataUnavailable
        } catch {
            return .insufficientStorage
        }
    }

    private func runPublish(
        _ attempt: OfflineStagingAttempt,
        commitGuard: @escaping OfflineCommitGuard,
        through limit: OfflineStepLimit
    ) async throws -> OfflinePublishOutcome? {
        let versionId = attempt.versionId
        defer { liveAttemptVersions.remove(versionId) }
        guard let job = try await database.read({ db in
            try DownloadJobRecord.filter(Column("stagingVersionId") == versionId).fetchOne(db)
        }) else {
            try? fileSystem.removeItem(at: attempt.directory)
            return .refused(.jobGone)
        }

        let staged: OfflineStagedVersion
        do {
            await attempt.seal()
            staged = try await attempt.finalize(edition: job.edition, createdAt: clock())
        } catch {
            return try await discardPublish(job: job, versionId: versionId, error: error)
        }
        if limit == .publish(.verify) { return nil }

        do {
            try fileSystem.moveItem(at: attempt.directory, to: versionDirectory(versionId))
            try fileSystem.synchronize(versionsDirectory)
        } catch {
            return try await discardPublish(job: job, versionId: versionId, error: error)
        }
        if limit == .publish(.rename) { return nil }

        do {
            return try await commitPublish(job: job, versionId: versionId, staged: staged, commitGuard: commitGuard)
        } catch let error as DatabaseError {
            // The commit rolled back, so no row references the version. The job is settled first and
            // the version discarded only after that write lands: if it fails too, the job keeps its
            // staging intent, and the next launch's reconciliation discards the version and requeues it,
            // as for a crash at this step. A full disk waits for space: downloads are what fill it.
            let outcome: DownloadAttemptOutcome = error.resultCode == .SQLITE_FULL
                ? .waiting(.insufficientStorage)
                : Self.outcome(for: error)
            try await setOutcome(jobID: job.id, versionId: versionId, outcome: outcome)
            let referenced = try await database.read { db in
                try Self.isReferenced(versionId: versionId, in: db)
            }
            if !referenced {
                discardArtifacts(versionId: versionId)
            }
            return .discarded(outcome)
        } catch {
            // Anything else failed inside the rolled-back commit (an undecodable snapshot, an
            // unreadable source scope), so no row references the version: discard it and record
            // the outcome now instead of leaving the job downloading until the next launch.
            return try await discardPublish(job: job, versionId: versionId, error: error)
        }
    }

    private func commitPublish(
        job: DownloadJobRecord,
        versionId: String,
        staged: OfflineStagedVersion,
        commitGuard: @escaping OfflineCommitGuard
    ) async throws -> OfflinePublishOutcome {
        let now = clock()
        let manifest = staged.manifest
        let manifestSHA256 = OfflineDigest.sha256Hex(staged.manifestData)
        let jobID = job.id
        let decision = try await database.write { db in
            try Self.commitVerifiedEdition(
                db,
                jobID: jobID,
                versionId: versionId,
                manifest: manifest,
                manifestSHA256: manifestSHA256,
                commitGuard: commitGuard,
                now: now
            )
        }
        // Decided inside the transaction: a version that a row references is never trashed.
        if case .refused = decision.outcome, !decision.versionIsReferenced,
           let trashed = detachToTrash(versionId) {
            try? fileSystem.removeItem(at: trashed)
        }
        return decision.outcome
    }

    /// P5: inserts the inventory row and deletes the job in one transaction. The source epoch is
    /// read from `pluginCompletionScope` here, and must equal the epoch frozen on the job.
    nonisolated private static func commitVerifiedEdition(
        _ db: Database,
        jobID: String,
        versionId: String,
        manifest: OfflineChapterManifest,
        manifestSHA256: String,
        commitGuard: OfflineCommitGuard,
        now: Date
    ) throws -> OfflineCommitDecision {
        guard var job = try DownloadJobRecord.fetchOne(db, key: jobID),
              job.stagingVersionId == versionId else {
            return try refusal(.jobGone, versionId: versionId, in: db)
        }
        if try DownloadedChapterRecord.filter(job.edition.predicate).fetchCount(db) > 0 {
            _ = try DownloadJobRecord.deleteOne(db, key: jobID)
            return try refusal(.alreadyVerified, versionId: versionId, in: db)
        }
        let currentEpoch = try PluginCompletionScope.current(pluginID: job.pluginId, in: db)
        guard job.sourceEpoch != nil, currentEpoch == job.sourceEpoch else {
            // The source's settings or credentials changed: the user decides whether to fetch again.
            job.state = .waiting
            job.waitingReason = .sourceConfigurationChanged
            job.stagingVersionId = nil
            job.updatedAt = now
            try job.update(db)
            return try refusal(.configurationChanged, versionId: versionId, in: db)
        }
        guard commitGuard(job) else {
            // The plugin or its trust changed under the attempt. Nothing the user chose changed, so
            // the chapter is fetched again by a fresh runtime under the current trust.
            job.state = .queued
            job.waitingReason = nil
            job.stagingVersionId = nil
            job.updatedAt = now
            try job.update(db)
            return try refusal(.staleRuntime, versionId: versionId, in: db)
        }
        let snapshot = try inventorySnapshot(of: job.chapterSnapshot)
        try DownloadedChapterRecord(
            pluginId: job.pluginId,
            mediaKind: job.mediaKind,
            canonicalMediaId: job.canonicalMediaId,
            chapterKey: job.chapterKey,
            authorityScope: job.authorityScope,
            versionId: versionId,
            state: .verified,
            damageReason: nil,
            contentKind: manifest.contentKind,
            pageCount: manifest.pages.count,
            byteCount: manifest.totalBytes,
            manifestFormatVersion: manifest.formatVersion,
            manifestSHA256: manifestSHA256,
            chapterSnapshot: snapshot,
            seriesTitle: job.seriesTitle,
            sourceEpoch: job.sourceEpoch,
            verifiedAt: now
        ).insert(db)
        _ = try DownloadJobRecord.deleteOne(db, key: jobID)
        return OfflineCommitDecision(outcome: .published(versionId: versionId), versionIsReferenced: true)
    }

    nonisolated private static func refusal(
        _ reason: OfflinePublishRefusal,
        versionId: String,
        in db: Database
    ) throws -> OfflineCommitDecision {
        OfflineCommitDecision(
            outcome: .refused(reason),
            versionIsReferenced: try isReferenced(versionId: versionId, in: db)
        )
    }

    /// The inventory copy of a chapter: `url` and `paywalled` are dropped, as the queue's copy
    /// needs them only to fetch pages.
    nonisolated private static func inventorySnapshot(of chapterSnapshot: Data) throws -> Data {
        var chapter = try JSONDecoder().decode(Chapter.self, from: chapterSnapshot)
        chapter.url = nil
        chapter.paywalled = nil
        return try JSONEncoder().encode(chapter)
    }

    private func discardPublish(
        job: DownloadJobRecord,
        versionId: String,
        error: Error
    ) async throws -> OfflinePublishOutcome {
        let outcome = Self.outcome(for: error)
        discardArtifacts(versionId: versionId)
        try await setOutcome(jobID: job.id, versionId: versionId, outcome: outcome)
        return .discarded(outcome)
    }

    /// Moves the job to `outcome` only while it still references `versionId`.
    private func setOutcome(jobID: String, versionId: String, outcome: DownloadAttemptOutcome) async throws {
        let now = clock()
        try await database.write { db in
            guard var job = try DownloadJobRecord.fetchOne(db, key: jobID),
                  job.stagingVersionId == versionId else { return }
            Self.apply(outcome, to: &job, now: now)
            try job.update(db)
        }
    }

    nonisolated private static func apply(_ outcome: DownloadAttemptOutcome, to job: inout DownloadJobRecord, now: Date) {
        job.stagingVersionId = nil
        job.updatedAt = now
        switch outcome {
        case .queued:
            job.state = .queued
            job.waitingReason = nil
            job.failureReason = nil
        case .waiting(let reason):
            job.state = .waiting
            job.waitingReason = reason
            job.failureReason = nil
        case .failed(let reason):
            job.state = .failed
            job.waitingReason = nil
            job.failureReason = reason
        }
    }

    /// Removes a version's staging directory and, if it was already published without a row, its
    /// version directory. Best effort: a failure here leaves garbage that collection removes.
    private func discardArtifacts(versionId: String) {
        try? fileSystem.removeItem(at: stagingDirectory(versionId))
        if let trashed = detachToTrash(versionId) {
            try? fileSystem.removeItem(at: trashed)
        }
    }

    /// Renames `versions/<id>` into `trash/`. Returns nil when nothing was moved: the version is
    /// absent, leased, or the rename failed.
    private func detachToTrash(_ versionId: String) -> URL? {
        guard !leases.isLeased(versionId: versionId) else { return nil }
        let destination = trashDirectory.appendingPathComponent(
            "\(versionId).\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileSystem.moveItem(at: versionDirectory(versionId), to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - Delete

    nonisolated private struct RemovedEdition: Sendable {
        let versionId: String?
        let stagingVersionId: String?
    }

    private func runDelete(_ edition: OfflineChapterEdition, through limit: OfflineStepLimit) async throws {
        let removed = try await database.write { db -> RemovedEdition in
            let row = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db)
            if row != nil {
                try DownloadedChapterRecord.filter(edition.predicate).deleteAll(db)
            }
            let job = try DownloadJobRecord.filter(edition.predicate).fetchOne(db)
            if job != nil {
                try DownloadJobRecord.filter(edition.predicate).deleteAll(db)
            }
            return RemovedEdition(versionId: row?.versionId, stagingVersionId: job?.stagingVersionId)
        }
        if limit == .delete(.commitRow) { return }

        if let stagingVersionId = removed.stagingVersionId {
            liveAttemptVersions.remove(stagingVersionId)
            try? fileSystem.removeItem(at: stagingDirectory(stagingVersionId))
        }
        var trashed: URL?
        if let versionId = removed.versionId {
            trashed = detachToTrash(versionId)
        }
        if limit == .delete(.detach) { return }

        if let trashed {
            try? fileSystem.removeItem(at: trashed)
        }
    }

    /// Runs after a lease is released, and at collection. Removes the version when nothing
    /// references it any more. Called by `OfflineChapterLease`.
    func reclaimIfUnreferenced(versionId: String) async {
        guard !leases.isLeased(versionId: versionId), !liveAttemptVersions.contains(versionId) else { return }
        let referenced = (try? await database.read { db in
            try Self.isReferenced(versionId: versionId, in: db)
        }) ?? true
        guard !referenced else { return }
        if let trashed = detachToTrash(versionId) {
            try? fileSystem.removeItem(at: trashed)
        }
    }

    nonisolated private static func isReferenced(versionId: String, in db: Database) throws -> Bool {
        try DownloadedChapterRecord.filter(Column("versionId") == versionId).fetchCount(db) > 0
            || DownloadJobRecord.filter(Column("stagingVersionId") == versionId).fetchCount(db) > 0
    }

    // MARK: - Reads and leases

    /// The inventory row for the edition, only when it is verified.
    func verifiedEdition(for edition: OfflineChapterEdition) async throws -> DownloadedChapterRecord? {
        try await database.read { db in
            try DownloadedChapterRecord
                .filter(edition.predicate && Column("state") == DownloadedChapterState.verified.rawValue)
                .fetchOne(db)
        }
    }

    /// The verified copies of one media item, ordered by chapter key. Damaged copies are left out.
    func verifiedChapters(
        pluginId: String,
        mediaKind: MediaKind,
        canonicalMediaId: String
    ) async throws -> [DownloadedChapterRecord] {
        try await database.read { db in
            try DownloadedChapterRecord
                .filter(
                    Column("pluginId") == pluginId
                        && Column("mediaKind") == mediaKind.rawValue
                        && Column("canonicalMediaId") == canonicalMediaId
                        && Column("state") == DownloadedChapterState.verified.rawValue
                )
                .order(Column("chapterKey"))
                .fetchAll(db)
        }
    }

    /// Checks that the next asset can be written above the reserve. Called before every asset, so
    /// an attempt stops before more bytes are written once the volume fills or protected data locks.
    func ensureCapacityForNextAsset() async throws {
        guard await protectedData.isProtectedDataAvailable() else {
            throw OfflineStoreError.blocked(.protectedDataUnavailable)
        }
        do {
            let capacity = try fileSystem.availableCapacity(at: root)
            guard capacity >= Self.reserveBytes else {
                throw OfflineStoreError.blocked(.insufficientStorage)
            }
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineStoreError.blocked(.protectedDataUnavailable)
        } catch let error as OfflineStoreError {
            throw error
        } catch {
            throw OfflineStoreError.blocked(.insufficientStorage)
        }
    }

    /// Reads one page of a leased version and checks it against the manifest before returning any
    /// byte. A permission error means a locked device, so the copy is left alone. A missing or
    /// altered page marks the copy damaged; the mark is scheduled, because readers call this on
    /// their own threads.
    nonisolated func readVerifiedPage(_ page: OfflineLeasedPage) throws -> Data {
        let data: Data
        do {
            data = try fileSystem.readData(at: page.fileURL)
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineStoreError.protectedDataUnavailable
        } catch OfflineFileSystemError.notFound {
            scheduleDamageMark(versionId: page.versionId, reason: .pageMismatch)
            throw OfflineStoreError.damaged(.pageMismatch)
        } catch {
            throw OfflineStoreError.versionUnavailable
        }
        guard Int64(data.count) == page.page.byteCount,
              OfflineDigest.sha256Hex(data) == page.page.sha256 else {
            scheduleDamageMark(versionId: page.versionId, reason: .pageMismatch)
            throw OfflineStoreError.damaged(.pageMismatch)
        }
        return data
    }

    nonisolated private func scheduleDamageMark(versionId: String, reason: DamageReason) {
        Task { [self] in
            try? await self.markDamaged(versionId: versionId, reason: reason)
        }
    }

    /// Opens a lease on a verified copy. Reads from the lease need no database access, so a Delete
    /// that lands later does not affect the bytes this lease can read.
    func openLease(edition: OfflineChapterEdition) async throws -> OfflineChapterLease {
        guard await protectedData.isProtectedDataAvailable() else {
            throw OfflineStoreError.protectedDataUnavailable
        }
        let row = try await database.read { db in
            try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db)
        }
        guard let row else { throw OfflineStoreError.notVerified }
        if row.state == .damaged {
            throw OfflineStoreError.damaged(row.damageReason ?? .manifestUnreadable)
        }

        let directory = versionDirectory(row.versionId)
        let exists = try Self.guardingProtectedData { try fileSystem.entryExists(at: directory) }
        guard exists else { throw OfflineStoreError.versionUnavailable }

        switch try Self.guardingProtectedData({ try inspectManifest(of: row) }) {
        case .damaged(let reason):
            try await markDamaged(versionId: row.versionId, reason: reason)
            throw OfflineStoreError.damaged(reason)
        case .valid(let manifest):
            let token = UUID()
            leases.register(
                token: token,
                versionId: row.versionId,
                versionDirectory: directory,
                manifest: manifest
            )
            return OfflineChapterLease(
                token: token,
                versionId: row.versionId,
                edition: edition,
                manifest: manifest,
                directory: leases,
                store: self
            )
        }
    }

    /// Marks a copy damaged, but only while the row still references that version.
    func markDamaged(versionId: String, reason: DamageReason) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE downloadedChapter SET state = ?, damageReason = ? WHERE versionId = ? AND state = ?",
                arguments: [
                    DownloadedChapterState.damaged.rawValue,
                    reason.rawValue,
                    versionId,
                    DownloadedChapterState.verified.rawValue
                ]
            )
        }
    }

    nonisolated private enum ManifestInspection {
        case valid(OfflineChapterManifest)
        case damaged(DamageReason)
    }

    /// Reads a row's manifest and checks its digest and identity. Permission errors propagate, so
    /// a locked device never marks a copy damaged.
    private func inspectManifest(of row: DownloadedChapterRecord) throws -> ManifestInspection {
        let manifestURL = versionDirectory(row.versionId).appendingPathComponent(OfflineChapterManifest.fileName)
        let data: Data
        do {
            data = try fileSystem.readData(at: manifestURL)
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineFileSystemError.permissionDenied
        } catch {
            return .damaged(.manifestUnreadable)
        }
        guard OfflineDigest.sha256Hex(data) == row.manifestSHA256 else {
            return .damaged(.manifestMismatch)
        }
        do {
            let manifest = try OfflineChapterManifest.decode(data)
            try manifest.validate(edition: row.edition, versionId: row.versionId)
            return .valid(manifest)
        } catch {
            return .damaged(.manifestUnreadable)
        }
    }

    /// Maps a permission failure to the store's protected-data error.
    nonisolated private static func guardingProtectedData<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch OfflineFileSystemError.permissionDenied {
            throw OfflineStoreError.protectedDataUnavailable
        }
    }
}

/// The result of P5: the outcome, and whether the version is still referenced afterwards.
nonisolated private struct OfflineCommitDecision: Sendable {
    let outcome: OfflinePublishOutcome
    let versionIsReferenced: Bool
}
