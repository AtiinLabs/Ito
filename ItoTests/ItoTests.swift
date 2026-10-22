//
//  ItoTests.swift
//  ItoTests
//
//  Created by caocao on 3/3/26.
//

import Testing
import GRDB
@testable import Ito

struct ItoTests {

    @Test func upgradeCreatesSystemListAndFilesListlessSeriesIntoIt() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "v8")
        try queue.write { db in
            for id in ["listless", "listed"] {
                try db.execute(
                    sql: """
                        INSERT INTO libraryItem (id, title, pluginId, isAnime, rawPayload)
                        VALUES (?, ?, 'plugin', 0, x'')
                        """,
                    arguments: [id, id]
                )
            }
            try db.execute(sql: """
                INSERT INTO libraryCategory (id, name, sortOrder, isSystemCategory, createdAt)
                VALUES ('reading', 'Reading', 1, 0, '2026-01-01 00:00:00.000')
                """)
            try db.execute(sql: """
                INSERT INTO itemCategoryLink (itemId, categoryId, addedAt)
                VALUES ('listed', 'reading', '2026-01-01 00:00:00.000')
                """)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let systemIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM libraryCategory WHERE isSystemCategory = 1"
            )
            #expect(systemIDs.count == 1)
            let links = try Row.fetchAll(
                db,
                sql: "SELECT itemId, categoryId FROM itemCategoryLink ORDER BY itemId"
            ).map { [$0["itemId"] as String, $0["categoryId"] as String] }
            #expect(links == [["listed", "reading"], ["listless", systemIDs.first ?? ""]])
        }
    }

}
