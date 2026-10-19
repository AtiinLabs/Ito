import Combine
import Foundation

enum AppMessageKind: Equatable {
    case browseUpdateFailed
    case browseDeleteFailed
    case browseDropLoadFailed
    case browseUnsupportedPluginFile
    case browsePluginDirectoryUnavailable
    case browseImportFailed(BrowseImportSource)
    case repositoryAdded
    case repositoryAlreadyAdded
    case repositoryAddFailed
    case repositoryRemoveFailed
    case repositoryRefreshFailed
    case repositoryInstallFailed
    case debugLogsCopied
    case sourceLoadFailed
    case sourceSearchFailed
    case pluginSettingsLoadFailed
    case pluginSettingsPersistenceFailed
    case pluginSettingsReloadFailed
    case sourceArchivedPluginDeleteFailed
    case discoverDetailRefreshFailed
    case trackingPreferencePersistenceFailed
    case trackingRemoteUpdateFailed
    case trackingLinkPersistenceFailed
    case trackingUnlinkFailed
    case trackingExternalPageOpenFailed
    case mediaDetailLoadFailed
    case mediaDetailSaveFailed
    case mediaDetailUnsaveFailed
    case mediaDetailSaved(actionToken: UUID)
    case mediaDetailTrackerProgressFailed
    case libraryLayoutPersistenceFailed
    case libraryItemRemovalFailed
    case libraryUpdateFailed
    case categoryCreateFailed
    case categoryRenameFailed
    case categoryDeleteFailed
    case categoryReorderFailed
    case categoryAssignmentFailed
    case categoryCreateAndAssignFailed
    case historyDeleteFailed
    case historyClearFailed
}

struct AppMessage: Identifiable, Equatable {
    let id: UUID
    let kind: AppMessageKind
}

struct AppMessagePresentation: Equatable {
    let style: ToastMessage.Style
    let title: String
    let detail: String?
    let actionTitle: String?
    let actionID: String?

    init(
        style: ToastMessage.Style,
        title: String,
        detail: String?,
        actionTitle: String? = nil,
        actionID: String? = nil
    ) {
        self.style = style
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.actionID = actionID
    }
}

extension AppMessageKind {
    var presentation: AppMessagePresentation {
        switch self {
        case .browseUpdateFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Update failed. Please try again."
            )
        case .browseDeleteFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to remove plugin. Please try again."
            )
        case .browseDropLoadFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to load dropped file."
            )
        case .browseUnsupportedPluginFile:
            return .init(
                style: .error,
                title: "Error",
                detail: "Please drop a valid .ito plugin file."
            )
        case .browsePluginDirectoryUnavailable:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to access plugins directory."
            )
        case .browseImportFailed(let source):
            let prefix = source == .drop ? "File copy error" : "URL Open error"
            return .init(
                style: .error,
                title: "Error",
                detail: "\(prefix): The plugin could not be imported."
            )
        case .repositoryAdded:
            return .init(
                style: .success,
                title: "Repository added",
                detail: nil
            )
        case .repositoryAlreadyAdded:
            return .init(
                style: .info,
                title: "Already added",
                detail: "This repository is already in your list."
            )
        case .repositoryAddFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to add repository. Please try again."
            )
        case .repositoryRemoveFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to remove repository. Please try again."
            )
        case .repositoryRefreshFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Some repositories could not be refreshed. Please try again."
            )
        case .repositoryInstallFailed:
            return .init(
                style: .error,
                title: "Error",
                detail: "Failed to install package. Please try again."
            )
        case .debugLogsCopied:
            return .init(
                style: .success,
                title: "Copied to clipboard",
                detail: nil
            )
        case .sourceLoadFailed:
            return .init(
                style: .error,
                title: "Failed to load source",
                detail: "Please try again."
            )
        case .sourceSearchFailed:
            return .init(
                style: .error,
                title: "Search failed",
                detail: "The source could not complete the search."
            )
        case .pluginSettingsLoadFailed:
            return .init(
                style: .error,
                title: "Settings unavailable",
                detail: "Plugin settings could not be loaded."
            )
        case .pluginSettingsPersistenceFailed:
            return .init(
                style: .error,
                title: "Settings not saved",
                detail: "The plugin setting could not be saved."
            )
        case .pluginSettingsReloadFailed:
            return .init(
                style: .error,
                title: "Settings reload failed",
                detail: "Plugin settings could not be reloaded."
            )
        case .sourceArchivedPluginDeleteFailed:
            return .init(
                style: .error,
                title: "Failed to remove plugin",
                detail: "Plugin removal encountered an error. Refresh plugin state before retrying."
            )
        case .discoverDetailRefreshFailed:
            return .init(
                style: .error,
                title: "Details unavailable",
                detail: "Full media details could not be refreshed. The available summary is still shown."
            )
        case .trackingPreferencePersistenceFailed:
            return .init(
                style: .error,
                title: "Preference not saved",
                detail: "Tracker sync settings could not be saved."
            )
        case .trackingRemoteUpdateFailed:
            return .init(
                style: .error,
                title: "Tracker not updated",
                detail: "The remote tracker entry could not be updated."
            )
        case .trackingLinkPersistenceFailed:
            return .init(
                style: .error,
                title: "Tracker link not saved",
                detail: "The remote entry changed, but its local link still needs to be saved."
            )
        case .trackingUnlinkFailed:
            return .init(
                style: .error,
                title: "Tracking not stopped",
                detail: "The local tracker link could not be removed."
            )
        case .trackingExternalPageOpenFailed:
            return .init(
                style: .error,
                title: "Tracker page unavailable",
                detail: "The tracker page could not be opened."
            )
        case .mediaDetailLoadFailed:
            return .init(
                style: .error,
                title: "Failed to load details",
                detail: "Please try again."
            )
        case .mediaDetailSaveFailed:
            return .init(
                style: .error,
                title: "Not saved",
                detail: "The library change could not be saved. Please try again."
            )
        case .mediaDetailUnsaveFailed:
            return .init(
                style: .error,
                title: "Still in library",
                detail: "The library change could not be saved. Please try again."
            )
        case .mediaDetailSaved(let actionToken):
            return .init(
                style: .success,
                title: "Saved to Uncategorized",
                detail: nil,
                actionTitle: "Move",
                actionID: actionToken.uuidString
            )
        case .mediaDetailTrackerProgressFailed:
            return .init(
                style: .error,
                title: "Local progress not updated",
                detail: "Tracking succeeded, but local progress could not be saved."
            )
        case .libraryLayoutPersistenceFailed:
            return .init(
                style: .error,
                title: "Layout not saved",
                detail: "The library layout could not be saved. Please try again."
            )
        case .libraryItemRemovalFailed:
            return .init(
                style: .error,
                title: "Still in library",
                detail: "The library item could not be removed. Please try again."
            )
        case .libraryUpdateFailed:
            return .init(
                style: .error,
                title: "Update check failed",
                detail: "The library update check could not finish. Please try again."
            )
        case .categoryCreateFailed:
            return .init(
                style: .error,
                title: "List not created",
                detail: "Your list couldn't be created. Please try again."
            )
        case .categoryRenameFailed:
            return .init(
                style: .error,
                title: "List not renamed",
                detail: "Your list couldn't be renamed. Please try again."
            )
        case .categoryDeleteFailed:
            return .init(
                style: .error,
                title: "List not deleted",
                detail: "Your list couldn't be deleted. Please try again."
            )
        case .categoryReorderFailed:
            return .init(
                style: .error,
                title: "Lists not reordered",
                detail: "Your list order couldn't be saved. Please try again."
            )
        case .categoryAssignmentFailed:
            return .init(
                style: .error,
                title: "List assignment not saved",
                detail: "The list assignment couldn't be saved. Please try again."
            )
        case .categoryCreateAndAssignFailed:
            return .init(
                style: .error,
                title: "List not created",
                detail: "The new list and assignment couldn't be saved. Please try again."
            )
        case .historyDeleteFailed:
            return .init(
                style: .error,
                title: "History item not deleted",
                detail: "The history item couldn't be deleted. Please try again."
            )
        case .historyClearFailed:
            return .init(
                style: .error,
                title: "History not cleared",
                detail: "Your history couldn't be cleared. Please try again."
            )
        }
    }
}

@MainActor
final class AppMessageCenter: ObservableObject {
    @Published private(set) var currentMessage: AppMessage?

    private var queuedMessages: [AppMessage] = []
    private var mediaDetailActionItemIDs: [UUID: String] = [:]

    @discardableResult
    func publish(_ kind: AppMessageKind) -> UUID {
        let message = AppMessage(id: UUID(), kind: kind)
        if currentMessage == nil {
            currentMessage = message
        } else {
            queuedMessages.append(message)
        }
        return message.id
    }

    func dismiss(messageID: UUID) {
        guard let current = currentMessage, current.id == messageID else { return }
        if case .mediaDetailSaved(let actionToken) = current.kind {
            mediaDetailActionItemIDs.removeValue(forKey: actionToken)
        }
        self.currentMessage = queuedMessages.isEmpty ? nil : queuedMessages.removeFirst()
    }

    @discardableResult
    func publishMediaDetailSaved(itemID: String) -> UUID {
        let actionToken = UUID()
        mediaDetailActionItemIDs[actionToken] = itemID
        return publish(.mediaDetailSaved(actionToken: actionToken))
    }

    func mediaDetailItemID(forActionID actionID: String) -> String? {
        guard let token = UUID(uuidString: actionID) else { return nil }
        return mediaDetailActionItemIDs[token]
    }

    var queuedMessageCount: Int {
        queuedMessages.count
    }
}
