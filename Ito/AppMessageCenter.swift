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
    case mediaDetailChapterUnavailable(isEpisode: Bool)
    case mediaDetailChapterLocked(isEpisode: Bool)
    case mediaDetailChapterNotDownloaded
    case libraryLayoutPersistenceFailed
    case libraryItemRemovalFailed
    case libraryUpdateFailed
    case libraryNoUpdateSources
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
                title: String(localized: "Error"),
                detail: String(localized: "Update failed. Please try again.")
            )
        case .browseDeleteFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to remove plugin. Please try again.")
            )
        case .browseDropLoadFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to load dropped file.")
            )
        case .browseUnsupportedPluginFile:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Please drop a valid .ito plugin file.")
            )
        case .browsePluginDirectoryUnavailable:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to access plugins directory.")
            )
        case .browseImportFailed(let source):
            let detail = source == .drop
                ? String(localized: "File copy error: The plugin could not be imported.")
                : String(localized: "URL Open error: The plugin could not be imported.")
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: detail
            )
        case .repositoryAdded:
            return .init(
                style: .success,
                title: String(localized: "Repository added"),
                detail: nil
            )
        case .repositoryAlreadyAdded:
            return .init(
                style: .info,
                title: String(localized: "Already added"),
                detail: String(localized: "This repository is already in your list.")
            )
        case .repositoryAddFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to add repository. Please try again.")
            )
        case .repositoryRemoveFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to remove repository. Please try again.")
            )
        case .repositoryRefreshFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Some repositories could not be refreshed. Please try again.")
            )
        case .repositoryInstallFailed:
            return .init(
                style: .error,
                title: String(localized: "Error"),
                detail: String(localized: "Failed to install package. Please try again.")
            )
        case .debugLogsCopied:
            return .init(
                style: .success,
                title: String(localized: "Copied to clipboard"),
                detail: nil
            )
        case .sourceLoadFailed:
            return .init(
                style: .error,
                title: String(localized: "Failed to load source"),
                detail: String(localized: "Please try again.")
            )
        case .sourceSearchFailed:
            return .init(
                style: .error,
                title: String(localized: "Search failed"),
                detail: String(localized: "The source could not complete the search.")
            )
        case .pluginSettingsLoadFailed:
            return .init(
                style: .error,
                title: String(localized: "Settings unavailable"),
                detail: String(localized: "Plugin settings could not be loaded.")
            )
        case .pluginSettingsPersistenceFailed:
            return .init(
                style: .error,
                title: String(localized: "Settings not saved"),
                detail: String(localized: "The plugin setting could not be saved.")
            )
        case .pluginSettingsReloadFailed:
            return .init(
                style: .error,
                title: String(localized: "Settings reload failed"),
                detail: String(localized: "Plugin settings could not be reloaded.")
            )
        case .sourceArchivedPluginDeleteFailed:
            return .init(
                style: .error,
                title: String(localized: "Failed to remove plugin"),
                detail: String(localized: "Plugin removal encountered an error. Refresh plugin state before retrying.")
            )
        case .discoverDetailRefreshFailed:
            return .init(
                style: .error,
                title: String(localized: "Details unavailable"),
                detail: String(localized: "Full media details could not be refreshed. The available summary is still shown.")
            )
        case .trackingPreferencePersistenceFailed:
            return .init(
                style: .error,
                title: String(localized: "Preference not saved"),
                detail: String(localized: "Tracker sync settings could not be saved.")
            )
        case .trackingRemoteUpdateFailed:
            return .init(
                style: .error,
                title: String(localized: "Tracker not updated"),
                detail: String(localized: "The remote tracker entry could not be updated.")
            )
        case .trackingLinkPersistenceFailed:
            return .init(
                style: .error,
                title: String(localized: "Tracker link not saved"),
                detail: String(localized: "The remote entry changed, but its local link still needs to be saved.")
            )
        case .trackingUnlinkFailed:
            return .init(
                style: .error,
                title: String(localized: "Tracking not stopped"),
                detail: String(localized: "The local tracker link could not be removed.")
            )
        case .trackingExternalPageOpenFailed:
            return .init(
                style: .error,
                title: String(localized: "Tracker page unavailable"),
                detail: String(localized: "The tracker page could not be opened.")
            )
        case .mediaDetailLoadFailed:
            return .init(
                style: .error,
                title: String(localized: "Failed to load details"),
                detail: String(localized: "Please try again.")
            )
        case .mediaDetailSaveFailed:
            return .init(
                style: .error,
                title: String(localized: "Not saved"),
                detail: String(localized: "The library change could not be saved. Please try again.")
            )
        case .mediaDetailUnsaveFailed:
            return .init(
                style: .error,
                title: String(localized: "Still in library"),
                detail: String(localized: "The library change could not be saved. Please try again.")
            )
        case .mediaDetailSaved(let actionToken):
            return .init(
                style: .success,
                title: String(localized: "Saved to Uncategorized"),
                detail: nil,
                actionTitle: String(localized: "Move"),
                actionID: actionToken.uuidString
            )
        case .mediaDetailTrackerProgressFailed:
            return .init(
                style: .error,
                title: String(localized: "Local progress not updated"),
                detail: String(localized: "Tracking succeeded, but local progress could not be saved.")
            )
        case .mediaDetailChapterUnavailable(let isEpisode):
            return .init(
                style: .info,
                title: isEpisode
                    ? String(localized: "Episode no longer listed")
                    : String(localized: "Chapter no longer listed"),
                detail: isEpisode
                    ? String(localized: "The source no longer lists this episode.")
                    : String(localized: "The source no longer lists this chapter.")
            )
        case .mediaDetailChapterLocked(let isEpisode):
            return .init(
                style: .info,
                title: isEpisode
                    ? String(localized: "Episode locked")
                    : String(localized: "Chapter locked"),
                detail: isEpisode
                    ? String(localized: "This episode is locked on the source.")
                    : String(localized: "This chapter is locked on the source.")
            )
        case .mediaDetailChapterNotDownloaded:
            return .init(
                style: .info,
                title: String(
                    localized: "This chapter isn't downloaded.",
                    comment: "Shown when a chapter has no offline copy and no installed source can load it. Used as the reader's load-failure text and as a notice on the series details screen."
                ),
                detail: nil
            )
        case .libraryLayoutPersistenceFailed:
            return .init(
                style: .error,
                title: String(localized: "Layout not saved"),
                detail: String(localized: "The library layout could not be saved. Please try again.")
            )
        case .libraryItemRemovalFailed:
            return .init(
                style: .error,
                title: String(localized: "Still in library"),
                detail: String(localized: "The library item could not be removed. Please try again.")
            )
        case .libraryUpdateFailed:
            return .init(
                style: .error,
                title: String(localized: "Update check failed"),
                detail: String(localized: "The library update check could not finish. Please try again.")
            )
        case .libraryNoUpdateSources:
            return .init(
                style: .info,
                title: String(localized: "No sources installed"),
                detail: String(localized: "Install a source in Browse to check your library for updates.")
            )
        case .categoryCreateFailed:
            return .init(
                style: .error,
                title: String(localized: "List not created"),
                detail: String(localized: "Your list couldn't be created. Please try again.")
            )
        case .categoryRenameFailed:
            return .init(
                style: .error,
                title: String(localized: "List not renamed"),
                detail: String(localized: "Your list couldn't be renamed. Please try again.")
            )
        case .categoryDeleteFailed:
            return .init(
                style: .error,
                title: String(localized: "List not deleted"),
                detail: String(localized: "Your list couldn't be deleted. Please try again.")
            )
        case .categoryReorderFailed:
            return .init(
                style: .error,
                title: String(localized: "Lists not reordered"),
                detail: String(localized: "Your list order couldn't be saved. Please try again.")
            )
        case .categoryAssignmentFailed:
            return .init(
                style: .error,
                title: String(localized: "List assignment not saved"),
                detail: String(localized: "The list assignment couldn't be saved. Please try again.")
            )
        case .categoryCreateAndAssignFailed:
            return .init(
                style: .error,
                title: String(localized: "List not created"),
                detail: String(localized: "The new list and assignment couldn't be saved. Please try again.")
            )
        case .historyDeleteFailed:
            return .init(
                style: .error,
                title: String(localized: "History item not deleted"),
                detail: String(localized: "The history item couldn't be deleted. Please try again.")
            )
        case .historyClearFailed:
            return .init(
                style: .error,
                title: String(localized: "History not cleared"),
                detail: String(localized: "Your history couldn't be cleared. Please try again.")
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
