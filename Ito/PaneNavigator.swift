import Combine

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

/// Navigators for every split-capable surface. Owned by `AppRouter` so the pane
/// selection outlives the view hierarchy that presents it.
@MainActor
final class AppPaneNavigators {
    let settings = PaneNavigator<SettingsDestination>()
}
