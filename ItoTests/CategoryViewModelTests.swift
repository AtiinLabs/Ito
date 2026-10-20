import XCTest
@testable import Ito

@MainActor
final class CategoryViewModelTests: XCTestCase {
    private let system = pr11bCategory(
        id: "system",
        name: "Uncategorized",
        order: 0,
        isSystem: true
    )
    private let alpha = pr11bCategory(id: "alpha", name: "Alpha", order: 1)
    private let beta = pr11bCategory(id: "beta", name: "Beta", order: 2)
    private let gamma = pr11bCategory(id: "gamma", name: "Gamma", order: 3)

    func testSettingsDerivesPinnedSystemAndAuthoritativeUserCategories() {
        let (viewModel, service, _, _) = makeSettings()

        XCTAssertEqual(viewModel.systemCategory?.id, "system")
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta"])

        let renamed = pr11bCategory(id: "alpha", name: "Externally Renamed", order: 2)
        let created = pr11bCategory(id: "external", name: "External", order: 1)
        service.publish(categories: [system, created, renamed])

        XCTAssertEqual(viewModel.categories.map(\.id), ["system", "external", "alpha"])
        XCTAssertEqual(viewModel.userCategories.map(\.name), ["External", "Externally Renamed"])
    }

    func testSettingsAddSheetOpenCancelAndExistingNameRules() {
        let (viewModel, _, _, _) = makeSettings()

        viewModel.presentAddCategory()
        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertFalse(viewModel.canCreateCategory)

        viewModel.newCategoryName = "  \n "
        XCTAssertFalse(viewModel.canCreateCategory)
        viewModel.newCategoryName = "  Name  "
        XCTAssertTrue(viewModel.canCreateCategory)

        viewModel.cancelAddCategory()
        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "")
    }

    func testSettingsCreateAwaitsPublicationThenDismissesAndPreservesExactName() async {
        let (viewModel, service, _, logger) = makeSettings()
        service.createResponses = [.immediate(.success("new"))]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "  New List  "

        await viewModel.createCategory()

        XCTAssertEqual(service.createdNames, ["  New List  "])
        XCTAssertEqual(viewModel.categories.last?.id, "new")
        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "")
        XCTAssertEqual(logger.events.map(\.kind), [.categoryCreate, .categoryCreate])
        XCTAssertEqual(logger.events.last?.outcome, .succeeded)
    }

    func testSettingsCreateFailureIsRetryableAndDoesNotDismissOrClearInput() async {
        let (viewModel, service, messages, _) = makeSettings()
        service.createResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected)),
            .immediate(.success("retry"))
        ]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "Retry Me"

        await viewModel.createCategory()

        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "Retry Me")
        XCTAssertEqual(viewModel.failure, .categoryCreateFailed)
        XCTAssertEqual(messages.messages, [.categoryCreateFailed])

        await viewModel.createCategory()
        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.categories.last?.id, "retry")
    }

    func testSettingsSuppressesDuplicateCreateAndStaleCompletionCannotDismissAfterCancel() async {
        let (viewModel, service, _, _) = makeSettings()
        service.createResponses = [.suspended]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "One"

        let first = Task { await viewModel.createCategory() }
        await waitUntil { service.pendingCreateCount == 1 }
        await viewModel.createCategory()
        XCTAssertEqual(service.createdNames, ["One"])

        viewModel.cancelAddCategory()
        service.resolveCreate(at: 0, result: .success("one"))
        await first.value

        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertNil(viewModel.failure)
        viewModel.presentAddCategory()
        XCTAssertTrue(viewModel.isAddCategoryPresented)
    }

    func testSettingsRenameInitializesExactIdentityAndAwaitsDurableSuccess() async {
        let (viewModel, service, _, _) = makeSettings()

        viewModel.beginRename(categoryID: "alpha")
        XCTAssertEqual(viewModel.editingCategoryID, "alpha")
        XCTAssertEqual(viewModel.editedCategoryName, "Alpha")
        viewModel.editedCategoryName = " Renamed "

        await viewModel.saveRename()

        XCTAssertEqual(service.renameRequests.first?.id, "alpha")
        XCTAssertEqual(service.renameRequests.first?.name, " Renamed ")
        XCTAssertEqual(viewModel.categories.first { $0.id == "alpha" }?.name, " Renamed ")
        XCTAssertEqual(viewModel.renameDismissalID, "alpha")
        viewModel.consumeRenameDismissal(categoryID: "alpha")
        XCTAssertNil(viewModel.editingCategoryID)
    }

    func testSettingsRenameFailureDoesNotDismissAndDuplicateSaveIsSuppressed() async {
        let (viewModel, service, messages, _) = makeSettings()
        service.renameResponses = [.suspended, .immediate(.success(()))]
        viewModel.beginRename(categoryID: "alpha")
        viewModel.editedCategoryName = "Retry"

        let first = Task { await viewModel.saveRename() }
        await waitUntil { service.pendingRenameCount == 1 }
        await viewModel.saveRename()
        XCTAssertEqual(service.renameRequests.count, 1)

        service.resolveRename(
            at: 0,
            result: .failure(CategoryHistoryTestFailure.expected)
        )
        await first.value

        XCTAssertEqual(viewModel.failure, .categoryRenameFailed)
        XCTAssertEqual(messages.messages, [.categoryRenameFailed])
        XCTAssertEqual(viewModel.editingCategoryID, "alpha")
        XCTAssertNil(viewModel.renameDismissalID)

        await viewModel.saveRename()
        XCTAssertEqual(viewModel.renameDismissalID, "alpha")
    }

    func testSettingsBeginRenameForAnotherCategoryWorksWhileRenameIsSaving() async {
        let (viewModel, service, _, _) = makeSettings()
        service.renameResponses = [.suspended]
        viewModel.beginRename(categoryID: "alpha")
        viewModel.editedCategoryName = "Alpha Edited"

        let first = Task { await viewModel.saveRename() }
        await waitUntil { service.pendingRenameCount == 1 }
        viewModel.endRename(categoryID: "alpha")
        viewModel.beginRename(categoryID: "beta")

        XCTAssertEqual(viewModel.editingCategoryID, "beta")
        XCTAssertEqual(viewModel.editedCategoryName, "Beta")

        service.resolveRename(at: 0, result: .success(()))
        await first.value

        XCTAssertEqual(viewModel.editingCategoryID, "beta")
        XCTAssertEqual(viewModel.editedCategoryName, "Beta")
        XCTAssertNil(viewModel.renameDismissalID)
        XCTAssertTrue(viewModel.canSaveRename)
    }

    func testSettingsNormalizesRenameAndDeleteWhenCategoryDisappears() {
        let (viewModel, service, _, _) = makeSettings()
        viewModel.beginRename(categoryID: "alpha")
        viewModel.requestDelete(categoryID: "alpha")

        service.publish(categories: [system, beta])

        XCTAssertNil(viewModel.editingCategoryID)
        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertNil(viewModel.renameDismissalID)
    }

    func testSettingsDeleteConfirmationUsesExactIdentityAndCancelWritesNothing() {
        let (viewModel, service, _, _) = makeSettings()

        viewModel.requestDelete(categoryID: "alpha")
        XCTAssertEqual(viewModel.categoryPendingDeletion?.id, "alpha")
        viewModel.cancelDelete()

        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertTrue(service.deleteRequests.isEmpty)
    }

    func testSettingsSystemDeleteIsUnavailable() {
        let (viewModel, service, _, _) = makeSettings()

        viewModel.requestDelete(categoryID: "system")
        viewModel.confirmDelete()

        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertTrue(service.deleteRequests.isEmpty)
    }

    func testSettingsDeleteConfirmationClearsOnConfirmAndCategoryRemainsUntilPublication() async {
        let (viewModel, service, _, _) = makeSettings()
        service.deleteResponses = [.suspended]
        viewModel.requestDelete(categoryID: "alpha")
        viewModel.confirmDelete()

        await waitUntil { service.pendingDeleteCount == 1 }
        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertTrue(viewModel.isDeleting)
        XCTAssertTrue(viewModel.categories.contains { $0.id == "alpha" })

        viewModel.cancelDelete()
        XCTAssertTrue(viewModel.isDeleting)

        service.resolveDelete(at: 0, result: .success(()))
        await waitUntil { !viewModel.isDeleting }

        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertFalse(viewModel.categories.contains { $0.id == "alpha" })
        XCTAssertEqual(service.deleteRequests, ["alpha"])
    }

    func testSettingsDeleteFailureLeavesNoPendingDeletionAndCanBeRequestedAgain() async {
        let (viewModel, service, messages, _) = makeSettings()
        service.deleteResponses = [.suspended]
        viewModel.requestDelete(categoryID: "alpha")
        viewModel.confirmDelete()
        await waitUntil { service.pendingDeleteCount == 1 }

        viewModel.confirmDelete()
        XCTAssertEqual(service.deleteRequests, ["alpha"])
        service.resolveDelete(
            at: 0,
            result: .failure(CategoryHistoryTestFailure.expected)
        )
        await waitUntil { !viewModel.isDeleting }

        XCTAssertNil(viewModel.categoryPendingDeletionID)
        XCTAssertTrue(viewModel.categories.contains { $0.id == "alpha" })
        XCTAssertEqual(viewModel.failure, .categoryDeleteFailed)
        XCTAssertEqual(messages.messages, [.categoryDeleteFailed])

        viewModel.requestDelete(categoryID: "alpha")
        XCTAssertEqual(viewModel.categoryPendingDeletionID, "alpha")
        XCTAssertNil(viewModel.failure)
    }

    func testSettingsReorderPinsSystemAndPublishesRequestedRelativeOrder() async {
        let (viewModel, service, _, _) = makeSettings(categories: [system, alpha, beta, gamma])

        viewModel.moveUserCategories(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["beta", "gamma", "alpha"])
        await waitUntil { !viewModel.isReordering }

        XCTAssertEqual(service.reorderRequests, [["beta", "gamma", "alpha"]])
        XCTAssertEqual(viewModel.categories.map(\.id), ["system", "beta", "gamma", "alpha"])
        XCTAssertEqual(viewModel.categories.map(\.sortOrder), [0, 1, 2, 3])
    }

    func testSettingsReorderFailureConvergesToAuthoritativeOrder() async {
        let (viewModel, service, messages, _) = makeSettings()
        service.reorderResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected))
        ]

        viewModel.moveUserCategories(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["beta", "alpha"])
        await waitUntil { !viewModel.isReordering }

        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(viewModel.failure, .categoryReorderFailed)
        XCTAssertEqual(messages.messages, [.categoryReorderFailed])
    }

    func testSettingsRapidReordersSerializeAndOlderCompletionCannotRevertNewerOrder() async {
        let (viewModel, service, _, _) = makeSettings(categories: [system, alpha, beta, gamma])
        service.reorderResponses = [.suspended]

        viewModel.moveUserCategories(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        await waitUntil { service.pendingReorderCount == 1 }
        viewModel.moveUserCategories(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta", "gamma"])

        service.resolveReorder(at: 0, result: .success(()))
        await waitUntil { !viewModel.isReordering }

        XCTAssertEqual(
            service.reorderRequests,
            [["beta", "gamma", "alpha"], ["alpha", "beta", "gamma"]]
        )
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta", "gamma"])
    }

    func testAssignmentOwnsExactItemAndDerivesAuthoritativeUserCategoriesAndLinks() {
        let links = [ItemCategoryLink(itemId: "item", categoryId: "alpha")]
        let (viewModel, service, _, _) = makeAssignment(links: links)

        XCTAssertEqual(viewModel.itemID, "item")
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["alpha", "beta"])
        XCTAssertFalse(viewModel.userCategories.contains(where: \.isSystemCategory))
        XCTAssertEqual(viewModel.activeCategoryIDs, ["alpha"])

        service.publish(
            categories: [system, beta, gamma],
            links: [ItemCategoryLink(itemId: "item", categoryId: "gamma")]
        )
        XCTAssertEqual(viewModel.userCategories.map(\.id), ["beta", "gamma"])
        XCTAssertEqual(viewModel.activeCategoryIDs, ["gamma"])
    }

    func testAssignmentAddRemovesUncategorizedOnlyAfterSuccess() async {
        let links = [ItemCategoryLink(itemId: "item", categoryId: "system")]
        let (viewModel, service, _, _) = makeAssignment(links: links)
        service.toggleResponses = [.suspended]

        let task = Task { await viewModel.toggleCategory(categoryID: "alpha") }
        await waitUntil { service.pendingToggleCount == 1 }
        XCTAssertEqual(viewModel.activeCategoryIDs, ["system"])

        service.resolveToggle(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(viewModel.activeCategoryIDs, ["alpha"])
        XCTAssertEqual(service.toggleRequests.first?.itemID, "item")
        XCTAssertEqual(service.toggleRequests.first?.categoryID, "alpha")
    }

    func testAssignmentRemovingFinalCustomRestoresUncategorized() async {
        let links = [ItemCategoryLink(itemId: "item", categoryId: "alpha")]
        let (viewModel, _, _, _) = makeAssignment(links: links)

        await viewModel.toggleCategory(categoryID: "alpha")

        XCTAssertEqual(viewModel.activeCategoryIDs, ["system"])
    }

    func testAssignmentFailureKeepsAuthoritativeCheckmarkAndIsRetryable() async {
        let links = [ItemCategoryLink(itemId: "item", categoryId: "system")]
        let (viewModel, service, messages, _) = makeAssignment(links: links)
        service.toggleResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected)),
            .immediate(.success(()))
        ]

        await viewModel.toggleCategory(categoryID: "alpha")
        XCTAssertEqual(viewModel.activeCategoryIDs, ["system"])
        XCTAssertEqual(viewModel.failure, .categoryAssignmentFailed)
        XCTAssertEqual(messages.messages, [.categoryAssignmentFailed])

        await viewModel.toggleCategory(categoryID: "alpha")
        XCTAssertEqual(viewModel.activeCategoryIDs, ["alpha"])
    }

    func testAssignmentSuppressesDuplicateSameCategoryToggle() async {
        let (viewModel, service, _, _) = makeAssignment()
        service.toggleResponses = [.suspended]

        let first = Task { await viewModel.toggleCategory(categoryID: "alpha") }
        await waitUntil { service.pendingToggleCount == 1 }
        await viewModel.toggleCategory(categoryID: "alpha")
        XCTAssertEqual(service.toggleRequests.count, 1)

        service.resolveToggle(at: 0, result: .success(()))
        await first.value
        XCTAssertFalse(viewModel.assigningCategoryIDs.contains("alpha"))
    }

    func testAssignmentDismissalPreventsStaleFailurePresentation() async {
        let (viewModel, service, messages, _) = makeAssignment()
        service.toggleResponses = [.suspended]
        let task = Task { await viewModel.toggleCategory(categoryID: "alpha") }
        await waitUntil { service.pendingToggleCount == 1 }

        viewModel.dismissPresentation()
        service.resolveToggle(
            at: 0,
            result: .failure(CategoryHistoryTestFailure.expected)
        )
        await task.value

        XCTAssertNil(viewModel.failure)
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testAssignmentNewListCancelAndNameRules() {
        let (viewModel, _, _, _) = makeAssignment()

        viewModel.presentAddCategory()
        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertFalse(viewModel.canCreateAndAssign)
        viewModel.newCategoryName = "  "
        XCTAssertFalse(viewModel.canCreateAndAssign)
        viewModel.newCategoryName = " List "
        XCTAssertTrue(viewModel.canCreateAndAssign)
        viewModel.cancelAddCategory()

        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "")
    }

    func testAssignmentCreateAndAssignPublishesTruthThenSetsScrollIdentity() async {
        let links = [ItemCategoryLink(itemId: "item", categoryId: "system")]
        let (viewModel, service, _, _) = makeAssignment(links: links)
        service.createAndAssignResponses = [.immediate(.success("new"))]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = " New "

        await viewModel.createAndAssignCategory()

        XCTAssertEqual(service.createAndAssignRequests.first?.name, " New ")
        XCTAssertEqual(service.createAndAssignRequests.first?.itemID, "item")
        XCTAssertTrue(viewModel.userCategories.contains { $0.id == "new" })
        XCTAssertEqual(viewModel.activeCategoryIDs, ["new"])
        XCTAssertEqual(viewModel.newlyCreatedCategoryID, "new")
        XCTAssertFalse(viewModel.isAddCategoryPresented)
        viewModel.consumeNewlyCreatedCategoryID("new")
        XCTAssertNil(viewModel.newlyCreatedCategoryID)
    }

    func testAssignmentCreateAndAssignFailureDoesNotPresentFullSuccessAndRetries() async {
        let (viewModel, service, messages, _) = makeAssignment()
        service.createAndAssignResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected)),
            .immediate(.success("retry"))
        ]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "Retry"

        await viewModel.createAndAssignCategory()

        XCTAssertTrue(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "Retry")
        XCTAssertNil(viewModel.newlyCreatedCategoryID)
        XCTAssertEqual(viewModel.failure, .categoryCreateAndAssignFailed)
        XCTAssertEqual(messages.messages, [.categoryCreateAndAssignFailed])

        await viewModel.createAndAssignCategory()
        XCTAssertEqual(viewModel.newlyCreatedCategoryID, "retry")
    }

    func testAssignmentSuppressesDuplicateCreateAndAssignAndDismissalDropsStaleScroll() async {
        let (viewModel, service, _, _) = makeAssignment()
        service.createAndAssignResponses = [.suspended]
        viewModel.presentAddCategory()
        viewModel.newCategoryName = "One"

        let first = Task { await viewModel.createAndAssignCategory() }
        await waitUntil { service.pendingCreateAndAssignCount == 1 }
        await viewModel.createAndAssignCategory()
        XCTAssertEqual(service.createAndAssignRequests.count, 1)

        viewModel.dismissPresentation()
        service.resolveCreateAndAssign(at: 0, result: .success("one"))
        await first.value

        XCTAssertNil(viewModel.newlyCreatedCategoryID)
        XCTAssertFalse(viewModel.isAddCategoryPresented)
        XCTAssertEqual(viewModel.newCategoryName, "")
    }

    private func makeSettings(
        categories: [LibraryCategory]? = nil,
        links: [ItemCategoryLink] = []
    ) -> (
        CategorySettingsViewModel,
        LibraryOrganizationFake,
        CategoryHistoryMessageSpy,
        CategoryHistoryPresentationLogSpy
    ) {
        let service = LibraryOrganizationFake(
            snapshot: .init(categories: categories ?? [system, alpha, beta], links: links)
        )
        let messages = CategoryHistoryMessageSpy()
        let logger = CategoryHistoryPresentationLogSpy()
        return (
            CategorySettingsViewModel(
                organization: service,
                messagePresenter: messages,
                presentationLogger: logger
            ),
            service,
            messages,
            logger
        )
    }

    private func makeAssignment(
        categories: [LibraryCategory]? = nil,
        links: [ItemCategoryLink] = []
    ) -> (
        CategoryAssignmentViewModel,
        LibraryOrganizationFake,
        CategoryHistoryMessageSpy,
        CategoryHistoryPresentationLogSpy
    ) {
        let service = LibraryOrganizationFake(
            snapshot: .init(categories: categories ?? [system, alpha, beta], links: links)
        )
        let messages = CategoryHistoryMessageSpy()
        let logger = CategoryHistoryPresentationLogSpy()
        return (
            CategoryAssignmentViewModel(
                itemID: "item",
                organization: service,
                messagePresenter: messages,
                presentationLogger: logger
            ),
            service,
            messages,
            logger
        )
    }
}
