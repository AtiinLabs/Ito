import Foundation
import GRDB
import ito_runner

/// The entry points of automatic downloads. Every call needs a reconciled store (otherwise it throws
/// `reconciliationPending` and writes nothing) and runs in one write transaction, so a crash leaves either all of
/// it or none: an observation's baseline, events, owners and jobs commit together, and a replay is idempotent.
extension OfflineChapterStore {
    // MARK: - Lifecycle

    /// Creates the rule, waiting for its first baseline: no event and no job exists yet. A disabled rule is enabled
    /// again as a new incarnation with the new configuration. The rule is stored only while the source epoch it was
    /// reviewed under is current, the series is in the Library and the selection encodes.
    func enableSubscription(_ request: SubscriptionEnableRequest) async throws -> SubscriptionEnableOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let media = request.media
        guard media.mediaKind == .manga || media.mediaKind == .novel else { return .refused(.unsupportedKind) }
        let configuration = request.configuration
        guard configuration.isValid, let selection = try? configuration.selection.storageData() else {
            return .refused(.invalidConfiguration)
        }
        let now = clock()
        return try await database.write { db -> SubscriptionEnableOutcome in
            guard try PluginCompletionScope.current(pluginID: media.pluginId, in: db) == request.reviewedSourceEpoch else {
                return .refused(.sourceChanged)
            }
            guard try Self.libraryItemExists(for: media, in: db) else { return .refused(.seriesNotSaved) }
            if var existing = try SeriesSubscriptionRecord.forMedia(media).fetchOne(db) {
                guard existing.state == .disabled else { return .alreadyExists(id: existing.id) }
                try SubscriptionLedger.discardEvidence(of: existing.id, now: now, in: db)
                existing.apply(configuration, selection: selection)
                existing.state = .enabled
                existing.pauseReason = nil
                existing.incarnation += 1
                existing.configGeneration += 1
                existing.lastAttemptAt = nil
                existing.lastAttemptOutcome = nil
                existing.lastSuccessAt = nil
                existing.updatedAt = now
                try existing.update(db)
                return .enabled(id: existing.id, incarnation: existing.incarnation)
            }
            var created = SeriesSubscriptionRecord(
                id: UUID().uuidString,
                pluginId: media.pluginId,
                mediaKind: media.mediaKind,
                canonicalMediaId: media.canonicalMediaId,
                state: .enabled,
                pauseReason: nil,
                mode: configuration.mode,
                windowSize: configuration.windowSize,
                perRunPositionCap: configuration.perRunPositionCap,
                selection: selection,
                replacementRule: configuration.replacementRule,
                incarnation: 1,
                configGeneration: 1,
                nextCheckTicket: 1,
                lastAttemptAt: nil,
                lastAttemptOutcome: nil,
                lastSuccessAt: nil,
                createdAt: now,
                updatedAt: now
            )
            created.apply(configuration, selection: selection)
            try created.insert(db)
            return .enabled(id: created.id, incarnation: created.incarnation)
        }
    }

    /// Stops the discovery of an enabled rule and keeps everything else: its owners, its events and its baseline.
    /// The baseline does not move while paused, so nothing released meanwhile is absorbed. Returns the jobs that are
    /// downloading for this rule alone, so the caller can stop their attempts: they go back to the queue, and a job
    /// without an enabled owner is not dequeued.
    func pauseSubscription(id: String) async throws -> [String] {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db -> [String] in
            guard var subscription = try SubscriptionLedger.subscription(id: id, in: db),
                  subscription.state == .enabled else { return [] }
            subscription.state = .paused
            subscription.pauseReason = .user
            subscription.updatedAt = now
            try subscription.update(db)
            return try String.fetchAll(
                db,
                sql: """
                    SELECT j.id FROM downloadJob j
                    WHERE j.state = 'downloading'
                      AND EXISTS (SELECT 1 FROM downloadJobOwner o WHERE o.jobId = j.id AND o.subscriptionId = ?)
                      AND NOT EXISTS (
                        SELECT 1 FROM downloadJobOwner o2 LEFT JOIN seriesSubscription s2 ON s2.id = o2.subscriptionId
                        WHERE o2.jobId = j.id
                          AND (o2.ownerKind = 'manual'
                               OR (s2.id != ? AND s2.state = 'enabled' AND s2.incarnation = o2.subscriptionIncarnation))
                      )
                    ORDER BY j.createdAt, j.id
                    """,
                arguments: [id, id]
            )
        }
    }

    /// Enables a paused rule again. A rule the person paused keeps its baseline, so what was released during the pause
    /// is classified by the next check, and its configuration generation does not change. A rule a restore or a source
    /// change paused has no baseline, events or owners, so it needs a review: it is enabled only with the reviewed
    /// configuration, while the source epoch it was reviewed under is current and the series is in the Library. It then
    /// starts over, waiting for its first baseline, under a new generation. A resume never creates an event or a job.
    func resumeSubscription(_ request: SubscriptionResumeRequest) async throws -> SubscriptionResumeOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db -> SubscriptionResumeOutcome in
            guard var subscription = try SubscriptionLedger.subscription(id: request.subscriptionId, in: db),
                  subscription.state == .paused, let reason = subscription.pauseReason else { return .unavailable }
            guard subscription.configGeneration == request.expectedConfigGeneration else { return .stale }
            switch reason {
            case .restored, .sourceRemapped:
                guard let epoch = request.reviewedSourceEpoch, let configuration = request.configuration else {
                    return .reviewRequired
                }
                guard try PluginCompletionScope.current(pluginID: subscription.pluginId, in: db) == epoch else {
                    return .sourceChanged
                }
                guard try Self.libraryItemExists(for: subscription.media, in: db) else { return .seriesNotSaved }
                guard configuration.isValid, let selection = try? configuration.selection.storageData() else {
                    return .invalidConfiguration
                }
                subscription.apply(configuration, selection: selection)
                subscription.configGeneration += 1
                subscription.lastAttemptAt = nil
                subscription.lastAttemptOutcome = nil
                subscription.lastSuccessAt = nil
            case .user:
                guard request.configuration == nil else { return .reviewRequired }
            }
            subscription.state = .enabled
            subscription.pauseReason = nil
            subscription.updatedAt = now
            try subscription.update(db)
            return .resumed(configGeneration: subscription.configGeneration)
        }
    }

    /// Applies a new configuration when the generation the editor saw is still current. Generations only grow, so a
    /// sheet that was open during another edit, a disable or a restore is stale. Existing jobs and owners are kept.
    /// Events that were waiting for capacity, a group, a choice or an unlocked row are decided again by the next
    /// check or drain; a review stays a review.
    func editSubscription(_ edit: SubscriptionEdit) async throws -> SubscriptionEditOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        guard edit.configuration.isValid, let selection = try? edit.configuration.selection.storageData() else {
            return .invalidConfiguration
        }
        let now = clock()
        return try await database.write { db -> SubscriptionEditOutcome in
            guard var subscription = try SubscriptionLedger.subscription(id: edit.subscriptionId, in: db),
                  subscription.state != .disabled else { return .unavailable }
            guard subscription.configGeneration == edit.expectedConfigGeneration else { return .stale }
            subscription.apply(edit.configuration, selection: selection)
            subscription.configGeneration += 1
            subscription.updatedAt = now
            try subscription.update(db)
            try SubscriptionLedger.reopenWaitingEvents(of: subscription.id, in: db)
            return .applied(configGeneration: subscription.configGeneration)
        }
    }

    /// Disables the rule. Jobs only it asked for are removed with their staging directories, so an attempt that is
    /// running for one is refused at its commit; jobs another owner asked for stay, and files are never touched.
    func disableSubscription(id: String) async throws -> SubscriptionRelease {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        let release = try await database.write { db -> SubscriptionRelease in
            guard let subscription = try SubscriptionLedger.subscription(id: id, in: db),
                  subscription.state != .disabled else { return SubscriptionRelease() }
            return try Self.disableSubscription(subscription, now: now, in: db)
        }
        discardStaging(versionIds: release.stagingVersionIds)
        return release
    }

    /// Releases the rule like `disableSubscription` and deletes it.
    func deleteSubscription(id: String) async throws -> SubscriptionRelease {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let release = try await database.write { db -> SubscriptionRelease in
            guard let subscription = try SubscriptionLedger.subscription(id: id, in: db) else { return SubscriptionRelease() }
            return try Self.deleteSubscription(subscription, in: db)
        }
        discardStaging(versionIds: release.stagingVersionIds)
        return release
    }

    func subscription(for media: MediaIdentity) async throws -> SeriesSubscriptionRecord? {
        try await database.read { db in try SeriesSubscriptionRecord.forMedia(media).fetchOne(db) }
    }

    // MARK: - Checks

    /// The enabled rules and when each was last attempted, for the scheduler. No evidence table is read.
    func subscriptionScheduleRows() async throws -> [SubscriptionScheduleRow] {
        try await database.read { db in
            try SeriesSubscriptionRecord
                .filter(Column("state") == SubscriptionState.enabled.rawValue)
                .order(Column("id"))
                .fetchAll(db)
                .map { rule in
                    SubscriptionScheduleRow(
                        id: rule.id, media: rule.media, state: rule.state,
                        lastAttemptAt: rule.lastAttemptAt, lastAttemptOutcome: rule.lastAttemptOutcome
                    )
                }
        }
    }

    /// The enabled rules a drain can act on, in id order: an open undecided event, a pending event that waits for queue
    /// or disk room, or Maintain Next N, whose window follows what was read.
    func drainableSubscriptionIds() async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT s.id FROM seriesSubscription s
                    WHERE s.state = 'enabled'
                      AND (s.mode = 'maintainNextUnread'
                           OR EXISTS (
                               SELECT 1 FROM subscriptionEvent e
                               WHERE e.subscriptionId = s.id
                                 AND (e.decision = 'undecided'
                                      OR (e.decision = 'pending' AND e.pendingReason IN ('queueCap', 'quota')))))
                    ORDER BY s.id
                    """
            )
        }
    }

    /// Allocates the ticket of one check of an enabled rule, when the epoch the caller captured is still the
    /// source's. The fetch then freezes `ticket.sourceEpoch`; only the newest ticket can move the baseline.
    func beginSubscriptionCheck(media: MediaIdentity, capturedEpoch: String) async throws -> SubscriptionCheckTicket? {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        return try await database.write { db -> SubscriptionCheckTicket? in
            guard var subscription = try SeriesSubscriptionRecord.forMedia(media).fetchOne(db),
                  subscription.state == .enabled,
                  try PluginCompletionScope.current(pluginID: media.pluginId, in: db) == capturedEpoch else { return nil }
            let ticket = subscription.nextCheckTicket
            subscription.nextCheckTicket += 1
            try subscription.update(db)
            return SubscriptionCheckTicket(
                subscriptionId: subscription.id,
                media: media,
                incarnation: subscription.incarnation,
                ticket: ticket,
                sourceEpoch: capturedEpoch
            )
        }
    }

    /// The compare-and-swap of one observation: it is judged against the baseline as committed now, and its
    /// baseline, seen keys, events, owners and jobs are written in this one transaction.
    func commitSubscriptionObservation(
        _ ticket: SubscriptionCheckTicket,
        _ observation: CatalogObservation,
        limits: AutomaticDownloadLimits
    ) async throws -> SubscriptionCommitOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db in
            try Self.commitObservation(ticket, observation, limits: limits, now: now, in: db)
        }
    }

    /// Records a check that produced no observation. A stale ticket records nothing.
    func recordSubscriptionCheckFailure(_ ticket: SubscriptionCheckTicket, _ outcome: SubscriptionCheckOutcome) async throws {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        try await database.write { db in
            guard let subscription = try SubscriptionLedger.subscription(id: ticket.subscriptionId, in: db),
                  subscription.state == .enabled, subscription.incarnation == ticket.incarnation else { return }
            // A check older than the baseline already accepted proves nothing about it.
            if let accepted = try SubscriptionLedger.baselineRecord(of: subscription.id, in: db),
               accepted.acceptedTicket >= ticket.ticket { return }
            try SubscriptionLedger.recordAttempt(subscription.id, outcome: outcome, success: false, now: now, in: db)
        }
    }

    /// Decides the events that wait for queue or disk room, and undecided ones, from the stored baseline. Events held
    /// by the per-run cap wait for the next check.
    func drainSubscriptionEvents(
        subscriptionId: String,
        limits: AutomaticDownloadLimits
    ) async throws -> SubscriptionCommitOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db in
            try Self.drainEvents(subscriptionId: subscriptionId, limits: limits, now: now, in: db)
        }
    }

    // MARK: - Decisions of a person

    /// Approves keys of an open event, or dismisses it. The event, the rule's generations and the candidate list the
    /// reviewer saw must all still be current; an approval then admits with the run cap exempt, and the queue cap, the
    /// quota and the user's deletion records still apply.
    func resolveSubscriptionEvent(
        _ resolution: SubscriptionEventResolution,
        limits: AutomaticDownloadLimits
    ) async throws -> SubscriptionCommitOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db in
            try Self.resolveEvent(resolution, limits: limits, now: now, in: db)
        }
    }

    /// Approves reviewed positions of the accepted catalog for download, for a rule that fills unread chapters. The
    /// rule's generations and the baseline revision and digest the reviewer saw must be current, or nothing is
    /// written. The approved keys are admitted with the run cap exempt.
    func approveSubscriptionBackfill(
        _ approval: SubscriptionBackfillApproval,
        limits: AutomaticDownloadLimits
    ) async throws -> SubscriptionCommitOutcome {
        guard isReconciled else { throw OfflineStoreError.reconciliationPending }
        let now = clock()
        return try await database.write { db in
            try Self.approveBackfill(approval, limits: limits, now: now, in: db)
        }
    }

    /// Whether automatic jobs may start: the bytes already stored are under the quota. It bounds the overshoot to the
    /// attempt already in flight.
    func automaticQuotaAdmits(_ limits: AutomaticDownloadLimits) async throws -> Bool {
        try await database.read { db in try Self.storedBytes(in: db) < limits.quotaBytes }
    }

    // MARK: - Transaction bodies

    nonisolated static func libraryItemExists(for media: MediaIdentity, in db: Database) throws -> Bool {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind
        )
        return try candidates.contains { id in
            guard let item = try LibraryItem.fetchOne(db, key: id) else { return false }
            return item.mediaIdentity == media
        }
    }

    nonisolated static func commitObservation(
        _ ticket: SubscriptionCheckTicket,
        _ observation: CatalogObservation,
        limits: AutomaticDownloadLimits,
        now: Date,
        in db: Database
    ) throws -> SubscriptionCommitOutcome {
        guard let subscription = try SubscriptionLedger.subscription(id: ticket.subscriptionId, in: db) else {
            return SubscriptionCommitOutcome(.superseded)
        }
        if subscription.state == .disabled { return SubscriptionCommitOutcome(.disabled) }
        guard subscription.incarnation == ticket.incarnation else { return SubscriptionCommitOutcome(.superseded) }
        // A paused rule writes nothing and does not advance its baseline: what is released while paused is not absorbed.
        if subscription.state == .paused { return SubscriptionCommitOutcome(.paused) }
        guard observation.media == ticket.media, observation.media == subscription.media else {
            return SubscriptionCommitOutcome(.superseded)
        }

        func reject(_ outcome: SubscriptionCheckOutcome) throws -> SubscriptionCommitOutcome {
            try SubscriptionLedger.recordAttempt(subscription.id, outcome: outcome, success: false, now: now, in: db)
            return SubscriptionCommitOutcome(outcome)
        }
        guard try PluginCompletionScope.current(pluginID: ticket.media.pluginId, in: db) == ticket.sourceEpoch,
              observation.fingerprint.sourceEpoch == ticket.sourceEpoch else { return try reject(.sourceChanged) }
        guard try libraryItemExists(for: ticket.media, in: db) else { return try reject(.seriesNotSaved) }
        let storedBaseline = try SubscriptionLedger.baselineRecord(of: subscription.id, in: db)
        // An observation that started before an accepted one never takes its place: no write at all.
        if let storedBaseline, storedBaseline.acceptedTicket >= ticket.ticket {
            return SubscriptionCommitOutcome(.superseded)
        }
        guard subscription.decodedSelection != nil else { return try reject(.selectionUnreadable) }
        guard (1...256).contains(observation.fingerprint.pluginVersion.utf8.count) else { return try reject(.unknownScope) }

        // The baseline as committed now: a check that began earlier and committed first is part of it.
        let previous = try storedBaseline.map { (record: $0, view: try SubscriptionLedger.view(of: $0, in: db)) }
        var outcome = SubscriptionCommitOutcome(.advanced)
        let accepted: SubscriptionBaselineRecord
        let catalog: SubscriptionAcceptedCatalog
        let attempt: SubscriptionCheckOutcome

        switch SubscriptionCatalogClassifier.classify(observation: observation, baseline: previous?.view) {
        case .rejected(let reason):
            return try reject(reason)
        case .unchanged:
            guard var record = previous?.record else { return try reject(.superseded) }
            // Not a content write: the revision stays, but this check is now the newest the baseline has seen.
            record.acceptedTicket = ticket.ticket
            try db.execute(
                sql: "UPDATE subscriptionBaseline SET acceptedTicket = ? WHERE subscriptionId = ?",
                arguments: [ticket.ticket, subscription.id]
            )
            accepted = record
            catalog = SubscriptionAcceptedCatalog(observation: observation)
            attempt = .unchanged
        case .baseline(let write, let reason):
            accepted = try SubscriptionLedger.accept(
                write, observation: observation, subscription: subscription,
                ticket: ticket.ticket, previous: previous, now: now, in: db
            )
            catalog = SubscriptionAcceptedCatalog(observation: observation)
            // A new scope decides what was waiting again: the keys it lists are the only live ones.
            if reason == .rebaselined { try SubscriptionLedger.reopenWaitingEvents(of: subscription.id, in: db) }
            attempt = reason
        case .advance(let write, let events):
            accepted = try SubscriptionLedger.accept(
                write, observation: observation, subscription: subscription,
                ticket: ticket.ticket, previous: previous, now: now, in: db
            )
            catalog = SubscriptionAcceptedCatalog(observation: observation)
            let inserted = try SubscriptionLedger.insert(
                events, for: subscription, observedCatalogDigest: observation.catalogDigest,
                scopeGeneration: accepted.scopeGeneration, now: now, in: db
            )
            outcome.createdEventIds = inserted.map(\.id)
            outcome.needsAttentionEventIds = inserted.filter { $0.decision == .needsReview }.map(\.id)
            try SubscriptionLedger.attachAlternates(
                inserted.filter { $0.kind == .newAlternate },
                positions: write.seenUpserts,
                subscription: subscription, in: db
            )
            attempt = .advanced
        case .anomaly(let events):
            // An empty catalog after a non-empty one raises a review and moves nothing.
            guard let record = previous?.record, let stored = try? SubscriptionAcceptedCatalog(record: record) else {
                return try reject(.incompleteCatalog)
            }
            let inserted = try SubscriptionLedger.insert(
                events, for: subscription, observedCatalogDigest: observation.catalogDigest,
                scopeGeneration: record.scopeGeneration, now: now, in: db
            )
            outcome.createdEventIds = inserted.map(\.id)
            outcome.needsAttentionEventIds = inserted.filter { $0.decision == .needsReview }.map(\.id)
            accepted = record
            catalog = stored
            attempt = .advanced
        }

        try refreshWindowEvents(
            subscription: subscription, catalog: catalog, scopeGeneration: accepted.scopeGeneration,
            now: now, in: db, into: &outcome
        )
        try admit(
            subscription: subscription, catalog: catalog,
            trigger: .check(runCap: subscription.perRunPositionCap),
            limits: limits, now: now, in: db, into: &outcome
        )
        try pruneTerminalEvents(of: subscription, catalog: catalog, in: db)
        try SubscriptionLedger.recordAttempt(subscription.id, outcome: attempt, success: true, now: now, in: db)
        outcome.outcome = attempt
        return outcome
    }

    nonisolated static func drainEvents(
        subscriptionId: String,
        limits: AutomaticDownloadLimits,
        now: Date,
        in db: Database
    ) throws -> SubscriptionCommitOutcome {
        guard let subscription = try SubscriptionLedger.subscription(id: subscriptionId, in: db) else {
            return SubscriptionCommitOutcome(.superseded)
        }
        if subscription.state == .disabled { return SubscriptionCommitOutcome(.disabled) }
        if subscription.state == .paused { return SubscriptionCommitOutcome(.paused) }
        guard let record = try SubscriptionLedger.baselineRecord(of: subscription.id, in: db) else {
            return SubscriptionCommitOutcome(.superseded, refusal: .unavailable)
        }
        // The jobs freeze the baseline's epoch, which must still be the source's.
        guard try PluginCompletionScope.current(pluginID: subscription.pluginId, in: db) == record.sourceEpoch else {
            return SubscriptionCommitOutcome(.sourceChanged)
        }
        guard subscription.decodedSelection != nil else { return SubscriptionCommitOutcome(.selectionUnreadable) }
        guard let catalog = try? SubscriptionAcceptedCatalog(record: record) else {
            return SubscriptionCommitOutcome(.incompleteCatalog)
        }
        var outcome = SubscriptionCommitOutcome(.advanced)
        try refreshWindowEvents(
            subscription: subscription, catalog: catalog, scopeGeneration: record.scopeGeneration,
            now: now, in: db, into: &outcome
        )
        try admit(
            subscription: subscription, catalog: catalog, trigger: .drain,
            limits: limits, now: now, in: db, into: &outcome
        )
        try pruneTerminalEvents(of: subscription, catalog: catalog, in: db)
        if outcome.queuedJobs + outcome.attachedJobs == 0, outcome.createdEventIds.isEmpty { outcome.outcome = .unchanged }
        return outcome
    }

    nonisolated static func resolveEvent(
        _ resolution: SubscriptionEventResolution,
        limits: AutomaticDownloadLimits,
        now: Date,
        in db: Database
    ) throws -> SubscriptionCommitOutcome {
        func refused(_ reason: SubscriptionResolutionRefusal) -> SubscriptionCommitOutcome {
            SubscriptionCommitOutcome(.superseded, refusal: reason)
        }
        guard let event = try SubscriptionEventRecord.fetchOne(db, key: resolution.eventId),
              let subscription = try SubscriptionLedger.subscription(id: event.subscriptionId, in: db),
              subscription.state != .disabled else { return refused(.unavailable) }
        guard event.incarnation == resolution.incarnation, subscription.incarnation == resolution.incarnation,
              subscription.configGeneration == resolution.configGeneration,
              event.candidateRevision == resolution.candidateRevision else { return refused(.stale) }
        guard event.decision.isOpen else { return refused(.eventNotOpen) }

        switch resolution.action {
        case .dismiss:
            try SubscriptionLedger.settle(event, as: .dismissed, now: now, in: db)
            return SubscriptionCommitOutcome(.advanced)
        case .approve(let keys):
            guard subscription.state == .enabled, let record = try SubscriptionLedger.baselineRecord(of: subscription.id, in: db) else {
                return refused(.unavailable)
            }
            guard event.identityKind != .catalog, event.kind != .catalogAnomaly, event.kind != .newAlternate,
                  !keys.isEmpty else { return refused(.invalidKeys) }
            let candidates = Set(event.candidates.map { ScanlatorUTF8(value: $0) })
            for key in keys {
                guard candidates.contains(ScanlatorUTF8(value: key)),
                      try SubscriptionSeenKeyRecord.fetchOne(
                          db, key: ["subscriptionId": subscription.id, "chapterKey": key]
                      )?.presentInAccepted == true else { return refused(.invalidKeys) }
            }
            guard try PluginCompletionScope.current(pluginID: subscription.pluginId, in: db) == record.sourceEpoch else {
                return SubscriptionCommitOutcome(.sourceChanged)
            }
            guard subscription.decodedSelection != nil else { return SubscriptionCommitOutcome(.selectionUnreadable) }
            guard let catalog = try? SubscriptionAcceptedCatalog(record: record) else {
                return SubscriptionCommitOutcome(.incompleteCatalog)
            }
            try SubscriptionLedger.settle(event, as: .undecided, approvedKeys: keys, now: now, in: db)
            var outcome = SubscriptionCommitOutcome(.advanced)
            try admit(
                subscription: subscription, catalog: catalog, trigger: .events([event.id]),
                limits: limits, now: now, in: db, into: &outcome
            )
            try pruneTerminalEvents(of: subscription, catalog: catalog, in: db)
            return outcome
        }
    }

    nonisolated static func approveBackfill(
        _ approval: SubscriptionBackfillApproval,
        limits: AutomaticDownloadLimits,
        now: Date,
        in db: Database
    ) throws -> SubscriptionCommitOutcome {
        func refused(_ reason: SubscriptionResolutionRefusal) -> SubscriptionCommitOutcome {
            SubscriptionCommitOutcome(.superseded, refusal: reason)
        }
        guard let subscription = try SubscriptionLedger.subscription(id: approval.subscriptionId, in: db),
              subscription.state == .enabled,
              let record = try SubscriptionLedger.baselineRecord(of: subscription.id, in: db) else {
            return refused(.unavailable)
        }
        guard subscription.mode == .newAndFillUnread else { return refused(.unsupportedMode) }
        guard subscription.incarnation == approval.incarnation,
              subscription.configGeneration == approval.configGeneration,
              record.revision == approval.baselineRevision,
              ScanlatorUTF8.bytesEqual(record.catalogDigest, approval.catalogDigest) else { return refused(.stale) }
        guard try PluginCompletionScope.current(pluginID: subscription.pluginId, in: db) == record.sourceEpoch else {
            return SubscriptionCommitOutcome(.sourceChanged)
        }
        guard subscription.decodedSelection != nil else { return SubscriptionCommitOutcome(.selectionUnreadable) }
        guard let catalog = try? SubscriptionAcceptedCatalog(record: record) else {
            return SubscriptionCommitOutcome(.incompleteCatalog)
        }

        // Every reviewed key must be listed by the accepted catalog, and the keys of one position must share it.
        var events: [ClassifiedEvent] = []
        for (ordinal, keys) in approval.positions.enumerated() {
            guard !keys.isEmpty, keys.count <= SubscriptionCatalogClassifier.candidateKeyLimit else {
                return refused(.invalidKeys)
            }
            var position: SubscriptionPositionID?
            for key in keys {
                guard let seen = try SubscriptionSeenKeyRecord.fetchOne(
                    db, key: ["subscriptionId": subscription.id, "chapterKey": key]
                ), seen.presentInAccepted else { return refused(.invalidKeys) }
                let evidence = seen.evidence.position
                if let position, position != evidence { return refused(.invalidKeys) }
                position = evidence
            }
            guard let position else { return refused(.invalidKeys) }
            events.append(ClassifiedEvent(
                kind: .backfill,
                identity: SubscriptionEventIdentity(kind: position.identityKind, value: position.value),
                qualifier: nil,
                candidateKeys: keys,
                previousRevision: nil,
                targetRevision: nil,
                ordinal: ordinal,
                initialDecision: .undecided,
                reviewReason: nil
            ))
        }
        // A finished approval of a position can be approved again, for example after its job was cancelled.
        for event in events {
            try db.execute(
                sql: """
                    DELETE FROM subscriptionEvent
                    WHERE subscriptionId = ? AND incarnation = ? AND kind = 'backfill'
                      AND identityKind = ? AND identityValue = ?
                      AND decision NOT IN (\(SubscriptionLedger.openDecisionsSQL))
                    """,
                arguments: [subscription.id, subscription.incarnation, event.identity.kind.rawValue, event.identity.value]
            )
        }
        let inserted = try SubscriptionLedger.insert(
            events, for: subscription, observedCatalogDigest: record.catalogDigest,
            scopeGeneration: record.scopeGeneration, now: now, in: db
        )
        for var event in inserted {
            event.approvedKeys = event.candidateKeys
            try event.update(db)
        }
        var outcome = SubscriptionCommitOutcome(.advanced)
        outcome.createdEventIds = inserted.map(\.id)
        try admit(
            subscription: subscription, catalog: catalog, trigger: .events(Set(inserted.map(\.id))),
            limits: limits, now: now, in: db, into: &outcome
        )
        try pruneTerminalEvents(of: subscription, catalog: catalog, in: db)
        return outcome
    }
}

nonisolated extension SeriesSubscriptionRecord {
    /// Copies a configuration onto the row. The caller checks it is valid and passes its encoded selection.
    mutating func apply(_ configuration: SubscriptionConfiguration, selection: Data) {
        mode = configuration.mode
        windowSize = configuration.windowSize
        perRunPositionCap = configuration.perRunPositionCap
        self.selection = selection
        replacementRule = configuration.replacementRule
    }
}
