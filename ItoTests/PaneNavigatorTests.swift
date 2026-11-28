import Combine
import XCTest
@testable import Ito
import ito_runner

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

    func testLibraryPlainSelectionOfSameSeriesIsNoOp() {
        let navigator = PaneNavigator<LibraryDetailSelection>()
        var published: [LibraryDetailSelection?] = []
        let cancellable = navigator.$selection.sink { published.append($0) }
        let item = makeLibraryItem("a")

        navigator.select(.plain(item))
        navigator.select(.plain(item))

        XCTAssertEqual(published.count, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testOpenedSelectionMintsFreshTokenEvenForSameSeries() {
        let item = makeLibraryItem("a")
        let intent = MediaDetailOpenIntent.resume(preferredScanlator: nil)
        let first = LibraryDetailSelection.opened(item, intent: intent)
        let second = LibraryDetailSelection.opened(item, intent: intent)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, LibraryDetailSelection.plain(item))
        XCTAssertEqual(first.item, second.item)
    }

    func testClosingHistoryClearsSelectionOnlyInStackArrangement() {
        XCTAssertTrue(LibraryPaneRules.clearsSelection(afterClosing: .history, arrangement: .stack))
        XCTAssertFalse(LibraryPaneRules.clearsSelection(afterClosing: .history, arrangement: .split))
        XCTAssertFalse(LibraryPaneRules.clearsSelection(afterClosing: .downloads, arrangement: .stack))
        XCTAssertFalse(LibraryPaneRules.clearsSelection(afterClosing: .lists, arrangement: .stack))
    }

    func testCollapseKeepsOnlyHistoryOnScreen() {
        XCTAssertEqual(LibraryPaneRules.screenAfterCollapse(.history), .history)
        XCTAssertNil(LibraryPaneRules.screenAfterCollapse(.downloads))
        XCTAssertNil(LibraryPaneRules.screenAfterCollapse(.lists))
        XCTAssertNil(LibraryPaneRules.screenAfterCollapse(nil))
    }

    private func makeLibraryItem(_ id: String) -> Ito.LibraryItem {
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
}
