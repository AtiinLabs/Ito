import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SourceSearchFiltersTests: XCTestCase {
    private let toggle = Control(id: "enabled", title: "Enabled", kind: .toggle(.init(defaultValue: false)))

    func testAllKindsAndIndividualKindsKeepIndependentUserValues() {
        let state = SourceSearchFilters()
        let capabilities = SearchCapabilities(sections: [.init(id: "filters", title: "Filters", controls: [toggle])])
        let kinds: [MediaKind?] = [nil, .manga, .anime]
        for kind in kinds {
            state.updateCapabilities(capabilities, kind: kind)
        }
        state.setValue(.toggle(true), for: toggle, kind: nil)
        state.setValue(.toggle(false), for: toggle, kind: .manga)
        XCTAssertEqual(state.values(for: nil), ["enabled": .toggle(true)])
        XCTAssertEqual(state.values(for: .manga), ["enabled": .toggle(false)])
        XCTAssertTrue(state.values(for: .anime).isEmpty)
    }

    func testDefaultsAreNotStoredAndResetRemovesOverrides() {
        let state = SourceSearchFilters()
        let capabilities = SearchCapabilities(sections: [.init(id: "filters", title: "Filters", controls: [toggle])])
        state.updateCapabilities(capabilities, kind: nil)
        XCTAssertTrue(state.values(for: nil).isEmpty)
        state.apply(["enabled": .toggle(true)], kind: nil)
        state.clear(kind: nil)
        XCTAssertTrue(state.values(for: nil).isEmpty)
        XCTAssertEqual(state.capabilities(for: nil), capabilities)
    }

    func testReconciliationKeepsLatestValidEditsAndDropsRemovedOrChangedControls() {
        let state = SourceSearchFilters()
        let removed = Control(id: "removed", title: "Removed", kind: .toggle(.init(defaultValue: false)))
        state.updateCapabilities(.init(sections: [.init(id: "filters", title: "Filters", controls: [toggle, removed])]), kind: .novel)
        state.apply(["enabled": .toggle(false), "removed": .toggle(true)], kind: .novel)
        state.setValue(.toggle(true), for: toggle, kind: .novel)
        state.updateCapabilities(.init(sections: [.init(id: "filters", title: "Filters", controls: [toggle])]), kind: .novel)
        XCTAssertEqual(state.values(for: .novel), ["enabled": .toggle(true)])
        let changed = Control(id: "enabled", title: "Enabled", kind: .text(.init(defaultValue: "")))
        state.updateCapabilities(.init(sections: [.init(id: "filters", title: "Filters", controls: [changed])]), kind: .novel)
        XCTAssertTrue(state.values(for: .novel).isEmpty)
    }

    func testApplyRejectsUnknownAndInvalidValuesButRetainsHiddenOverrides() {
        let state = SourceSearchFilters()
        let hidden = Control(id: "hidden", title: "Hidden", visibleWhen: [.init(control: "enabled", anyOf: ["true"])], kind: .text(.init(defaultValue: "")))
        state.updateCapabilities(.init(sections: [.init(id: "filters", title: "Filters", controls: [toggle, hidden])]), kind: nil)
        state.apply(["enabled": .text("invalid"), "unknown": .toggle(true), "hidden": .text("kept")], kind: nil)
        XCTAssertEqual(state.values(for: nil), ["hidden": .text("kept")])
        state.updateCapabilities(nil, kind: nil)
        XCTAssertNil(state.capabilities(for: nil))
        XCTAssertTrue(state.values(for: nil).isEmpty)
    }

    func testPresentationHidesDependentPageWithoutDiscardingItsOverride() {
        let state = SourceSearchFilters()
        let dependent = Control(
            id: "dependent",
            title: "Dependent",
            visibleWhen: [.init(control: "enabled", anyOf: ["true"])],
            kind: .text(.init(defaultValue: ""))
        )
        let capabilities = SearchCapabilities(sections: [
            .init(id: "controller", title: "Controller", controls: [toggle]),
            .init(id: "dependentPage", title: "Dependent page", flags: [.page], controls: [dependent])
        ])
        state.updateCapabilities(capabilities, kind: nil)
        var draft: [String: ControlValue] = ["dependent": .text("kept")]

        let initiallyHidden = SourceSearchFilters.Presentation(capabilities: capabilities, values: draft)
        XCTAssertEqual(initiallyHidden.sections.map(\.id), ["controller"])
        XCTAssertEqual(initiallyHidden.visibleControlIDs, ["enabled"])

        draft["enabled"] = .toggle(true)
        let shown = SourceSearchFilters.Presentation(capabilities: capabilities, values: draft)
        XCTAssertEqual(shown.sections.map(\.id), ["controller", "dependentPage"])
        XCTAssertEqual(shown.visibleControlIDs, ["enabled", "dependent"])
        XCTAssertTrue(shown.sections[1].flags.contains(.page))

        draft["enabled"] = .toggle(false)
        let hiddenAgain = SourceSearchFilters.Presentation(capabilities: capabilities, values: draft)
        XCTAssertEqual(hiddenAgain.sections.map(\.id), ["controller"])
        XCTAssertEqual(hiddenAgain.visibleControlIDs, ["enabled"])
        XCTAssertEqual(draft["dependent"], .text("kept"))
        state.apply(draft, kind: nil)
        XCTAssertEqual(state.values(for: nil), ["enabled": .toggle(false), "dependent": .text("kept")])
    }
}
