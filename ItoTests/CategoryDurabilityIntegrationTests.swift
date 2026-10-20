import Combine
import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class CategoryDurabilityIntegrationTests: XCTestCase {
    func testCreateCommitsPublishesExactNameAndFailureRollsBackWithoutFalseSuccess() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        let createdID = try await manager.createCategory(name: "  Duplicate  ")

        let persisted = try await database.dbPool.read { db in
            try LibraryCategory.fetchOne(db, key: createdID)
        }
        XCTAssertEqual(persisted?.name, "  Duplicate  ")
        XCTAssertEqual(persisted?.sortOrder, 3)
        XCTAssertEqual(manager.categories.first { $0.id == createdID }, persisted)

        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_category_create
                AFTER INSERT ON libraryCategory
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected category create failure');
                END
                """)
        }
        let messages = CategoryHistoryMessageSpy()
        let viewModel = CategorySettingsViewModel(
            organization: manager,
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "Will Roll Back"

        await viewModel.createCategory()

        let rolledBackCount = try await database.dbPool.read { db in
            try LibraryCategory
                .filter(LibraryCategory.Columns.name == "Will Roll Back")
                .fetchCount(db)
        }
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertFalse(manager.categories.contains { $0.name == "Will Roll Back" })
        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "Will Roll Back")
        XCTAssertEqual(viewModel.failure, .categoryCreateFailed)
        XCTAssertEqual(messages.messages, [.categoryCreateFailed])
        XCTAssertTrue(manager.categories.contains { $0.id == fixture.system.id })
    }

    func testCreateDoesNotPublishBeforeCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        _ = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let gate = CategoryHistoryDatabaseWriteGate()
        defer { gate.release() }
        try await database.dbPool.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction(
                "wait_for_category_create_commit",
                argumentCount: 0,
                pure: false
            ) { _ in
                gate.blockWriter()
                return nil
            })
            try db.execute(sql: """
                CREATE TRIGGER wait_before_category_create_commit
                AFTER INSERT ON libraryCategory
                BEGIN
                    SELECT wait_for_category_create_commit();
                END
                """)
        }
        var published = false
        let subscription = manager.$categories.sink { categories in
            if categories.contains(where: { $0.name == "Committed" }) { published = true }
        }
        defer { subscription.cancel() }

        let operation = Task { try await manager.createCategory(name: "Committed") }
        let didBlockBeforeCommit = await gate.waitUntilBlocked(timeout: 2)
        XCTAssertTrue(didBlockBeforeCommit)
        XCTAssertFalse(published)
        XCTAssertFalse(manager.categories.contains { $0.name == "Committed" })

        gate.release()
        let categoryID = try await operation.value
        XCTAssertTrue(published)
        XCTAssertTrue(manager.categories.contains { $0.id == categoryID })
    }

    func testRenameReusesDurableBoundaryAndViewModelFailureDoesNotDismiss() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_category_rename_for_view_model
                AFTER UPDATE OF name ON libraryCategory
                WHEN NEW.id = 'alpha'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected category rename failure');
                END
                """)
        }
        let messages = CategoryHistoryMessageSpy()
        let viewModel = CategorySettingsViewModel(
            organization: manager,
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )
        viewModel.beginRename(categoryID: fixture.alpha.id)
        viewModel.editedCategoryName = "Renamed"

        await viewModel.saveRename()

        let failedName = try await database.dbPool.read { db in
            try LibraryCategory.fetchOne(db, key: fixture.alpha.id)?.name
        }
        XCTAssertEqual(failedName, fixture.alpha.name)
        XCTAssertEqual(manager.categories.first { $0.id == fixture.alpha.id }?.name, fixture.alpha.name)
        XCTAssertEqual(viewModel.editingCategoryID, fixture.alpha.id)
        XCTAssertNil(viewModel.renameDismissalID)
        XCTAssertEqual(viewModel.failure, .categoryRenameFailed)
        XCTAssertEqual(messages.messages, [.categoryRenameFailed])

        try await database.dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER fail_category_rename_for_view_model")
        }
        await viewModel.saveRename()
        let committedName = try await database.dbPool.read { db in
            try LibraryCategory.fetchOne(db, key: fixture.alpha.id)?.name
        }
        XCTAssertEqual(committedName, "Renamed")
        XCTAssertEqual(manager.categories.first { $0.id == fixture.alpha.id }?.name, "Renamed")
        XCTAssertEqual(viewModel.renameDismissalID, fixture.alpha.id)
    }

    func testDurableNameBoundariesPreserveDuplicatesCaseAndNonemptyWhitespace() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        let duplicateID = try await manager.createCategory(name: "Alpha")
        let caseVariantID = try await manager.createCategory(name: "alpha")
        try await manager.renameCategory(id: fixture.beta.id, to: "  Alpha  ")

        let categories = try await database.dbPool.read(LibraryCategory.fetchAll)
        XCTAssertEqual(categories.filter { $0.name == "Alpha" }.count, 2)
        XCTAssertTrue(categories.contains { $0.id == caseVariantID && $0.name == "alpha" })
        XCTAssertTrue(categories.contains { $0.id == duplicateID && $0.name == "Alpha" })
        XCTAssertEqual(categories.first { $0.id == fixture.beta.id }?.name, "  Alpha  ")
        XCTAssertEqual(manager.categories.first { $0.id == fixture.beta.id }?.name, "  Alpha  ")
    }

    func testDeleteCommitsCascadeOrphanReassignmentAndProtectsSystemCategory() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        try await manager.deleteCategoryDurably(id: fixture.alpha.id)

        let persisted = try await readOrganization(from: database)
        XCTAssertEqual(persisted.categories.map(\.id), [fixture.system.id, fixture.beta.id])
        XCTAssertEqual(
            linkPairs(persisted.links),
            Set([
                "item-alpha|system",
                "item-both|beta",
                "item-beta|beta"
            ])
        )
        XCTAssertEqual(manager.categories, persisted.categories)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(persisted.links))

        try await manager.deleteCategoryDurably(id: fixture.system.id)
        let afterSystemAttempt = try await readOrganization(from: database)
        XCTAssertTrue(afterSystemAttempt.categories.contains { $0.id == fixture.system.id })
        XCTAssertEqual(manager.categories, afterSystemAttempt.categories)
    }

    func testDeleteFailureInsideOrphanReassignmentRollsBackAndViewModelStaysTruthful() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let before = try await readOrganization(from: database)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_category_delete_after_orphan_reassignment
                AFTER INSERT ON itemCategoryLink
                WHEN NEW.categoryId = 'system'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected category delete failure');
                END
                """)
        }
        let messages = CategoryHistoryMessageSpy()
        let viewModel = CategorySettingsViewModel(
            organization: manager,
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )
        viewModel.requestDelete(categoryID: fixture.alpha.id)
        viewModel.confirmDelete()
        await waitUntil { !viewModel.isDeleting }

        let after = try await readOrganization(from: database)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(linkPairs(after.links), linkPairs(before.links))
        XCTAssertEqual(manager.categories, before.categories)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(before.links))
        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertEqual(viewModel.failure, .categoryDeleteFailed)
        XCTAssertEqual(messages.messages, [.categoryDeleteFailed])
    }

    func testReorderCommitsCompleteExactOrderAndPublishes() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        try await manager.reorderCategoriesDurably(
            userCategoryIDs: [fixture.beta.id, fixture.alpha.id]
        )

        let categories = try await database.dbPool.read { db in
            try LibraryCategory.order(LibraryCategory.Columns.sortOrder).fetchAll(db)
        }
        XCTAssertEqual(categories.map(\.id), ["system", "beta", "alpha"])
        XCTAssertEqual(categories.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(manager.categories, categories)
    }

    func testReorderFailureRollsBackEveryRowAndViewModelConverges() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        _ = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let before = manager.categories
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_category_reorder_mid_transaction
                BEFORE UPDATE OF sortOrder ON libraryCategory
                WHEN NEW.id = 'beta'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected category reorder failure');
                END
                """)
        }
        let viewModel = CategorySettingsViewModel(
            organization: manager,
            messagePresenter: CategoryHistoryMessageSpy(),
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )

        viewModel.moveUserCategories(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        await waitUntil { !viewModel.isReordering }

        let persisted = try await database.dbPool.read { db in
            try LibraryCategory.order(LibraryCategory.Columns.sortOrder).fetchAll(db)
        }
        XCTAssertEqual(persisted, before)
        XCTAssertEqual(manager.categories, before)
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(viewModel.failure, .categoryReorderFailed)
    }

    func testAssignmentAddAndRemoveCommitUncategorizedInvariantAndPublish() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        try await manager.toggleCategoryDurably(
            forItemID: fixture.itemAlpha.id,
            categoryID: fixture.beta.id
        )
        var persistedLinks = try await database.dbPool.read(ItemCategoryLink.fetchAll)
        XCTAssertEqual(
            itemCategoryIDs(fixture.itemAlpha.id, links: persistedLinks),
            [fixture.alpha.id, fixture.beta.id]
        )
        XCTAssertEqual(linkPairs(manager.links), linkPairs(persistedLinks))

        try await manager.toggleCategoryDurably(
            forItemID: fixture.itemAlpha.id,
            categoryID: fixture.alpha.id
        )
        try await manager.toggleCategoryDurably(
            forItemID: fixture.itemAlpha.id,
            categoryID: fixture.beta.id
        )
        persistedLinks = try await database.dbPool.read(ItemCategoryLink.fetchAll)
        XCTAssertEqual(
            itemCategoryIDs(fixture.itemAlpha.id, links: persistedLinks),
            [fixture.system.id]
        )
        XCTAssertEqual(linkPairs(manager.links), linkPairs(persistedLinks))

        try await manager.toggleCategoryDurably(
            forItemID: fixture.itemBeta.id,
            categoryID: fixture.alpha.id
        )
        persistedLinks = try await database.dbPool.read(ItemCategoryLink.fetchAll)
        XCTAssertEqual(
            itemCategoryIDs(fixture.itemBeta.id, links: persistedLinks),
            [fixture.alpha.id, fixture.beta.id]
        )
    }

    func testAssignmentAddFailureRollsBackInsertAndUncategorizedRemovalWithoutFalseCheckmark() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        try await database.dbPool.write { db in
            try ItemCategoryLink
                .filter(ItemCategoryLink.Columns.itemId == fixture.itemAlpha.id)
                .deleteAll(db)
            try ItemCategoryLink(
                itemId: fixture.itemAlpha.id,
                categoryId: fixture.system.id
            ).insert(db)
            try db.execute(sql: """
                CREATE TRIGGER fail_assignment_after_uncategorized_removal
                AFTER DELETE ON itemCategoryLink
                WHEN OLD.itemId = 'item-alpha' AND OLD.categoryId = 'system'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected assignment add failure');
                END
                """)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let messages = CategoryHistoryMessageSpy()
        let viewModel = CategoryAssignmentViewModel(
            itemID: fixture.itemAlpha.id,
            organization: manager,
            messagePresenter: messages,
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )

        await viewModel.toggleCategory(categoryID: fixture.alpha.id)

        let links = try await database.dbPool.read(ItemCategoryLink.fetchAll)
        XCTAssertEqual(itemCategoryIDs(fixture.itemAlpha.id, links: links), [fixture.system.id])
        XCTAssertEqual(viewModel.activeCategoryIDs, [fixture.system.id])
        XCTAssertFalse(viewModel.isAssigned(to: fixture.alpha.id))
        XCTAssertEqual(viewModel.failure, .categoryAssignmentFailed)
        XCTAssertEqual(messages.messages, [.categoryAssignmentFailed])
    }

    func testAssignmentRemoveFailureRollsBackRemovalAndUncategorizedRestoration() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_assignment_after_uncategorized_restore
                AFTER INSERT ON itemCategoryLink
                WHEN NEW.itemId = 'item-alpha' AND NEW.categoryId = 'system'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected assignment remove failure');
                END
                """)
        }
        let viewModel = CategoryAssignmentViewModel(
            itemID: fixture.itemAlpha.id,
            organization: manager,
            messagePresenter: CategoryHistoryMessageSpy(),
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )

        await viewModel.toggleCategory(categoryID: fixture.alpha.id)

        let links = try await database.dbPool.read(ItemCategoryLink.fetchAll)
        XCTAssertEqual(itemCategoryIDs(fixture.itemAlpha.id, links: links), [fixture.alpha.id])
        XCTAssertEqual(viewModel.activeCategoryIDs, [fixture.alpha.id])
        XCTAssertTrue(viewModel.isAssigned(to: fixture.alpha.id))
        XCTAssertEqual(viewModel.failure, .categoryAssignmentFailed)
    }

    func testCreateAndAssignCommitsAtomicallyPublishesAndReturnsIdentity() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        try await database.dbPool.write { db in
            try ItemCategoryLink
                .filter(ItemCategoryLink.Columns.itemId == fixture.itemAlpha.id)
                .deleteAll(db)
            try ItemCategoryLink(
                itemId: fixture.itemAlpha.id,
                categoryId: fixture.system.id
            ).insert(db)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()

        let categoryID = try await manager.createCategoryAndAssignDurably(
            name: "Created and Assigned",
            itemID: fixture.itemAlpha.id
        )

        let organization = try await readOrganization(from: database)
        XCTAssertEqual(
            organization.categories.first { $0.id == categoryID }?.name,
            "Created and Assigned"
        )
        XCTAssertEqual(
            itemCategoryIDs(fixture.itemAlpha.id, links: organization.links),
            [categoryID]
        )
        XCTAssertEqual(manager.categories, organization.categories)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(organization.links))
    }

    func testCreateAndAssignFailureRollsBackCategoryLinkAndUncategorizedRemoval() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fixture = try await seedOrganization(in: database)
        try await database.dbPool.write { db in
            try ItemCategoryLink
                .filter(ItemCategoryLink.Columns.itemId == fixture.itemAlpha.id)
                .deleteAll(db)
            try ItemCategoryLink(
                itemId: fixture.itemAlpha.id,
                categoryId: fixture.system.id
            ).insert(db)
            try db.execute(sql: """
                CREATE TRIGGER fail_create_and_assign_after_uncategorized_removal
                AFTER DELETE ON itemCategoryLink
                WHEN OLD.itemId = 'item-alpha' AND OLD.categoryId = 'system'
                BEGIN
                    SELECT RAISE(ROLLBACK, 'injected create and assign failure');
                END
                """)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let before = try await readOrganization(from: database)
        let viewModel = CategoryAssignmentViewModel(
            itemID: fixture.itemAlpha.id,
            organization: manager,
            messagePresenter: CategoryHistoryMessageSpy(),
            presentationLogger: CategoryHistoryPresentationLogSpy()
        )
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "Atomic Failure"

        await viewModel.createAndAssignCategory()

        let after = try await readOrganization(from: database)
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(linkPairs(after.links), linkPairs(before.links))
        XCTAssertEqual(manager.categories, before.categories)
        XCTAssertEqual(linkPairs(manager.links), linkPairs(before.links))
        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "Atomic Failure")
        XCTAssertNil(viewModel.newlyCreatedCategoryID)
        XCTAssertEqual(viewModel.failure, .categoryCreateAndAssignFailed)
    }

    private func seedOrganization(in database: TestDatabase) async throws -> CategoryFixture {
        let fixture = CategoryFixture()
        try await database.dbPool.write { db in
            try fixture.system.insert(db)
            try fixture.alpha.insert(db)
            try fixture.beta.insert(db)
            try fixture.itemAlpha.insert(db)
            try fixture.itemBoth.insert(db)
            try fixture.itemBeta.insert(db)
            try ItemCategoryLink(itemId: fixture.itemAlpha.id, categoryId: fixture.alpha.id).insert(db)
            try ItemCategoryLink(itemId: fixture.itemBoth.id, categoryId: fixture.alpha.id).insert(db)
            try ItemCategoryLink(itemId: fixture.itemBoth.id, categoryId: fixture.beta.id).insert(db)
            try ItemCategoryLink(itemId: fixture.itemBeta.id, categoryId: fixture.beta.id).insert(db)
        }
        return fixture
    }

    private func readOrganization(
        from database: TestDatabase
    ) async throws -> (categories: [LibraryCategory], links: [ItemCategoryLink]) {
        try await database.dbPool.read { db in
            (
                try LibraryCategory.order(LibraryCategory.Columns.sortOrder).fetchAll(db),
                try ItemCategoryLink.fetchAll(db)
            )
        }
    }

    private func linkPairs(_ links: [ItemCategoryLink]) -> Set<String> {
        Set(links.map { "\($0.itemId)|\($0.categoryId)" })
    }

    private func itemCategoryIDs(_ itemID: String, links: [ItemCategoryLink]) -> Set<String> {
        Set(links.filter { $0.itemId == itemID }.map(\.categoryId))
    }
}

private struct CategoryFixture {
    let system = pr11bCategory(
        id: "system",
        name: "Uncategorized",
        order: 0,
        isSystem: true
    )
    let alpha = pr11bCategory(id: "alpha", name: "Alpha", order: 1)
    let beta = pr11bCategory(id: "beta", name: "Beta", order: 2)
    let itemAlpha = pr11bLibraryItem(id: "item-alpha")
    let itemBoth = pr11bLibraryItem(id: "item-both")
    let itemBeta = pr11bLibraryItem(id: "item-beta")
}

private func pr11bLibraryItem(id: String) -> Ito.LibraryItem {
    Ito.LibraryItem(
        id: id,
        title: id,
        coverUrl: nil,
        pluginId: "plugin",
        isAnime: false,
        pluginType: .manga,
        rawPayload: Data(),
        anilistId: nil
    )
}

private final class CategoryHistoryDatabaseWriteGate: @unchecked Sendable {
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
