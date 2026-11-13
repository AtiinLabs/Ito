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
    case repositorySourcesRefreshed
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
    case mediaDetailDownloadRefused
    case mediaDetailDownloadActionFailed
    case mediaDetailReplacementUnavailable
    /// A download preset queued chapters; `alreadyStored` of its range were saved or queued before.
    case mediaDetailDownloadsQueued(queued: Int, alreadyStored: Int)
    case mediaDetailNothingToDownload
    case mediaDetailEditionChoiceNotRemembered
    case mediaDetailEditionChoiceNotSaved
    case mediaDetailEditionChoiceUnreadable
    case mediaDetailEditionChoiceReadFailed(reviewing: Bool)
    case libraryLayoutPersistenceFailed
    case libraryItemRemovalFailed
    /// The series left the Library, but its downloads are still stored.
    case libraryDownloadsNotDeleted
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
        case .repositorySourcesRefreshed:
            return .init(
                style: .success,
                title: String(localized: "Sources refreshed", comment: "Toast title shown after the user refreshes every repository's source list and the refresh succeeds."),
                detail: nil
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
                    comment: "Shown when a chapter has no offline copy and cannot be loaded: no installed source can load it, or the device is offline. Used as the reader's load-failure text and as a notice on the series details screen."
                ),
                detail: nil
            )
        case .mediaDetailDownloadRefused:
            return .init(
                style: .info,
                title: String(
                    localized: "This chapter can't be downloaded.",
                    comment: "Series details: the chapter is locked, or its source can't be saved for offline reading."
                ),
                detail: nil
            )
        case .mediaDetailReplacementUnavailable:
            return .init(
                style: .info,
                title: String(
                    localized: "This copy can't be replaced.",
                    comment: "Series details: a saved chapter cannot be replaced, because its source settings changed after it was saved or it was saved under another series."
                ),
                detail: String(
                    localized: "Delete the saved copy and download the chapter again.",
                    comment: "Series details: what to do when a saved chapter cannot be replaced."
                )
            )
        case .mediaDetailDownloadActionFailed:
            return .init(
                style: .error,
                title: String(
                    localized: "Couldn't update the download",
                    comment: "Series details: a Download, Cancel, Retry or Delete Download action did not take effect."
                ),
                detail: String(
                    localized: "The download could not be changed. Please try again.",
                    comment: "Series details: detail for a download action that did not take effect."
                )
            )
        case .mediaDetailDownloadsQueued(let queued, let alreadyStored):
            return .init(
                style: .success,
                title: String(
                    localized: "Queued \(queued) chapters",
                    comment: "Series details: a download preset queued chapters. The placeholder is the number of chapters, which needs plural forms."
                ),
                detail: alreadyStored > 0
                    ? String(
                        localized: "\(alreadyStored) already saved or queued",
                        comment: "Series details: how many chapters of a download preset's range were already saved or queued. The placeholder is a number, which needs plural forms."
                    )
                    : nil
            )
        case .mediaDetailNothingToDownload:
            return .init(
                style: .info,
                title: String(
                    localized: "Nothing new to download",
                    comment: "Series details: a download preset found every chapter in its range already saved or queued, or none to download."
                ),
                detail: nil
            )
        case .mediaDetailEditionChoiceNotRemembered:
            return .init(
                style: .error,
                title: String(
                    localized: "Scanlator choice not remembered",
                    comment: "Series details: the chosen scanlators could not be remembered for this series."
                ),
                detail: String(
                    localized: "It applies to this download only.",
                    comment: "Series details: detail when the chosen scanlators could not be remembered for the series, so the choice applies to the current download only."
                )
            )
        case .mediaDetailEditionChoiceNotSaved:
            return .init(
                style: .error,
                title: String(
                    localized: "Scanlator choice not saved",
                    comment: "Series details: the scanlators chosen for this series could not be saved."
                ),
                detail: String(
                    localized: "Your choice couldn't be stored. Please try again.",
                    comment: "Series details: detail when the scanlators chosen for this series could not be saved."
                )
            )
        case .mediaDetailEditionChoiceUnreadable:
            return .init(
                style: .error,
                title: String(
                    localized: "Saved scanlator choice unavailable",
                    comment: "Series details: the scanlators remembered for this series could not be read."
                ),
                detail: String(
                    localized: "Review this download before it starts.",
                    comment: "Series details: detail when the scanlators remembered for this series cannot be read, so the download is shown for review instead of being queued."
                )
            )
        case .mediaDetailEditionChoiceReadFailed(let reviewing):
            return .init(
                style: .error,
                title: String(
                    localized: "Couldn't read the saved scanlator choice",
                    comment: "Series details: reading the scanlators remembered for this series failed this time. The choice itself may be fine."
                ),
                detail: reviewing
                    ? String(
                        localized: "Review this download before it starts.",
                        comment: "Series details: detail when the scanlators remembered for this series cannot be read, so the download is shown for review instead of being queued."
                    )
                    : String(
                        localized: "Please try again.",
                        comment: "Series details: detail when the remembered scanlators could not be read and nothing was changed."
                    )
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
        case .libraryDownloadsNotDeleted:
            return .init(
                style: .error,
                title: String(
                    localized: "Downloads not deleted",
                    comment: "Library: a series was removed from the Library, but its saved chapters could not be deleted."
                ),
                detail: String(
                    localized: "Removed from Library. Its downloads couldn't be deleted; delete them in Downloads.",
                    comment: "Library: removal committed, then deleting the series' downloads failed. Never claims the removal was undone."
                )
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
