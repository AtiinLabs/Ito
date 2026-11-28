import Combine
import Foundation

/// Owns the selected detail for one list/detail surface. Views observe `selection`
/// to drive the detail column and the stack-mode push; they never hold the detail's
/// view models, so selection stays a plain value that survives arrangement changes.
@MainActor
final class PaneNavigator<Selection: Hashable>: ObservableObject {
    @Published private(set) var selection: Selection?

    func select(_ value: Selection) {
        guard selection != value else { return }
        selection = value
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
    }
}

/// A series opened from the Library grid or History. Identity is the series and the open token: a plain
/// selection of the same series is a no-op, while each `opened` call mints a new token so an explicit open
/// re-runs the detail even when the series is already selected.
struct LibraryDetailSelection: Hashable {
    let item: LibraryItem
    let openIntent: MediaDetailOpenIntent?
    let openID: UUID?

    static func plain(_ item: LibraryItem) -> LibraryDetailSelection {
        LibraryDetailSelection(item: item, openIntent: nil, openID: nil)
    }

    static func opened(_ item: LibraryItem, intent: MediaDetailOpenIntent?) -> LibraryDetailSelection {
        LibraryDetailSelection(item: item, openIntent: intent, openID: UUID())
    }

    static func == (lhs: LibraryDetailSelection, rhs: LibraryDetailSelection) -> Bool {
        lhs.item.id == rhs.item.id && lhs.openID == rhs.openID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
        hasher.combine(openID)
    }
}

/// The Library list-column screens that the toolbar pushes over the grid.
nonisolated enum LibraryListScreen: Hashable {
    case history
    case downloads
    case lists
}

nonisolated enum LibraryPaneRules {
    /// Closing History in stack arrangement clears the selection, so a series selected while
    /// History was open does not re-push when the user returns to the list.
    static func clearsSelection(afterClosing screen: LibraryListScreen, arrangement: PaneArrangement) -> Bool {
        screen == .history && arrangement == .stack
    }

    /// Collapsing to the stack keeps History on screen; Downloads and Lists return to the grid.
    static func screenAfterCollapse(_ screen: LibraryListScreen?) -> LibraryListScreen? {
        screen == .history ? .history : nil
    }
}

/// What the Browse detail shows: a source's home, or the repositories list.
enum BrowseDetailSelection: Hashable {
    case source(pluginID: String)
    case repositories
}

/// Browse-side routing for the detail column. The Browse view model and repository deep links route through
/// this protocol so they never hold the navigator's selection type.
@MainActor
protocol BrowseDetailRouting: AnyObject {
    func showRepositories()
    func installedSourcesDidChange(_ pluginIDs: Set<String>)
}

extension PaneNavigator: BrowseDetailRouting where Selection == BrowseDetailSelection {
    func showRepositories() {
        select(.repositories)
    }

    /// Clears a source selection whose plugin is no longer installed.
    func installedSourcesDidChange(_ pluginIDs: Set<String>) {
        if case .source(let id)? = selection, !pluginIDs.contains(id) {
            clearSelection()
        }
    }
}

/// Navigators for every split-capable surface. Owned by `AppRouter` so the pane
/// selection outlives the view hierarchy that presents it.
@MainActor
final class AppPaneNavigators {
    let settings = PaneNavigator<SettingsDestination>()
    let library = PaneNavigator<LibraryDetailSelection>()
    let browse = PaneNavigator<BrowseDetailSelection>()
}
