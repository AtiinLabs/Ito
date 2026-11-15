import GRDB

extension AppDatabase {
    /// The durable catalog ledger behind automatic downloads and the shared job ownership it needs.
    ///
    /// - `downloadBatch` is rebuilt in the SQLite 12-step order (create, copy, drop, rename) so its preset can be
    ///   `automatic`: an automatic batch must not claim `single`. It must not be renamed first, because a rename
    ///   rewrites the foreign keys of `downloadJob` to the dropped table. The columns, constraints and absent
    ///   indexes are exactly v26's.
    /// - `downloadJobOwner` records who requested each job. Every job that exists when this migration runs was
    ///   requested by a person, so each gets one manual owner whose request is its batch. An owner is never
    ///   inferred from a preset. The link to a subscription has no cascade: releasing a subscription's owners is an
    ///   explicit step, so a deletion that skips it fails instead of leaving jobs without an owner.
    /// - The subscription, its single accepted baseline, its cumulative seen keys and its events are created. The
    ///   enum-valued columns carry the closed lists of the matching Swift enums; a test keeps the two in step.
    ///
    /// Foreign-key checks are deferred by GRDB around the migration, so this migration issues no PRAGMA of its own.
    /// Every `TEXT` comparison uses the default `BINARY` collation: keys and identifiers compare as exact bytes.
    nonisolated static func registerSubscriptionLedgerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27") { db in
            try db.execute(sql: """
                CREATE TABLE downloadBatch_v27 (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  preset TEXT NOT NULL CHECK(preset IN ('single','next','next5','next10','unread','all','custom','more','automatic')),
                  windowKind TEXT CHECK(windowKind IS NULL OR windowKind IN ('next','more')),
                  positionCount INTEGER CHECK(positionCount IS NULL OR (typeof(positionCount) = 'integer' AND positionCount BETWEEN 1 AND 1000)),
                  customPresetId TEXT CHECK(customPresetId IS NULL OR length(customPresetId) = 36),
                  selection BLOB NOT NULL,
                  catalogDigest TEXT CHECK(catalogDigest IS NULL OR length(catalogDigest) = 64),
                  entrySnapshot BLOB NOT NULL,
                  createdAt DATETIME NOT NULL,
                  CHECK ((preset IN ('custom','more')) = (windowKind IS NOT NULL)),
                  CHECK ((windowKind IS NULL) = (positionCount IS NULL)),
                  CHECK ((preset = 'custom') = (customPresetId IS NOT NULL)),
                  CHECK (preset != 'more' OR windowKind = 'more')
                );
                INSERT INTO downloadBatch_v27
                  (id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
                   selection, catalogDigest, entrySnapshot, createdAt)
                SELECT id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
                   selection, catalogDigest, entrySnapshot, createdAt
                FROM downloadBatch;
                DROP TABLE downloadBatch;
                ALTER TABLE downloadBatch_v27 RENAME TO downloadBatch;
                """)

            try db.execute(sql: """
                CREATE TABLE seriesSubscription (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('enabled','paused','disabled')),
                  pauseReason TEXT CHECK(pauseReason IS NULL OR pauseReason IN ('user','sourceRemapped','restored')),
                  mode TEXT NOT NULL CHECK(mode IN ('newReleases','newAndFillUnread','maintainNextUnread')),
                  windowSize INTEGER CHECK(windowSize IS NULL OR (typeof(windowSize) = 'integer' AND windowSize BETWEEN 1 AND 100)),
                  perRunPositionCap INTEGER NOT NULL DEFAULT 5 CHECK(typeof(perRunPositionCap) = 'integer' AND perRunPositionCap BETWEEN 1 AND 20),
                  selection BLOB NOT NULL,
                  replacementRule TEXT NOT NULL DEFAULT 'off' CHECK(replacementRule IN ('off','sameKeyReliableRevision')),
                  incarnation INTEGER NOT NULL CHECK(incarnation >= 1),
                  configGeneration INTEGER NOT NULL CHECK(configGeneration >= 1),
                  nextCheckTicket INTEGER NOT NULL DEFAULT 1 CHECK(nextCheckTicket >= 1),
                  lastAttemptAt DATETIME,
                  lastAttemptOutcome TEXT CHECK(lastAttemptOutcome IS NULL OR lastAttemptOutcome IN (
                    'baselineEstablished','rebaselined','advanced','unchanged',
                    'incompleteCatalog','unknownScope','emptyCatalog','oversizedCatalog','unsupportedKind',
                    'sourceChanged','superseded','paused','disabled','seriesNotSaved','selectionUnreadable','fetchFailed')),
                  lastSuccessAt DATETIME,
                  createdAt DATETIME NOT NULL,
                  updatedAt DATETIME NOT NULL,
                  UNIQUE (pluginId, mediaKind, canonicalMediaId),
                  CHECK ((state = 'paused') = (pauseReason IS NOT NULL)),
                  CHECK ((mode = 'maintainNextUnread') = (windowSize IS NOT NULL)),
                  CHECK ((lastAttemptAt IS NULL) = (lastAttemptOutcome IS NULL))
                );

                CREATE TABLE subscriptionBaseline (
                  subscriptionId TEXT PRIMARY KEY NOT NULL REFERENCES seriesSubscription(id) ON DELETE CASCADE,
                  incarnation INTEGER NOT NULL CHECK(incarnation >= 1),
                  revision INTEGER NOT NULL CHECK(revision >= 1),
                  acceptedTicket INTEGER NOT NULL CHECK(acceptedTicket >= 1),
                  scopeGeneration INTEGER NOT NULL CHECK(scopeGeneration >= 1),
                  acquisition TEXT NOT NULL CHECK(acquisition IN ('mediaUpdate')),
                  sourceEpoch TEXT NOT NULL CHECK(length(sourceEpoch) = 32),
                  pluginVersion TEXT NOT NULL CHECK(length(CAST(pluginVersion AS BLOB)) BETWEEN 1 AND 256),
                  chapterABI INTEGER NOT NULL CHECK(chapterABI = 3),
                  catalogScope TEXT NOT NULL CHECK(catalogScope IN ('visible','allEligible')),
                  catalogDigest TEXT NOT NULL CHECK(length(catalogDigest) = 64),
                  rowCount INTEGER NOT NULL CHECK(rowCount BETWEEN 1 AND 20000),
                  orderConfidence TEXT NOT NULL CHECK(orderConfidence IN ('confident','ambiguous')),
                  highWaterKind TEXT CHECK(highWaterKind IS NULL OR highWaterKind IN ('logical','exact')),
                  highWaterValue TEXT,
                  maxDateUpdated REAL,
                  tombstonesTruncated INTEGER NOT NULL DEFAULT 0 CHECK(tombstonesTruncated IN (0,1)),
                  entrySnapshot BLOB NOT NULL CHECK(length(entrySnapshot) <= 16777216),
                  acceptedAt DATETIME NOT NULL,
                  CHECK ((orderConfidence = 'confident') = (highWaterKind IS NOT NULL)),
                  CHECK ((highWaterKind IS NULL) = (highWaterValue IS NULL))
                );

                CREATE TABLE subscriptionSeenKey (
                  subscriptionId TEXT NOT NULL REFERENCES seriesSubscription(id) ON DELETE CASCADE,
                  chapterKey TEXT NOT NULL CHECK(length(CAST(chapterKey AS BLOB)) BETWEEN 1 AND 512),
                  positionKind TEXT NOT NULL CHECK(positionKind IN ('logical','exact')),
                  positionValue TEXT NOT NULL,
                  lastRevision TEXT CHECK(lastRevision IS NULL OR length(CAST(lastRevision AS BLOB)) BETWEEN 1 AND 256),
                  presentInAccepted INTEGER NOT NULL CHECK(presentInAccepted IN (0,1)),
                  acceptedRank INTEGER CHECK(acceptedRank IS NULL OR (presentInAccepted = 1 AND acceptedRank >= 0)),
                  firstSeenScopeGeneration INTEGER NOT NULL CHECK(firstSeenScopeGeneration >= 1),
                  firstSeenAt DATETIME NOT NULL,
                  PRIMARY KEY (subscriptionId, chapterKey)
                ) WITHOUT ROWID;
                CREATE INDEX idx_subscriptionSeenKey_position ON subscriptionSeenKey(subscriptionId, positionKind, positionValue);

                CREATE TABLE subscriptionEvent (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  subscriptionId TEXT NOT NULL REFERENCES seriesSubscription(id) ON DELETE CASCADE,
                  incarnation INTEGER NOT NULL CHECK(incarnation >= 1),
                  kind TEXT NOT NULL CHECK(kind IN ('newPosition','newAlternate','revisionChanged','unplacedKey','catalogAnomaly','backfill','window')),
                  identityKind TEXT NOT NULL CHECK(identityKind IN ('logical','exact','catalog')),
                  identityValue TEXT NOT NULL CHECK(length(CAST(identityValue AS BLOB)) BETWEEN 1 AND 512),
                  qualifier TEXT CHECK(qualifier IS NULL OR length(CAST(qualifier AS BLOB)) BETWEEN 1 AND 256),
                  decision TEXT NOT NULL CHECK(decision IN ('undecided','pending','awaitingEdition','needsChoice','needsReview','locked',
                                                            'enqueued','satisfied','recorded','suppressed','blockedDamaged',
                                                            'dismissed','revoked','superseded')),
                  pendingReason TEXT CHECK(pendingReason IS NULL OR pendingReason IN ('runCap','queueCap','quota')),
                  reviewReason TEXT CHECK(reviewReason IS NULL OR reviewReason IN (
                    'noReliableOrder','noBaselineOrder','highWaterMissing','anchorsReordered','positionIdentityChanged',
                    'knownPositionAfterHighWater','insertedBeforeHighWater','olderThanBaseline','tooManyCandidates',
                    'bulkArrival','bulkRevisionChange','emptyAfterNonempty',
                    'selectionUnresolved','numberOnlyReadState','windowOrderAmbiguous')),
                  candidateKeys BLOB NOT NULL,
                  candidateRevision INTEGER NOT NULL DEFAULT 1 CHECK(candidateRevision >= 1),
                  approvedKeys BLOB,
                  decidedKeys BLOB,
                  previousRevision TEXT,
                  targetRevision TEXT,
                  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                  observedCatalogDigest TEXT NOT NULL CHECK(length(observedCatalogDigest) = 64),
                  configGeneration INTEGER NOT NULL CHECK(configGeneration >= 1),
                  scopeGeneration INTEGER NOT NULL CHECK(scopeGeneration >= 1),
                  createdAt DATETIME NOT NULL,
                  decidedAt DATETIME,
                  CHECK ((decision = 'pending') = (pendingReason IS NOT NULL)),
                  CHECK (decision != 'needsReview' OR reviewReason IS NOT NULL),
                  CHECK ((decision IN ('enqueued','satisfied')) = (decidedKeys IS NOT NULL)),
                  CHECK ((kind = 'revisionChanged') = (targetRevision IS NOT NULL)),
                  CHECK (kind != 'revisionChanged' OR qualifier = targetRevision)
                );
                CREATE UNIQUE INDEX idx_subscriptionEvent_identity
                  ON subscriptionEvent(subscriptionId, incarnation, kind, identityKind, identityValue, ifnull(qualifier, ''));
                CREATE INDEX idx_subscriptionEvent_open ON subscriptionEvent(subscriptionId, decision, createdAt, ordinal, id);
                """)

            try db.execute(sql: """
                CREATE TABLE downloadJobOwner (
                  jobId TEXT NOT NULL REFERENCES downloadJob(id) ON DELETE CASCADE,
                  ownerKind TEXT NOT NULL CHECK(ownerKind IN ('manual','subscription')),
                  manualRequestId TEXT CHECK(manualRequestId IS NULL OR length(manualRequestId) = 36),
                  subscriptionId TEXT REFERENCES seriesSubscription(id),
                  subscriptionIncarnation INTEGER CHECK(subscriptionIncarnation IS NULL OR subscriptionIncarnation >= 1),
                  eventId TEXT CHECK(eventId IS NULL OR length(eventId) = 36),
                  attachedAt DATETIME NOT NULL,
                  CHECK ((ownerKind = 'manual') = (manualRequestId IS NOT NULL)),
                  CHECK ((ownerKind = 'subscription') = (subscriptionId IS NOT NULL)),
                  CHECK ((ownerKind = 'subscription') = (subscriptionIncarnation IS NOT NULL)),
                  CHECK ((ownerKind = 'subscription') = (eventId IS NOT NULL))
                );
                CREATE UNIQUE INDEX idx_downloadJobOwner_manual ON downloadJobOwner(jobId, manualRequestId) WHERE ownerKind = 'manual';
                CREATE UNIQUE INDEX idx_downloadJobOwner_subscription ON downloadJobOwner(jobId, subscriptionId) WHERE ownerKind = 'subscription';
                CREATE INDEX idx_downloadJobOwner_job ON downloadJobOwner(jobId);
                CREATE INDEX idx_downloadJobOwner_bySubscription ON downloadJobOwner(subscriptionId) WHERE subscriptionId IS NOT NULL;

                INSERT INTO downloadJobOwner (jobId, ownerKind, manualRequestId, attachedAt)
                SELECT id, 'manual', batchId, createdAt FROM downloadJob;
                """)
        }
    }
}
