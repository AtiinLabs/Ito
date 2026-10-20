import Combine
import GRDB
import XCTest
@testable import Ito

@MainActor
final class HistoryDurabilityIntegrationTests: XCTestCase {
    func testDeleteCommitsExactRecordKeepsOthersAndPublishes() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = makeRecords()
        try await seed(records, in: database)
        let managers = try await makeManagers(database)

        try await managers.history.removeEntryDurably(id: records[0].id)

        let persisted = try await database.dbPool.read { db in
            try ReadingHistoryRecord
                .order(ReadingHistoryRecord.Columns.readAt.desc)
                .fetchAll(db)
        }
        XCTAssertEqual(persisted.map(\.id), [records[1].id, records[2].id])
        XCTAssertEqual(managers.history.history.map(\.record), persisted)
    }

    func testDeleteFailureRollsBackAndViewModelKeepsEntryVisible() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = makeRecords()
        try await seed(records, in: database)
        let managers = try await makeManagers(database)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_history_delete
                AFTER DELETE ON readingHistory
                WHEN OLD.id = 'newest'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected history delete failure');
                END
                """)
        }
        let messages = CategoryHistoryMessageSpy()
        let viewModel = HistoryViewModel(
            historyService: managers.history,
            sourceNames: HistorySourceNamesFake(),
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )

        await viewModel.deleteEntry(id: "newest")

        let persisted = try await database.dbPool.read(ReadingHistoryRecord.fetchAll)
        XCTAssertEqual(Set(persisted.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(Set(managers.history.history.map(\.id)), Set(records.map(\.id)))
        XCTAssertTrue(viewModel.history.contains { $0.id == "newest" })
        XCTAssertEqual(viewModel.failure, .historyDeleteFailed)
        XCTAssertEqual(messages.messages, [.historyDeleteFailed])
    }

    func testClearCommitsAllRecordsAndPublishesEmpty() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await seed(makeRecords(), in: database)
        let managers = try await makeManagers(database)

        try await managers.history.clearHistoryDurably()

        let persistedCount = try await database.dbPool.read(ReadingHistoryRecord.fetchCount)
        XCTAssertEqual(persistedCount, 0)
        XCTAssertTrue(managers.history.history.isEmpty)
    }

    func testStalePreClearObservationCannotOverwriteCommittedEmptyPublication() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await seed(makeRecords(), in: database)
        let scheduler = ManualHistoryObservationScheduler()
        let managers = try await makeManagers(database, observationScheduler: scheduler)

        try await database.dbPool.write { db in
            try pr11bHistoryRecord(id: "stale", readAt: 4).insert(db)
        }
        let stalePublication = await scheduler.nextPublication()

        try await managers.history.clearHistoryDurably()
        XCTAssertTrue(managers.history.history.isEmpty)

        stalePublication.run()
        XCTAssertTrue(managers.history.history.isEmpty)
    }

    func testStalePreDeleteObservationCannotRestoreDeletedEntry() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = makeRecords()
        try await seed(records, in: database)
        let scheduler = ManualHistoryObservationScheduler()
        let managers = try await makeManagers(database, observationScheduler: scheduler)

        try await database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE readingHistory SET chapterTitle = ? WHERE id = ?",
                arguments: ["Updated", records[2].id]
            )
        }
        let stalePublication = await scheduler.nextPublication()

        try await managers.history.removeEntryDurably(id: records[0].id)
        XCTAssertEqual(managers.history.history.map(\.id), [records[1].id, records[2].id])

        stalePublication.run()
        XCTAssertEqual(managers.history.history.map(\.id), [records[1].id, records[2].id])
    }

    func testLaterExternalCommitStillPublishesAfterDurableClear() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try await seed(makeRecords(), in: database)
        let scheduler = ManualHistoryObservationScheduler()
        let managers = try await makeManagers(database, observationScheduler: scheduler)

        try await managers.history.clearHistoryDurably()
        XCTAssertTrue(managers.history.history.isEmpty)
        let clearPublication = await scheduler.nextPublication()
        clearPublication.run()

        let laterRecord = pr11bHistoryRecord(id: "later", readAt: 4)
        try await database.dbPool.write { db in
            try laterRecord.insert(db)
        }
        let laterPublication = await scheduler.nextPublication()
        laterPublication.run()

        XCTAssertEqual(managers.history.history.map(\.record), [laterRecord])
    }

    func testLaterExternalCommitStillPublishesAfterDurableDelete() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = makeRecords()
        try await seed(records, in: database)
        let scheduler = ManualHistoryObservationScheduler()
        let managers = try await makeManagers(database, observationScheduler: scheduler)

        try await managers.history.removeEntryDurably(id: records[0].id)
        XCTAssertEqual(managers.history.history.map(\.id), [records[1].id, records[2].id])
        let deletePublication = await scheduler.nextPublication()
        deletePublication.run()

        let laterRecord = pr11bHistoryRecord(id: "later", readAt: 4)
        try await database.dbPool.write { db in
            try laterRecord.insert(db)
        }
        let laterPublication = await scheduler.nextPublication()
        laterPublication.run()

        XCTAssertEqual(
            managers.history.history.map(\.record),
            [laterRecord, records[1], records[2]]
        )
    }

    func testPublicationOrderRejectsOlderDurableCompletionAndAcceptsLaterExternalCommit() {
        var publicationOrder = HistoryPublicationOrder()

        XCTAssertTrue(publicationOrder.accepts(2), "Newer clear commit publishes")
        XCTAssertFalse(publicationOrder.accepts(1), "Older delete completion cannot overwrite clear")
        XCTAssertTrue(publicationOrder.accepts(3), "Later external commit remains observable")
        XCTAssertFalse(publicationOrder.accepts(2), "Older clear cleanup cannot overwrite external state")
    }

    func testClearFailureRollsBackAllDeletesAndViewModelDoesNotReportSuccess() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = makeRecords()
        try await seed(records, in: database)
        let managers = try await makeManagers(database)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_history_clear_mid_transaction
                AFTER DELETE ON readingHistory
                WHEN OLD.id = 'middle'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected history clear failure');
                END
                """)
        }
        let messages = CategoryHistoryMessageSpy()
        let viewModel = HistoryViewModel(
            historyService: managers.history,
            sourceNames: HistorySourceNamesFake(),
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )

        await viewModel.clearHistory()

        let persisted = try await database.dbPool.read(ReadingHistoryRecord.fetchAll)
        XCTAssertEqual(Set(persisted.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(Set(managers.history.history.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(Set(viewModel.history.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(viewModel.failure, .historyClearFailed)
        XCTAssertEqual(messages.messages, [.historyClearFailed])
    }

    func testClearDoesNotPublishBeforeCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let record = pr11bHistoryRecord(id: "only", readAt: 1)
        try await seed([record], in: database)
        let managers = try await makeManagers(database)
        let gate = HistoryDatabaseWriteGate()
        defer { gate.release() }
        try await database.dbPool.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction(
                "wait_for_history_clear_commit",
                argumentCount: 0,
                pure: false
            ) { _ in
                gate.blockWriter()
                return nil
            })
            try db.execute(sql: """
                CREATE TRIGGER wait_before_history_clear_commit
                AFTER DELETE ON readingHistory
                WHEN OLD.id = 'only'
                BEGIN
                    SELECT wait_for_history_clear_commit();
                END
                """)
        }
        var publishedEmpty = false
        let subscription = managers.history.$history.sink { history in
            if history.isEmpty { publishedEmpty = true }
        }
        defer { subscription.cancel() }
        publishedEmpty = false

        let operation = Task { try await managers.history.clearHistoryDurably() }
        let didBlockBeforeCommit = await gate.waitUntilBlocked(timeout: 2)
        XCTAssertTrue(didBlockBeforeCommit)
        XCTAssertFalse(publishedEmpty)
        XCTAssertEqual(managers.history.history.map(\.id), ["only"])

        gate.release()
        try await operation.value
        XCTAssertTrue(publishedEmpty)
        XCTAssertTrue(managers.history.history.isEmpty)
    }

    func testReloadPreservesDescendingReadAtOrderingAndTwoHundredRecordLimit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let records = (0..<205).map {
            pr11bHistoryRecord(id: "record-\($0)", readAt: TimeInterval($0))
        }
        try await seed(records, in: database)
        let managers = try await makeManagers(database)

        XCTAssertEqual(managers.history.history.count, 200)
        XCTAssertEqual(managers.history.history.first?.id, "record-204")
        XCTAssertEqual(managers.history.history.last?.id, "record-5")
        XCTAssertEqual(
            managers.history.history.map(\.record.readAt),
            managers.history.history.map(\.record.readAt).sorted(by: >)
        )
    }

    private func makeRecords() -> [ReadingHistoryRecord] {
        [
            pr11bHistoryRecord(id: "newest", readAt: 3),
            pr11bHistoryRecord(id: "middle", readAt: 2),
            pr11bHistoryRecord(id: "oldest", readAt: 1)
        ]
    }

    private func seed(
        _ records: [ReadingHistoryRecord],
        in database: TestDatabase
    ) async throws {
        try await database.dbPool.write { db in
            for record in records { try record.insert(db) }
        }
    }

    private func makeManagers(
        _ database: TestDatabase
    ) async throws -> (library: LibraryManager, history: HistoryManager) {
        let library = LibraryManager(dbPool: database.dbPool)
        let history = HistoryManager(dbPool: database.dbPool, libraryManager: library)
        try await history.reload()
        return (library, history)
    }

    private func makeManagers<Scheduler: ValueObservationMainActorScheduler>(
        _ database: TestDatabase,
        observationScheduler: Scheduler
    ) async throws -> (library: LibraryManager, history: HistoryManager) {
        let library = LibraryManager(dbPool: database.dbPool)
        let history = HistoryManager(
            dbPool: database.dbPool,
            libraryManager: library,
            observationScheduler: observationScheduler
        )
        try await history.reload()
        return (library, history)
    }
}

private func pr11bHistoryRecord(id: String, readAt: TimeInterval) -> ReadingHistoryRecord {
    ReadingHistoryRecord(
        id: id,
        mediaKey: "media-\(id)",
        title: "Title \(id)",
        coverUrl: nil,
        pluginId: "plugin",
        chapterKey: "chapter-\(id)",
        chapterTitle: "Chapter \(id)",
        readAt: Date(timeIntervalSince1970: readAt)
    )
}

private final class HistoryDatabaseWriteGate: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func blockWriter() {
        blocked.signal()
        resume.wait()
    }

    func waitUntilBlocked(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: self.blocked.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }

    func release() {
        resume.signal()
    }
}

nonisolated private final class ManualHistoryObservationScheduler: ValueObservationMainActorScheduler,
    @unchecked Sendable {
    nonisolated struct ScheduledPublication: @unchecked Sendable {
        let action: @MainActor () -> Void

        @MainActor
        func run() {
            action()
        }
    }

    private let lock = NSLock()
    private var publications: [ScheduledPublication] = []
    private var continuations: [CheckedContinuation<ScheduledPublication, Never>] = []

    func immediateInitialValue() -> Bool { true }

    func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        let publication = ScheduledPublication(action: action)
        lock.lock()
        if continuations.isEmpty {
            publications.append(publication)
            lock.unlock()
        } else {
            let continuation = continuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: publication)
        }
    }

    func nextPublication() async -> ScheduledPublication {
        await withCheckedContinuation { continuation in
            lock.lock()
            if publications.isEmpty {
                continuations.append(continuation)
                lock.unlock()
            } else {
                let publication = publications.removeFirst()
                lock.unlock()
                continuation.resume(returning: publication)
            }
        }
    }
}
