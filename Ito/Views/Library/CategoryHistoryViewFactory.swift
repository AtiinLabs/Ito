import SwiftUI

@MainActor
struct CategoryHistoryViewFactory {
    private let dependencies: PreparedCategoryHistoryDependencies
    private let messagePresenter: any CategoryHistoryMessagePresenting
    private let presentationLogger: any PresentationEventLogging

    init(
        dependencies: PreparedCategoryHistoryDependencies,
        messagePresenter: any CategoryHistoryMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
    }

    func makeCategoryAssignmentViewModel(itemID: String) -> CategoryAssignmentViewModel {
        CategoryAssignmentViewModel(
            itemID: itemID,
            organization: dependencies.organization,
            messagePresenter: messagePresenter,
            presentationLogger: presentationLogger
        )
    }

    func makeCategoryAssignmentSheet(itemID: String) -> CategoryAssignmentSheet {
        CategoryAssignmentSheet(viewModel: makeCategoryAssignmentViewModel(itemID: itemID))
    }

    func makeCategorySettingsViewModel() -> CategorySettingsViewModel {
        CategorySettingsViewModel(
            organization: dependencies.organization,
            messagePresenter: messagePresenter,
            presentationLogger: presentationLogger
        )
    }

    func makeCategorySettingsView() -> CategorySettingsView {
        CategorySettingsView(viewModel: makeCategorySettingsViewModel())
    }

    func makeHistoryViewModel() -> HistoryViewModel {
        HistoryViewModel(
            historyService: dependencies.history,
            sourceNames: dependencies.sourceNames,
            messagePresenter: messagePresenter,
            presentationLogger: presentationLogger
        )
    }

    func makeHistoryView() -> HistoryView {
        HistoryView(viewModel: makeHistoryViewModel())
    }
}
