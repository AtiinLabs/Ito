import Foundation
import GRDB
import ito_runner

/// The accepted catalog an admission pass works from: the rows the baseline lists, in source order, with the exact
/// bytes that jobs and the batch freeze. It comes from the observation being committed, or from the stored baseline.
nonisolated struct SubscriptionAcceptedCatalog: Sendable {
    let rows: [CatalogRowEvidence]
    let chapters: [Chapter]
    let entrySnapshot: Data
    let digest: String
    let sourceEpoch: String

    init(observation: CatalogObservation) {
        rows = observation.rows
        chapters = observation.chapters
        entrySnapshot = observation.entrySnapshot
        digest = observation.catalogDigest
        sourceEpoch = observation.fingerprint.sourceEpoch
    }

    /// Reads the catalog back from a stored baseline. Throws when the frozen snapshot is not a readable entry.
    init(record: SubscriptionBaselineRecord) throws {
        let entry = try JSONDecoder().decode(MediaEntry.self, from: record.entrySnapshot)
        chapters = Self.chapters(of: entry)
        rows = chapters.map { CatalogRowEvidence(chapter: $0) }
        entrySnapshot = record.entrySnapshot
        digest = record.catalogDigest
        sourceEpoch = record.sourceEpoch
    }

    static func chapters(of entry: MediaEntry) -> [Chapter] {
        switch entry {
        case .manga(let manga): manga.chapters ?? []
        case .novel(let novel): novel.chapters ?? []
        case .anime: []
        }
    }

    static func title(of entry: MediaEntry) -> String {
        switch entry {
        case .manga(let manga): manga.title
        case .novel(let novel): novel.title
        case .anime(let anime): anime.title
        }
    }
}

/// Which open events one admission pass decides.
nonisolated enum SubscriptionAdmissionTrigger: Sendable {
    /// A check commit: everything that is waiting, under this many positions for the run.
    case check(runCap: Int)
    /// An explicit drain: events that wait for queue or disk room, and undecided ones. No run cap.
    case drain
    /// Exactly these events, reset to undecided by an approval or a backfill. No run cap.
    case events(Set<String>)
}

extension OfflineChapterStore {
    // MARK: - Reading the store

    /// What each exact key of a series has in the store: a verified or damaged copy, or a job (a failed job still
    /// occupies its key). A copy wins over a job.
    nonisolated static func storedStates(
        for media: MediaIdentity,
        in db: Database
    ) throws -> [ScanlatorUTF8: StoredEditionState] {
        let arguments: StatementArguments = [media.pluginId, media.mediaKind.rawValue, media.canonicalMediaId]
        var stored: [ScanlatorUTF8: StoredEditionState] = [:]
        for key in try String.fetchAll(
            db,
            sql: "SELECT chapterKey FROM downloadJob WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: arguments
        ) {
            stored[ScanlatorUTF8(value: key)] = .queued
        }
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT chapterKey, state FROM downloadedChapter
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                """,
            arguments: arguments
        ) {
            let key: String = row["chapterKey"]
            let state: String = row["state"]
            stored[ScanlatorUTF8(value: key)] = state == DownloadedChapterState.verified.rawValue ? .verified : .damaged
        }
        return stored
    }

    /// The admission inputs, read in the transaction that acts on the decisions.
    nonisolated static func admissionContext(
        subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        events: [SubscriptionEventRecord],
        limits: AutomaticDownloadLimits,
        runCapRemaining: Int?,
        in db: Database
    ) throws -> AdmissionContext {
        let media = subscription.media
        let arguments: StatementArguments = [media.pluginId, media.mediaKind.rawValue, media.canonicalMediaId]
        let suppressed = try String.fetchAll(
            db,
            sql: "SELECT chapterKey FROM downloadSuppression WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: arguments
        )
        var installed: [ScanlatorUTF8: InstalledCopyEvidence] = [:]
        let replacementKeys = events.filter { $0.kind == .revisionChanged }.flatMap(\.candidates)
        if !replacementKeys.isEmpty {
            let currentEpoch = try PluginCompletionScope.current(pluginID: media.pluginId, in: db)
            for key in replacementKeys {
                let edition = OfflineChapterEdition(media: media, chapterKey: key)
                guard let copy = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) else { continue }
                installed[ScanlatorUTF8(value: key)] = InstalledCopyEvidence(
                    isVerified: copy.state == .verified,
                    revision: try? installedRevision(copy),
                    sourceEpochIsCurrent: copy.sourceEpoch != nil && copy.sourceEpoch == currentEpoch
                )
            }
        }
        let jobCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadJob") ?? 0
        let automaticOnly = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM downloadJob
                WHERE NOT EXISTS (
                    SELECT 1 FROM downloadJobOwner o WHERE o.jobId = downloadJob.id AND o.ownerKind = 'manual'
                )
                """
        ) ?? 0
        return AdmissionContext(
            subscription: subscription,
            selection: subscription.decodedSelection,
            baselineRows: catalog.rows,
            stored: try storedStates(for: media, in: db),
            suppressed: Set(suppressed.map { ScanlatorUTF8(value: $0) }),
            installed: installed,
            jobCount: jobCount,
            autoOnlyOutstandingJobs: automaticOnly,
            storedBytes: try storedBytes(in: db),
            limits: limits,
            runCapRemaining: runCapRemaining
        )
    }

    /// The bytes of every stored copy, damaged ones included: they occupy storage until deleted.
    nonisolated static func storedBytes(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM downloadedChapter") ?? 0
    }

    // MARK: - Window events

    /// Maintain Next N: derives the window's events from the accepted catalog and the exact read state, supersedes the
    /// ones of an anchor that moved on, and records the new ones through the unique identity.
    nonisolated static func refreshWindowEvents(
        subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        scopeGeneration: Int64,
        now: Date,
        in db: Database,
        into outcome: inout SubscriptionCommitOutcome
    ) throws {
        guard subscription.mode == .maintainNextUnread, let windowSize = subscription.windowSize,
              let selection = subscription.decodedSelection else { return }
        let readState = try SubscriptionLedger.readState(for: subscription.media, in: db)
        let events = SubscriptionWindowPlanner.events(
            rows: catalog.rows,
            selection: selection,
            windowSize: windowSize,
            readState: readState,
            stored: try storedStates(for: subscription.media, in: db)
        )
        let qualifier = SubscriptionWindowPlanner.anchorQualifier(
            SubscriptionWindowPlanner.anchorKey(in: catalog.rows, readState: readState)
        )
        try SubscriptionLedger.supersedeWindowEvents(
            of: subscription.id, exceptQualifier: qualifier, now: now, in: db
        )
        let inserted = try SubscriptionLedger.insert(
            events, for: subscription, observedCatalogDigest: catalog.digest,
            scopeGeneration: scopeGeneration, now: now, in: db
        )
        outcome.createdEventIds += inserted.map(\.id)
        outcome.needsAttentionEventIds += inserted.filter { $0.decision == .needsReview }.map(\.id)
    }

    /// Prunes the terminal events of a rule, keeping the window events of the anchor the catalog and the read state have
    /// now. The anchor is read in the caller's transaction, so what is protected is what the next pass would recompute.
    nonisolated static func pruneTerminalEvents(
        of subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        in db: Database
    ) throws {
        var qualifier: String?
        if subscription.mode == .maintainNextUnread {
            let readState = try SubscriptionLedger.readState(for: subscription.media, in: db)
            qualifier = SubscriptionWindowPlanner.anchorQualifier(
                SubscriptionWindowPlanner.anchorKey(in: catalog.rows, readState: readState)
            )
        }
        try SubscriptionLedger.pruneTerminalEvents(of: subscription.id, protectingWindowQualifier: qualifier, in: db)
    }

    // MARK: - Admission pass

    /// Decides the open events the trigger names, in the order they were raised, and acts on each decision in the
    /// caller's transaction: an enqueue inserts the jobs through the shared core (one automatic batch per pass), a
    /// replacement goes through the replacement core, and every other decision is stored on the event. The context
    /// is updated after each enqueue, so later events see the jobs and the positions already used. Nothing is
    /// admitted while the subscription is not enabled or its selection cannot be read.
    nonisolated static func admit(
        subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        trigger: SubscriptionAdmissionTrigger,
        limits: AutomaticDownloadLimits,
        now: Date,
        in db: Database,
        into outcome: inout SubscriptionCommitOutcome
    ) throws {
        guard subscription.state == .enabled, subscription.decodedSelection != nil else { return }
        let candidates: [SubscriptionEventRecord]
        let runCap: Int?
        switch trigger {
        case .check(let cap):
            candidates = try SubscriptionLedger.events(
                of: subscription.id,
                decisions: [.undecided, .pending, .awaitingEdition, .needsChoice, .locked],
                in: db
            )
            runCap = cap
        case .drain:
            candidates = try SubscriptionLedger.events(of: subscription.id, decisions: [.undecided, .pending], in: db)
                .filter { $0.decision == .undecided || $0.pendingReason == .queueCap || $0.pendingReason == .quota }
            runCap = nil
        case .events(let ids):
            candidates = try SubscriptionLedger.events(of: subscription.id, decisions: [.undecided], in: db)
                .filter { ids.contains($0.id) }
            runCap = nil
        }
        guard !candidates.isEmpty else { return }

        var context = try admissionContext(
            subscription: subscription, catalog: catalog, events: candidates,
            limits: limits, runCapRemaining: runCap, in: db
        )
        var batch = SubscriptionBatchState(catalog: catalog)
        for event in candidates {
            let decision = SubscriptionAdmission.decide(event, context)
            try apply(
                decision, to: event, subscription: subscription, catalog: catalog,
                context: &context, batch: &batch, now: now, in: db, outcome: &outcome
            )
        }
        outcome.pendingCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM subscriptionEvent WHERE subscriptionId = ? AND decision = 'pending'",
            arguments: [subscription.id]
        ) ?? 0
    }

    /// The one automatic batch a pass shares, and the entry its jobs freeze.
    private struct SubscriptionBatchState {
        let catalog: SubscriptionAcceptedCatalog
        var batchId: String?
        var nextSequence = 0
        private var decoded: MediaEntry?
        private var chapterIndex: [ScanlatorUTF8: Int]?

        init(catalog: SubscriptionAcceptedCatalog) { self.catalog = catalog }

        mutating func entry() throws -> MediaEntry {
            if let decoded { return decoded }
            let entry = try JSONDecoder().decode(MediaEntry.self, from: catalog.entrySnapshot)
            decoded = entry
            return entry
        }

        mutating func chapter(forKey key: String) -> Chapter? {
            if chapterIndex == nil {
                var index: [ScanlatorUTF8: Int] = [:]
                for (offset, chapter) in catalog.chapters.enumerated() { index[ScanlatorUTF8(value: chapter.key)] = offset }
                chapterIndex = index
            }
            return chapterIndex?[ScanlatorUTF8(value: key)].map { catalog.chapters[$0] }
        }
    }

    // MARK: - Acting on a decision

    private nonisolated static func apply(
        _ decision: AdmissionDecision,
        to event: SubscriptionEventRecord,
        subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        context: inout AdmissionContext,
        batch: inout SubscriptionBatchState,
        now: Date,
        in db: Database,
        outcome: inout SubscriptionCommitOutcome
    ) throws {
        /// A waiting decision that did not change is not written again.
        func store(
            _ new: SubscriptionDecision,
            pending: SubscriptionPendingReason? = nil,
            review: SubscriptionReviewReason? = nil,
            decided: [String]? = nil
        ) throws {
            let unchanged = event.decision == new && new.isOpen
                && event.pendingReason == (new == .pending ? pending : nil)
                && (new != .needsReview || event.reviewReason == review)
            guard !unchanged else { return }
            try SubscriptionLedger.settle(
                event, as: new, pending: pending, review: review, decidedKeys: decided, now: now, in: db
            )
            if new == .needsChoice || new == .needsReview { outcome.needsAttentionEventIds.append(event.id) }
        }

        switch decision {
        case .enqueue(let keys):
            let owner = DownloadRequestOwner.subscription(
                id: subscription.id, incarnation: subscription.incarnation, eventId: event.id
            )
            if event.kind == .revisionChanged {
                let replaced = try enqueueReplacement(
                    event, key: keys[0], owner: owner, subscription: subscription, catalog: catalog,
                    context: &context, batch: &batch, now: now, in: db, outcome: &outcome
                )
                try store(replaced.decision, decided: replaced.decidedKeys)
                return
            }
            var chapters: [Chapter] = []
            for key in keys {
                guard let chapter = batch.chapter(forKey: key) else { continue }
                chapters.append(chapter)
            }
            let entry = try batch.entry()
            let encoder = JSONEncoder()
            let batchId = batch.batchId ?? UUID().uuidString
            let prepared = PreparedDownloadBatch(
                pluginId: subscription.pluginId,
                mediaKind: subscription.mediaKind,
                canonicalMediaId: subscription.canonicalMediaId,
                entrySnapshot: catalog.entrySnapshot,
                seriesTitle: SubscriptionAcceptedCatalog.title(of: entry),
                provenance: .automatic,
                selection: subscription.selection,
                catalogDigest: catalog.digest,
                chapters: chapters,
                chapterSnapshots: try chapters.map { try encoder.encode($0) },
                batchId: batchId,
                jobIds: chapters.map { _ in UUID().uuidString },
                sourceEpoch: catalog.sourceEpoch,
                sequenceOffset: batch.nextSequence
            )
            let result = try insertBatch(prepared, owner: owner, now: now, in: db)
            if result.outcome.queued > 0 { batch.batchId = batchId }
            batch.nextSequence += chapters.count
            var owned: [String] = []
            var saved: [String] = []
            var attached = 0
            for (chapter, disposition) in zip(chapters, result.dispositions) {
                switch disposition {
                case .inserted: owned.append(chapter.key)
                case .attached: owned.append(chapter.key); attached += 1
                case .alreadyOwned, .repeatedInRequest: owned.append(chapter.key)
                case .alreadySaved: saved.append(chapter.key)
                case .blockedDamaged, .locked, .suppressed: break
                }
            }
            outcome.queuedJobs += result.outcome.queued
            outcome.attachedJobs += attached
            context.apply(enqueued: owned, created: result.outcome.queued)
            if !owned.isEmpty {
                try store(.enqueued, decided: owned + saved)
            } else if !saved.isEmpty {
                try store(.satisfied, decided: saved)
            } else if result.outcome.suppressed > 0 {
                try store(.suppressed)
            } else if result.outcome.blockedDamaged > 0 {
                try store(.blockedDamaged)
            } else {
                try store(.locked)
            }
        case .satisfied(let keys): try store(.satisfied, decided: keys)
        case .pending(let reason): try store(.pending, pending: reason)
        case .awaitingEdition: try store(.awaitingEdition)
        case .needsChoice: try store(.needsChoice)
        case .needsReview(let reason): try store(.needsReview, review: reason)
        case .locked: try store(.locked)
        case .blockedDamaged: try store(.blockedDamaged)
        case .suppressed: try store(.suppressed)
        case .superseded: try store(.superseded)
        case .recorded: try store(.recorded)
        }
    }

    /// An admitted revision change under the rule: the replacement core, with the event as the authorization. Returns
    /// the decision to store on the event.
    private nonisolated static func enqueueReplacement(
        _ event: SubscriptionEventRecord,
        key: String,
        owner: DownloadRequestOwner,
        subscription: SeriesSubscriptionRecord,
        catalog: SubscriptionAcceptedCatalog,
        context: inout AdmissionContext,
        batch: inout SubscriptionBatchState,
        now: Date,
        in db: Database,
        outcome: inout SubscriptionCommitOutcome
    ) throws -> (decision: SubscriptionDecision, decidedKeys: [String]?) {
        let edition = OfflineChapterEdition(media: subscription.media, chapterKey: key)
        guard let chapter = batch.chapter(forKey: key),
              let copy = try DownloadedChapterRecord.filter(edition.predicate).fetchOne(db) else {
            return (.superseded, nil)
        }
        let entry = try batch.entry()
        let result = try insertReplacementJob(
            target: DownloadEnqueueRequest(
                pluginId: subscription.pluginId,
                mediaKind: subscription.mediaKind,
                canonicalMediaId: subscription.canonicalMediaId,
                entry: entry,
                chapter: chapter,
                seriesTitle: SubscriptionAcceptedCatalog.title(of: entry),
                sourceEpoch: catalog.sourceEpoch
            ),
            expectedVersionId: copy.versionId,
            expectedRevision: event.previousRevision,
            authorizationId: event.id,
            provenance: .automatic,
            owner: owner,
            now: now,
            in: db
        )
        switch result {
        case .queued:
            outcome.queuedJobs += 1
            context.apply(enqueued: [key], created: 1)
            return (.enqueued, [key])
        case .alreadyQueued:
            outcome.attachedJobs += 1
            context.apply(enqueued: [key], created: 0)
            return (.enqueued, [key])
        case .alreadyDownloaded, .refused:
            return (.superseded, nil)
        }
    }
}
