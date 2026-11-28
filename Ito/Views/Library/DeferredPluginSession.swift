import Combine
import SwiftUI

/// Holds one deferred-plugin lookup and the destination it resolved to. The Library detail keeps the
/// session for as long as its selection lives, so a re-parent or re-install reuses the destination
/// instead of rebuilding its view models.
@MainActor
final class DeferredPluginSession: ObservableObject {
    let viewModel: DeferredPluginViewModel
    private var built: (routeID: UUID, view: AnyView)?
    private var modelChanges: AnyCancellable?

    init(viewModel: DeferredPluginViewModel) {
        self.viewModel = viewModel
        // DeferredPluginView observes the session, not the model, so the model's changes must reach the
        // view through the session; without this the view never leaves its first phase.
        modelChanges = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Returns the destination for `routeID`, building it once per route. A new route builds again.
    func destination(for routeID: UUID, make: () -> AnyView) -> AnyView {
        if let built, built.routeID == routeID {
            return built.view
        }
        let view = make()
        built = (routeID, view)
        return view
    }
}
