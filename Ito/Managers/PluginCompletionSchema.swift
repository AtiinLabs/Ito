import GRDB

/// Installation-local authorization and delivery state. Neither table is a backup component.
nonisolated enum PluginCompletionSchema {
    static func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE pluginCompletionScope (
                pluginId TEXT PRIMARY KEY NOT NULL,
                epoch TEXT NOT NULL CHECK(length(epoch) = 32 AND epoch NOT GLOB '*[^0-9a-f]*')
            );
            CREATE TABLE pluginCompletionOutbox (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                pluginId TEXT NOT NULL,
                canonicalMediaId TEXT NOT NULL,
                mediaKey TEXT NOT NULL,
                unitKey TEXT NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('manga', 'novel', 'anime')),
                originatingEpoch TEXT CHECK(originatingEpoch IS NULL OR
                    (length(originatingEpoch) = 32 AND originatingEpoch NOT GLOB '*[^0-9a-f]*')),
                revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0),
                status TEXT NOT NULL CHECK(status IN ('pending', 'paused')),
                pauseReason TEXT CHECK(pauseReason IS NULL OR pauseReason IN (
                    'configurationChanged', 'unknownOrigin', 'credentials', 'missingRemote',
                    'sourceUnavailable', 'incompatible', 'sourceError', 'retryLimit')),
                attemptCount INTEGER NOT NULL DEFAULT 0 CHECK(attemptCount >= 0),
                createdAt DATETIME NOT NULL,
                nextAttemptAt DATETIME NOT NULL,
                lastAttemptAt DATETIME,
                lastErrorCategory TEXT,
                CHECK((status = 'pending' AND originatingEpoch IS NOT NULL AND pauseReason IS NULL)
                    OR (status = 'paused' AND pauseReason IS NOT NULL))
            );
            CREATE UNIQUE INDEX pluginCompletionOutbox_target_origin
                ON pluginCompletionOutbox(pluginId, kind, mediaKey, unitKey, COALESCE(originatingEpoch, ''));
            CREATE INDEX pluginCompletionOutbox_eligible ON pluginCompletionOutbox(status, nextAttemptAt, id);
            INSERT INTO pluginCompletionScope(pluginId, epoch)
                SELECT pluginId, lower(hex(randomblob(16))) FROM pluginIdentityRegistry;
            """)
        try createScopeTriggers(in: db)
        try createSettingsTriggers(in: db)
    }

    private static func createScopeTriggers(in db: Database) throws {
        for event in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER pluginCompletionScope_after_\(event.lowercased())_pause
                AFTER \(event) ON pluginCompletionScope
                BEGIN
                    UPDATE pluginCompletionOutbox
                    SET status = 'paused', revision = revision + 1,
                        pauseReason = CASE WHEN originatingEpoch IS NULL
                            THEN 'unknownOrigin' ELSE 'configurationChanged' END
                    WHERE pluginId = NEW.pluginId
                        AND (originatingEpoch IS NULL OR originatingEpoch IS NOT NEW.epoch);
                END;
                """)
        }
        try db.execute(sql: """
            CREATE TRIGGER pluginCompletionScope_after_delete_pause
            AFTER DELETE ON pluginCompletionScope
            BEGIN
                UPDATE pluginCompletionOutbox
                SET status = 'paused', revision = revision + 1,
                    pauseReason = CASE WHEN originatingEpoch IS NULL
                        THEN 'unknownOrigin' ELSE 'configurationChanged' END
                WHERE pluginId = OLD.pluginId;
            END;
            """)
    }

    private static func createSettingsTriggers(in db: Database) throws {
        for (event, owner) in [("INSERT", "NEW"), ("DELETE", "OLD")] {
            try db.execute(sql: """
                CREATE TRIGGER pluginSetting_completion_after_\(event.lowercased())
                AFTER \(event) ON pluginSetting
                BEGIN
                    INSERT INTO pluginCompletionScope(pluginId, epoch)
                    VALUES (\(owner).pluginId, lower(hex(randomblob(16))))
                    ON CONFLICT(pluginId) DO UPDATE SET epoch = excluded.epoch;
                END;
                """)
        }
        try db.execute(sql: """
            CREATE TRIGGER pluginSetting_completion_after_update
            AFTER UPDATE ON pluginSetting
            WHEN OLD.value IS NOT NEW.value OR OLD.key IS NOT NEW.key OR OLD.pluginId IS NOT NEW.pluginId
            BEGIN
                INSERT INTO pluginCompletionScope(pluginId, epoch)
                VALUES (OLD.pluginId, lower(hex(randomblob(16))))
                ON CONFLICT(pluginId) DO UPDATE SET epoch = excluded.epoch;
                INSERT INTO pluginCompletionScope(pluginId, epoch)
                SELECT NEW.pluginId, lower(hex(randomblob(16)))
                WHERE OLD.pluginId IS NOT NEW.pluginId
                ON CONFLICT(pluginId) DO UPDATE SET epoch = excluded.epoch;
            END;
            """)
    }
}
