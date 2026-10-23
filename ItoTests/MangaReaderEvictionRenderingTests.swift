import Combine
import SwiftUI
import UIKit
import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {
    func testRenderedLazyPrefixEvictionPreservesDeepPagePosition() async {
        let chapters = (1...5).map { makeChapter("c\($0)", number: Float($0)) }
        let subject = makeSubject(chapters: chapters, viewer: .Vertical)
        for chapter in chapters {
            subject.loader.enqueue(.pages([page(0)]), for: chapter.key)
        }
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        for count in 2...4 {
            subject.viewModel.appendNextChapter()
            await waitForReader { subject.viewModel.segments.count == count }
        }
        let state = EvictionRenderingState()
        let coordinator = MangaContinuousScrollPositionCoordinator()
        let restored = expectation(description: "Evicted prefix while retaining deep-page position")
        var completed = false
        let host = UIHostingController(rootView: EvictionRenderingProbe(
            state: state, viewModel: subject.viewModel
        ) { geometry, proxy in
            guard geometry.viewport != nil else { return }
            if state.phase == .observingInitialLayout {
                state.phase = .positioning
                return
            }
            guard state.phase != .evicting else { return }
            if state.phase == .positioning {
                guard let screen = geometry.pages["c4#0"]?.viewportFrame,
                      abs(screen.minY + 700) <= 1 else { return }
                _ = coordinator.update(geometry, viewModel: subject.viewModel)
                state.phase = .evicting
                return
            }
            let correction = coordinator.update(geometry, viewModel: subject.viewModel)
            if let mutation = subject.viewModel.scrollTarget, coordinator.isSettled(mutation) {
                subject.viewModel.consumeScrollTarget(mutation)
            } else if let correction {
                proxy.scrollTo(correction.pageID, anchor: UnitPoint(x: 0.5, y: correction.alignmentY))
            }
            if let screen = geometry.pages["c4#0"]?.viewportFrame,
               subject.viewModel.segments.map(\.chapter.key) == ["c2", "c3", "c4", "c5"],
               abs(screen.minY + 700) <= 1,
               subject.viewModel.scrollTarget == nil, !completed {
                completed = true
                restored.fulfill()
            }
        })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let oldKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            oldKeyWindow?.makeKeyAndVisible()
            subject.viewModel.disappear()
        }
        await fulfillment(of: [restored], timeout: 5)
    }
}

@MainActor
private final class EvictionRenderingState: ObservableObject {
    enum Phase: Hashable { case observingInitialLayout, positioning, evicting, restoring }
    @Published var phase = Phase.observingInitialLayout
}

private struct EvictionRenderingProbe: View {
    @ObservedObject var state: EvictionRenderingState
    @ObservedObject var viewModel: MangaReaderViewModel
    let observe: (MangaContinuousGeometry, ScrollViewProxy) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.flatPages) { page in
                        if page.chapter.key == "c4" {
                            Color.blue.frame(height: 1_400)
                                .background(MangaContinuousPageGeometryReporter(pageID: "c4#0"))
                                .id("c4#0")
                        } else {
                            Color.clear.frame(height: 1_000)
                        }
                    }
                    Color.clear.frame(height: 1_000)
                }
                .coordinateSpace(name: "manga.continuous.content")
                .background { MangaContinuousContentBoundsReporter() }
            }
            .coordinateSpace(name: "manga.continuous.viewport")
            .overlay { MangaContinuousViewportReporter() }
            .frame(width: 390, height: 844)
            .onPreferenceChange(MangaContinuousGeometryPreferenceKey.self) { observe($0, proxy) }
            .task(id: state.phase) {
                if state.phase == .positioning {
                    let alignment = MangaContinuousScrollPositionCoordinator.alignmentY(
                        viewportTop: -700, pageHeight: 1_400, viewportHeight: 844
                    )
                    proxy.scrollTo("c4#0", anchor: UnitPoint(x: 0.5, y: alignment))
                } else if state.phase == .evicting {
                    state.phase = .restoring
                    viewModel.appendNextChapter()
                }
            }
        }
        .ignoresSafeArea()
    }
}
