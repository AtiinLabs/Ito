import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

/// Drives the real deferred-plugin view model through the pane lifecycle registry,
/// the same way `PaneLifecycleModifier` drives it from SwiftUI appear/disappear.
/// Each ordering a stack→split reparent can produce must still open the series.
@MainActor
final class DeferredPluginPaneLifecycleTests: XCTestCase {
    private var viewModel: DeferredPluginViewModel!
    private var registry: PaneLifecycleRegistry!

    override func setUp() {
        super.setUp()
        registry = PaneLifecycleRegistry()
        let item = Ito.LibraryItem(
            id: "item.exact",
            title: "Private title",
            coverUrl: nil,
            pluginId: "plugin.exact",
            isAnime: false,
            pluginType: .manga,
            rawPayload: try! JSONEncoder().encode(Manga(key: "manga", title: "Manga")),
            anilistId: nil
        )
        viewModel = DeferredPluginViewModel(
            item: item,
            openIntent: nil,
            plugins: DeferredPluginFake(
                installedPluginIDs: ["plugin.exact"],
                supportedKinds: [.manga],
                runnerResponses: [
                    .immediate(.success(ItoRunner())),
                    .immediate(.success(ItoRunner()))
                ]
            ),
            installer: DeferredInstallerFake(lookupResponses: [], installResponses: []),
            payloadDecoder: JSONDeferredPluginPayloadDecoder(),
            offlineReading: UnavailableOfflineChapterReading(),
            presentationLogger: PresentationEventCaptureSpy()
        )
    }

    override func tearDown() {
        viewModel = nil
        registry = nil
        super.tearDown()
    }

    /// Mirrors `PaneLifecycleModifier`: `.onAppear` installs, `.onDisappear` uninstalls.
    private func install(_ token: UUID) {
        registry.install(
            owner: viewModel,
            token: token,
            onAppear: { [viewModel] in viewModel?.appear() },
            onDisappear: { [viewModel] in viewModel?.disappear() }
        )
    }

    private func uninstall(_ token: UUID) {
        registry.uninstall(owner: viewModel, token: token)
    }

    private func waitForRoute(file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while viewModel.route == nil, Date() < deadline {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.route, "series must open; phase=\(viewModel.phase)", file: file, line: line)
    }

    /// Stack push: the detail appears, then the split detail installs before the stack one leaves.
    func testOverlappingReinstallBeforeUninstallOpensSeries() async {
        let stack = UUID()
        let split = UUID()
        install(stack)
        registry.beginHandover()
        install(split)
        uninstall(stack)
        registry.flushPending()
        await waitForRoute()
    }

    /// Stack push: the stack detail leaves before the split detail installs.
    func testUninstallBeforeReinstallOpensSeries() async {
        let stack = UUID()
        let split = UUID()
        install(stack)
        uninstall(stack)
        install(split)
        await waitForRoute()
    }

    /// The handover marks the root pending; the reinstall reclaims it without a restart.
    func testHandoverThenReinstallKeepsSeriesOpen() async {
        let stack = UUID()
        let split = UUID()
        install(stack)
        await waitForRoute()
        registry.beginHandover()
        uninstall(stack)
        install(split)
        registry.flushPending()
        await waitForRoute()
    }

    /// No reinstall after the handover: the pending root is released and the series
    /// is not left in a loading state while nothing is presenting it.
    func testHandoverWithoutReinstallLeavesNoPresentingSeriesLoading() async {
        let stack = UUID()
        install(stack)
        await waitForRoute()
        registry.beginHandover()
        uninstall(stack)
        registry.flushPending()
        XCTAssertFalse(registry.isPresent(viewModel))
    }

    /// The Library's deferred view observes the session, not the model, so a change in the model must reach
    /// it through the session. Without that, the series stayed on its loading spinner after the model was ready.
    func testTheSessionPassesTheModelsChangesOnToItsView() {
        let session = DeferredPluginSession(viewModel: viewModel)
        var changes = 0
        let subscription = session.objectWillChange.sink { changes += 1 }
        viewModel.appear()
        XCTAssertGreaterThan(changes, 0)
        subscription.cancel()
    }
}
