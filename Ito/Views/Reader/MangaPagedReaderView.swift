import SwiftUI
import UIKit

/// The paged reader's pager. The reader owns the page index; this view shows it and reports the
/// page a swipe lands on. Page buttons slide the pager exactly as a swipe does.
///
/// Positions run from -1 (the previous chapter's loading page, when there is one) through the
/// chapter's pages to `pageCount` (the next chapter's loading page).
struct MangaPagedReaderView<Page: View>: UIViewControllerRepresentable {
    /// Content of one chapter: a new identity resets the pager without an animation.
    let chapterKey: String
    let pageCount: Int
    let hasPrevious: Bool
    let hasNext: Bool
    let index: Int
    let isRightToLeft: Bool
    let content: (Int) -> Page
    let onIndexChange: (Int) -> Void

    func makeUIViewController(context: Context) -> MangaPagedReaderController<Page> {
        let controller = MangaPagedReaderController<Page>()
        controller.update(with: self)
        return controller
    }

    func updateUIViewController(_ controller: MangaPagedReaderController<Page>, context: Context) {
        controller.update(with: self)
    }
}

final class MangaPagedReaderController<Page: View>: UIViewController,
    UIPageViewControllerDataSource,
    UIPageViewControllerDelegate {
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 0]
    )
    private var configuration: MangaPagedReaderView<Page>?
    /// Hosts near the current position, so neighbours keep their state (zoom, loaded image)
    /// while the pager can show them. Farther ones are released with their images.
    private var hosts: [Int: MangaPagedPageHost<Page>] = [:]
    private var shownChapterKey: String?
    private var shownIndex: Int?
    private var shownRightToLeft: Bool?
    /// A finger swipe is moving the pager (from `willTransitionTo` to `didFinishAnimating`).
    private(set) var isSwiping = false
    /// A programmatic slide is moving the pager; it ends in its own completion.
    private(set) var isSliding = false
    /// Identifies the latest slide, so a superseded slide's completion cannot end a newer one.
    private var slide: UInt64 = 0

    /// Replacing pages while the pager moves confuses the page controller, so reader changes
    /// made meanwhile are applied when the movement ends.
    var isTransitioning: Bool { isSwiping || isSliding }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        pager.dataSource = self
        pager.delegate = self
        pager.view.backgroundColor = .clear
        // Page order is physical: the reader decides which side the next page comes from.
        pager.view.semanticContentAttribute = .forceLeftToRight
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        if let configuration { show(configuration) }
    }

    func update(with configuration: MangaPagedReaderView<Page>) {
        self.configuration = configuration
        guard isViewLoaded else { return }
        show(configuration)
    }

    private func show(_ configuration: MangaPagedReaderView<Page>) {
        guard !isTransitioning else { return }
        if shownChapterKey != configuration.chapterKey {
            shownChapterKey = configuration.chapterKey
            shownIndex = nil
            hosts.removeAll()
        }
        // Positions that no longer exist leave; the rest keep their hosts and get new content.
        hosts = hosts.filter { contains($0.key, in: configuration) }
        for (position, host) in hosts { host.rootView = configuration.content(position) }
        let target = clamped(configuration.index, in: configuration)
        if target == shownIndex, configuration.isRightToLeft != shownRightToLeft, let shownIndex {
            // The page controller keeps the neighbours it already asked for; another reading
            // direction needs them asked for again.
            shownRightToLeft = configuration.isRightToLeft
            pager.setViewControllers([host(for: shownIndex, in: configuration)], direction: .forward, animated: false)
            return
        }
        guard target != shownIndex else { return }
        shownRightToLeft = configuration.isRightToLeft
        let previous = shownIndex
        shownIndex = target
        releaseDistantHosts()
        let forward = previous.map { target > $0 } ?? true
        // One page apart in the same chapter slides like a swipe; anything else jumps.
        let animated = (previous.map { abs(target - $0) == 1 } ?? false) && view.window != nil
        if animated {
            isSliding = true
            slide &+= 1
            // A finger cannot start a swipe during the slide, so the slide decides the page.
            pager.view.isUserInteractionEnabled = false
        }
        let token = slide
        pager.setViewControllers(
            [host(for: target, in: configuration)],
            direction: forward != configuration.isRightToLeft ? .forward : .reverse,
            animated: animated
        ) { [weak self] _ in
            // Programmatic slides end here; the delegate reports only swipes.
            guard animated, let self, self.slide == token else { return }
            self.isSliding = false
            self.pager.view.isUserInteractionEnabled = true
            if let configuration = self.configuration { self.show(configuration) }
        }
    }

    private func contains(_ position: Int, in configuration: MangaPagedReaderView<Page>) -> Bool {
        let first = configuration.hasPrevious ? -1 : 0
        let last = configuration.hasNext ? configuration.pageCount : configuration.pageCount - 1
        return position >= first && position <= last
    }

    private func clamped(_ index: Int, in configuration: MangaPagedReaderView<Page>) -> Int {
        let first = configuration.hasPrevious ? -1 : 0
        let last = configuration.hasNext ? configuration.pageCount : max(configuration.pageCount - 1, 0)
        return min(max(index, first), last)
    }

    private func releaseDistantHosts() {
        guard let shownIndex else { return }
        hosts = hosts.filter { abs($0.key - shownIndex) <= 2 }
    }

    private func host(for position: Int, in configuration: MangaPagedReaderView<Page>) -> MangaPagedPageHost<Page> {
        if let host = hosts[position] { return host }
        let host = MangaPagedPageHost(position: position, rootView: configuration.content(position))
        hosts[position] = host
        return host
    }

    // MARK: - Data source

    /// The page `step` positions from `viewController` in reading order, or `nil` past either end.
    private func neighbour(of viewController: UIViewController, step: Int) -> UIViewController? {
        guard let configuration, let host = viewController as? MangaPagedPageHost<Page> else { return nil }
        let position = host.position + step
        guard contains(position, in: configuration) else { return nil }
        return self.host(for: position, in: configuration)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        // Right to left, the page on the left is the next one.
        neighbour(of: viewController, step: configuration?.isRightToLeft == true ? 1 : -1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        neighbour(of: viewController, step: configuration?.isRightToLeft == true ? -1 : 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isSwiping = true
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        isSwiping = false
        let readerMoved = configuration.map { clamped($0.index, in: $0) != shownIndex || $0.chapterKey != shownChapterKey }
        // A swipe's page counts only when no slide owns the pager.
        let landed = completed && !isSliding
            ? (pageViewController.viewControllers?.first as? MangaPagedPageHost<Page>)?.position
            : nil
        // A swipe that lands on another page moves the reader, unless the reader moved meanwhile
        // (a page button during the swipe): then its page wins and is shown next.
        if let landed, landed != shownIndex, readerMoved == false {
            shownIndex = landed
            releaseDistantHosts()
            configuration?.onIndexChange(landed)
            return
        }
        if let landed { shownIndex = landed }
        if let configuration { show(configuration) }
    }
}

/// One page of the pager: its position in the chapter and its SwiftUI content.
final class MangaPagedPageHost<Page: View>: UIHostingController<Page> {
    let position: Int

    init(position: Int, rootView: Page) {
        self.position = position
        super.init(rootView: rootView)
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
