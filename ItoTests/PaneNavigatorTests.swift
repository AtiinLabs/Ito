import Combine
import XCTest
@testable import Ito

@MainActor
final class PaneNavigatorTests: XCTestCase {
    func testSelectPublishesOnlyChangedValues() {
        let navigator = PaneNavigator<String>()
        var published: [String?] = []
        let cancellable = navigator.$selection.sink { published.append($0) }

        navigator.select("a")
        navigator.select("a")
        navigator.clearSelection()
        navigator.clearSelection()

        XCTAssertEqual(published, [nil, "a", nil])
        XCTAssertNil(navigator.selection)
        withExtendedLifetime(cancellable) {}
    }

    func testAppNavigatorsDoNotShareSettingsSelection() {
        let first = AppPaneNavigators()
        let second = AppPaneNavigators()

        first.settings.select(.backup)

        XCTAssertEqual(first.settings.selection, .backup)
        XCTAssertNil(second.settings.selection)
    }
}
