import Combine
import SwiftUI
import UIKit
import XCTest
import ito_runner
@testable import Ito

extension MangaReaderViewModelTests {
    func testRenderedMultiPagePrefixEvictionKeepsTheDeepPositionWithEveryPageReporting() async {
        let chapters = (1...5).map { makeChapter("c\($0)", number: Float($0)) }
        let subject = makeSubject(chapters: chapters, viewer: .Vertical)
        for chapter in chapters {
            subject.loader.enqueue(.pages([page(0), page(1)]), for: chapter.key)
        }
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        for count in 2...4 {
            subject.viewModel.appendNextChapter()
            await waitForReader { subject.viewModel.segments.count == count }
        }
        // Realize every page to exercise multiple geometry reporters during the same eviction.
        // The existing lazy-prefix test independently covers LazyVStack estimation.
        let layout = RenderedLayout(defaultHeight: 800, heights: ["c4#0": 1_400], lazy: false)
        let deepTop: CGFloat = -700
        let restored = expectation(description: "Prefix evicted with c4#0 still at its deep position")
        let script = RenderedScript(
            pageID: "c4#0",
            top: deepTop,
            scrollOffset: 5_500, // Six 800pt pages precede c4#0, then 700pt into the page.
            mutate: { subject.viewModel.appendNextChapter() },
            isMutated: { _ in subject.viewModel.segments.map(\.chapter.key) == ["c2", "c3", "c4", "c5"] },
            done: restored
        )

        await present(RenderedContinuousProbe(viewModel: subject.viewModel, layout: layout, script: script)) {
            await self.fulfillment(of: [restored], timeout: 5)
        }
        XCTAssertEqual(subject.viewModel.flatPages[subject.viewModel.continuousPageIndex].id, "c4#0")
    }

    func testRenderedPartiallyVisiblePlaceholderBecomesATallImageWithoutMovingTheReadingPosition() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2), page(3)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        let layout = RenderedLayout(defaultHeight: 800, heights: ["a#0": 400])
        // The reader has scrolled partly past a placeholder that is still laid out.
        let readingTop: CGFloat = -300
        let kept = expectation(description: "a#0 kept its place while it grew into a tall image")
        let script = RenderedScript(
            pageID: "a#0",
            top: readingTop,
            scrollOffset: -readingTop,
            mutate: { layout.heights.values["a#0"] = 2_000 },
            isMutated: { $0.pages["a#0"]?.viewportFrame?.height == 2_000 },
            done: kept
        )

        await present(RenderedContinuousProbe(viewModel: subject.viewModel, layout: layout, script: script)) {
            await self.fulfillment(of: [kept], timeout: 5)
        }
        XCTAssertEqual(subject.viewModel.flatPages[subject.viewModel.continuousPageIndex].id, "a#0")
    }

    func testRenderedRetainedPlaceholderAboveTheViewportGrowsWithoutMovingTheVisiblePage() async {
        let subject = makeSubject(chapters: [makeChapter("a", number: 1)], viewer: .Vertical)
        subject.loader.enqueue(.pages([page(0), page(1), page(2), page(3)]), for: "a")
        subject.viewModel.start()
        await waitForReader { subject.viewModel.loadPhase == .content }
        // Eager realization models an above-viewport image whose decode is still in flight.
        // Lazy realization and prefix eviction are covered separately.
        let layout = RenderedLayout(defaultHeight: 800, heights: ["a#0": 400], lazy: false)
        let kept = expectation(description: "a#2 stayed at -200 after the retained placeholder grew")
        let script = RenderedScript(
            pageID: "a#2", top: -200, scrollOffset: 1_400,
            mutate: { layout.heights.values["a#0"] = 2_000 },
            isMutated: { abs(($0.pages["a#2"]?.contentFrame?.minY ?? 0) - 2_800) <= 1 },
            done: kept
        )

        await present(RenderedContinuousProbe(viewModel: subject.viewModel, layout: layout, script: script)) {
            await self.fulfillment(of: [kept], timeout: 5)
        }
        XCTAssertEqual(subject.viewModel.flatPages[subject.viewModel.continuousPageIndex].id, "a#2")
    }

    /// Hosts `probe` in a portrait window for the duration of `body`.
    private func present(_ probe: RenderedContinuousProbe, during body: () async -> Void) async {
        let host = RenderedHost(rootView: probe)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let oldKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        window.rootViewController = host
        host.didAppear = {
            let offset = probe.script.scrollOffset
            host.view.layoutIfNeeded()
            guard let scrollView = RenderedScript.scrollView(in: host.view) else {
                return XCTFail("Rendered reader did not attach a UIScrollView")
            }
            XCTAssertNotNil(scrollView.window)
            XCTAssertGreaterThan(scrollView.bounds.height, 0)
            XCTAssertGreaterThanOrEqual(scrollView.contentSize.height - scrollView.bounds.height, offset)
            probe.script.beginOffsetPositioning()
            scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            XCTAssertEqual(scrollView.contentOffset.y, offset, accuracy: 1)
        }
        window.makeKeyAndVisible()
        await body()
        window.isHidden = true
        oldKeyWindow?.makeKeyAndVisible()
        probe.viewModel.disappear()
    }
}

@MainActor
private final class RenderedHost: UIHostingController<RenderedContinuousProbe> {
    var didAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear?()
        didAppear = nil
    }
}

/// Positions a page, applies one layout mutation once it is the current page there, and fulfils
/// `done` when the page is back at that position with no target pending.
@MainActor
private final class RenderedScript: ObservableObject {
    enum Phase { case starting, positioning, mutating, done }

    let pageID: String
    let top: CGFloat
    let mutate: () -> Void
    let isMutated: (MangaContinuousGeometry) -> Bool
    let done: XCTestExpectation
    @Published private(set) var phase = Phase.starting
    /// Test-only positioning models a manually reached offset, not an anchored scroll request.
    let scrollOffset: CGFloat

    init(
        pageID: String,
        top: CGFloat,
        scrollOffset: CGFloat,
        mutate: @escaping () -> Void,
        isMutated: @escaping (MangaContinuousGeometry) -> Bool,
        done: XCTestExpectation
    ) {
        self.pageID = pageID
        self.top = top
        self.scrollOffset = scrollOffset
        self.mutate = mutate
        self.isMutated = isMutated
        self.done = done
    }

    func beginOffsetPositioning() {
        phase = .positioning
    }

    func observe(_ geometry: MangaContinuousGeometry, viewModel: MangaReaderViewModel) {
        guard phase != .starting else { return }
        guard let pageTop = geometry.pages[pageID]?.viewportFrame?.minY, abs(pageTop - top) <= 1 else { return }
        let isCurrent = viewModel.flatPages[viewModel.continuousPageIndex].id == pageID
        switch phase {
        case .positioning where isCurrent:
            phase = .mutating
        case .mutating where isMutated(geometry) && viewModel.scrollTarget == nil:
            phase = .done
            done.fulfill()
        default:
            break
        }
    }
}

extension RenderedScript {
    static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}

/// Page heights, observed only by each page's own cell.
@MainActor
private final class RenderedHeights: ObservableObject {
    let defaultHeight: CGFloat
    @Published var values: [String: CGFloat]

    init(defaultHeight: CGFloat, values: [String: CGFloat]) {
        self.defaultHeight = defaultHeight
        self.values = values
    }
}

/// Page heights and whether the fixture retains all pages.
@MainActor
private final class RenderedLayout {
    let heights: RenderedHeights
    let lazy: Bool

    init(defaultHeight: CGFloat, heights: [String: CGFloat], lazy: Bool = true) {
        self.heights = RenderedHeights(defaultHeight: defaultHeight, values: heights)
        self.lazy = lazy
    }
}

/// One page; like a decoded image, a height change re-renders only this cell.
private struct RenderedPage: View {
    @ObservedObject var heights: RenderedHeights
    let pageID: String

    var body: some View {
        Color.blue.frame(height: heights.values[pageID] ?? heights.defaultHeight)
    }
}

/// The continuous reader's scroll stack, wired to the coordinator the way `ReaderView` is.
private struct RenderedContinuousProbe: View {
    @ObservedObject var viewModel: MangaReaderViewModel
    let layout: RenderedLayout
    @ObservedObject var script: RenderedScript
    @State private var coordinator = MangaContinuousScrollPositionCoordinator()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if layout.lazy {
                        LazyVStack(spacing: 0) { pages }
                    } else {
                        VStack(spacing: 0) { pages }
                    }
                }
                .coordinateSpace(name: "manga.continuous.content")
                .background { MangaContinuousContentBoundsReporter() }
            }
            .coordinateSpace(name: "manga.continuous.viewport")
            .overlay { MangaContinuousViewportReporter() }
            .frame(width: 390, height: 844)
            .onPreferenceChange(MangaContinuousGeometryPreferenceKey.self) { geometry in
                if let request = coordinator.handle(geometry, viewModel: viewModel) {
                    proxy.scrollTo(request.pageID, anchor: UnitPoint(x: 0.5, y: request.alignmentY))
                }
                script.observe(geometry, viewModel: viewModel)
            }
            .task(id: script.phase) {
                if script.phase == .mutating { script.mutate() }
            }
            .onChange(of: viewModel.scrollTarget) { target in
                guard let target, let request = coordinator.issue(target, viewModel: viewModel) else { return }
                proxy.scrollTo(request.pageID, anchor: UnitPoint(x: 0.5, y: request.alignmentY))
            }
        }
        .ignoresSafeArea()
    }

    private var pages: some View {
        ForEach(viewModel.flatPages) { page in
            RenderedPage(heights: layout.heights, pageID: page.id)
                .background(MangaContinuousPageGeometryReporter(pageID: page.id))
                .id(page.id)
        }
    }
}
