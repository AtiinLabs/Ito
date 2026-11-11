import Combine
import SwiftUI
import UIKit
import ito_runner

/// The continuous reader: one native scroll view owns the viewport and zoom, while a
/// viewport-sized collection view renders rows in logical document coordinates.
struct MangaContinuousReaderView: UIViewControllerRepresentable {
    let viewModel: MangaReaderViewModel
    let onToggleUI: () -> Void

    func makeUIViewController(context: Context) -> MangaContinuousCollectionViewController {
        MangaContinuousCollectionViewController(viewModel: viewModel, onToggleUI: onToggleUI)
    }

    func updateUIViewController(_ controller: MangaContinuousCollectionViewController, context: Context) {
        controller.onToggleUI = onToggleUI
    }

    static func dismantleUIViewController(_ controller: MangaContinuousCollectionViewController, coordinator: ()) {
        controller.invalidate()
    }
}

/// One row of the continuous reader.
enum MangaContinuousRow: Hashable {
    case previousChapter
    /// The divider above a chapter that follows another; it carries the chapter's first page ID.
    case divider(String)
    case page(String)
    case nextChapter
}

@MainActor
final class MangaContinuousCollectionViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    /// Prompt rows: a 400-point minimum content height plus 40 points of padding above and below.
    static let promptHeight: CGFloat = 480
    /// Height-to-width ratio reserved for an image page until its decoded size is known.
    static let fallbackImageRatio: CGFloat = 1.435
    /// The next chapter loads once the user scrolls within this many viewport heights of the
    /// bottom of the last page.
    static let appendDistanceInViewports: CGFloat = 1

    let viewModel: MangaReaderViewModel
    private let viewportRetention: MangaContinuousViewportRetention
    var onToggleUI: () -> Void
    let collectionView: UICollectionView
    let scrollView: UIScrollView
    private let documentView = UIView()
    private var isCommittingLayout = false
    private var isChangingZoom = false
    private var viewportEpoch: UInt64 = 0
    private var observedViewportBounds: CGRect = .null
    private var observedZoomScale: CGFloat = 1
    private let doubleTap = UITapGestureRecognizer()
    private let layout = MangaContinuousCollectionViewLayout()

    private var snapshot: MangaContinuousReaderSnapshot?
    private var rows: [MangaContinuousRow] = []
    private var rowIndexByPageID: [String: Int] = [:]
    private var pagesByID: [String: FlatPage] = [:]
    private var layoutWidth: CGFloat = 0

    private var imageKeyByPageID: [String: ReaderPageImageKey] = [:]
    private var pixelSizes: [ReaderPageImageKey: CGSize] = [:]
    private var imageObservations: [ReaderPageImageKey: ReaderImageObservation] = [:]
    /// Requests that failed; their rows make room for Try Again.
    private var failedKeys: Set<ReaderPageImageKey> = []
    /// Image metadata received while native zoom or scrolling owns the document geometry.
    private var pendingImageLayouts: [ReaderPageImageKey: (size: CGSize?, failed: Bool)] = [:]
    private var measuredHeights: [String: CGFloat] = [:]

    private var subscriptions: Set<AnyCancellable> = []
    private var pendingNavigation: MangaScrollRequest?
    private var animatingNavigation: MangaScrollRequest?
    private var isLandingNavigation = false
    private var lastReportedPageIDs: [String] = []
    private var isInvalidated = false

#if DEBUG
    /// Called after every layout transaction this controller commits.
    var onLayoutCommitted: (() -> Void)?
#endif

    init(viewModel: MangaReaderViewModel, onToggleUI: @escaping () -> Void, scrollView: UIScrollView = UIScrollView()) {
        self.viewModel = viewModel
        viewportRetention = viewModel.makeContinuousViewportRetention()
        self.scrollView = scrollView
        self.onToggleUI = onToggleUI
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        collectionView.backgroundColor = .black
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.isScrollEnabled = false
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = ReaderZoomGeometry.maximumScale
        scrollView.delegate = self
        scrollView.addSubview(documentView)
        documentView.addSubview(collectionView)
        collectionView.register(
            MangaContinuousHostingCell.self,
            forCellWithReuseIdentifier: MangaContinuousHostingCell.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        doubleTap.delegate = self
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)
        scrollView.addGestureRecognizer(doubleTap)
        // `@Published` delivers the current value on subscription, then each new one before the
        // property changes; only the delivered value is read.
        viewModel.$continuousSnapshot
            .sink { [weak self] snapshot in self?.apply(snapshot: snapshot) }
            .store(in: &subscriptions)
        viewModel.$scrollTarget
            .sink { [weak self] request in
                guard let request else { return }
                self?.navigate(to: request)
            }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = scrollView }

    @objc private func backgroundTapped() { onToggleUI() }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        let physicalPoint = recognizer.location(in: scrollView)
        let viewportPoint = CGPoint(
            x: physicalPoint.x - scrollView.bounds.minX,
            y: physicalPoint.y - scrollView.bounds.minY
        )
        let scale: CGFloat = scrollView.zoomScale > 1 ? 1 : ReaderZoomGeometry.doubleTapScale
        scrollView.zoom(to: ReaderZoomGeometry.targetRect(
            contentPoint: recognizer.location(in: documentView),
            viewportPoint: viewportPoint,
            viewportSize: scrollView.bounds.size,
            scale: scale
        ), animated: true)
    }

    var documentViewport: CGRect {
        ReaderZoomGeometry.documentViewport(
            contentOffset: scrollView.contentOffset,
            viewportSize: scrollView.bounds.size,
            scale: scrollView.zoomScale
        )
    }

    /// Magnified overscan stays below two unzoomed viewports, independent of document length.
    private func updateRendererWindow() {
        // A native zoom-in sets its destination before its displayed transform arrives.
        // Cover the outgoing tap-focused viewport without depending on callback timing.
        let padding = max(0, 1 - 1 / scrollView.zoomScale)
        let coveredArea = documentViewport.insetBy(
            dx: -scrollView.bounds.width * padding,
            dy: -scrollView.bounds.height * padding
        ).intersection(documentView.bounds)
        let viewport = coveredArea.isNull ? CGRect.zero : coveredArea
        // Virtualization must not inherit the outer scroll view's zoom animation.
        UIView.performWithoutAnimation {
            collectionView.frame = viewport
            collectionView.bounds = viewport
            collectionView.layoutIfNeeded()
        }
    }

    /// Ready images and background content use the native tap pair. Placeholders, retry
    /// buttons and chapter prompts retain their own actions.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: collectionView)
        guard let index = layout.rowIndices(in: CGRect(x: point.x, y: point.y, width: 1, height: 1)).first,
              layout.frames[index].contains(point) else { return true }
        switch rows[index] {
        case .previousChapter:
            return gestureRecognizer !== doubleTap && snapshot?.loadingPrevious == true
        case .nextChapter:
            return gestureRecognizer !== doubleTap && snapshot?.loadingNext == true
        case .divider:
            return true
        case .page(let id):
            guard let page = pagesByID[id], case .url = page.page.content else { return true }
            guard let key = imageKeyByPageID[id] else { return false }
            if case .ready = viewModel.imageSession.state(for: key).phase { return true }
            return false
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Closing the reader stops the image session and drops its observers; reopening
        // observes every page again.
        cancelImageObservations { _ in true }
        observeImages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.bounds.width != layoutWidth {
            commitAnchored {}
        }
        updateRendererWindow()
        performPendingNavigation()
        reportViewport()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Text, dividers and prompts follow Dynamic Type; their measured heights change with it.
        let textSizeChanged = previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        // Image rows end on whole screen pixels, which depend on the display scale.
        let scaleChanged = previousTraitCollection?.displayScale != traitCollection.displayScale
        guard textSizeChanged || scaleChanged else { return }
        if textSizeChanged { measuredHeights = [:] }
        commitAnchored {}
    }

    /// Stops every callback into the view model; the controller is being removed.
    func invalidate() {
        isInvalidated = true
        viewportRetention.invalidate()
        subscriptions.removeAll()
        cancelImageObservations { _ in true }
        pendingImageLayouts = [:]
        pendingNavigation = nil
        animatingNavigation = nil
        for child in children {
            if let host = child as? UIHostingController<AnyView> { MangaContinuousHostingCell.detach(host) }
        }
    }

    // MARK: - Snapshot

    func apply(snapshot next: MangaContinuousReaderSnapshot) {
        guard !isInvalidated, snapshot?.revision != next.revision else { return }
        commitAnchored {
            snapshot = next
            pagesByID = Dictionary(next.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = Self.rows(for: next)
            rowIndexByPageID = [:]
            for (index, row) in rows.enumerated() {
                if case .page(let id) = row { rowIndexByPageID[id] = index }
            }
            observeImages()
            collectionView.reloadData()
        }
        performPendingNavigation()
        reportViewport()
    }

    static func rows(for snapshot: MangaContinuousReaderSnapshot) -> [MangaContinuousRow] {
        var rows: [MangaContinuousRow] = []
        if !snapshot.previousBoundary.isEnd { rows.append(.previousChapter) }
        for page in snapshot.pages {
            if page.chapterPosition == 0 && page.segmentIndex > 0 { rows.append(.divider(page.id)) }
            rows.append(.page(page.id))
        }
        if !snapshot.nextBoundary.isEnd { rows.append(.nextChapter) }
        return rows
    }

    // MARK: - Layout

    /// Runs `change`, recomputes every frame, and moves the offset by however far the anchor page
    /// moved, so that page stays at the same pixel. Runs synchronously: no later pass corrects
    /// the position. A jump still animating lands at once on its page's new position.
    private func commitAnchored(_ change: () -> Void) {
        guard !isCommittingLayout else { change(); return }
        isCommittingLayout = true
        let anchor = visibleAnchor()
        let oldAnchorY = anchor.flatMap { pageFrame($0.pageID)?.minY }
        let zoomScale = scrollView.zoomScale
        let oldOffset = scrollView.contentOffset
        let previousRows = rows
        let previousFrames = layout.frames
        let previousWidth = layoutWidth
        change()
        layoutWidth = scrollView.bounds.width
        let nextFrames = frames(width: layoutWidth)
        if rows != previousRows || nextFrames != previousFrames || layoutWidth != previousWidth {
            viewportEpoch &+= 1
        }
        layout.setFrames(nextFrames)
        let size = layout.collectionViewContentSize
        let bounds = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width * zoomScale / 2, y: size.height * zoomScale / 2)
        let contentSize = CGSize(width: size.width * zoomScale, height: size.height * zoomScale)
        if documentView.bounds != bounds { documentView.bounds = bounds }
        if documentView.center != center { documentView.center = center }
        if scrollView.contentSize != contentSize { scrollView.contentSize = contentSize }
        var offset = oldOffset
        let interrupted = animatingNavigation
        animatingNavigation = nil
        if let interrupted, let frame = pageFrame(interrupted.pageID) {
            offset.y = frame.minY * zoomScale
        } else if let anchor, let oldAnchorY, let frame = pageFrame(anchor.pageID) {
            offset.y += (frame.minY - oldAnchorY) * zoomScale
        }
        if !scrollView.isTracking && !scrollView.isDecelerating {
            offset.y = min(max(offset.y, 0), max(scrollView.contentSize.height - scrollView.bounds.height, 0))
            offset.x = min(max(offset.x, 0), max(scrollView.contentSize.width - scrollView.bounds.width, 0))
        }
        // A flush nested in a landing's scroll callback must not end that landing.
        let wasLanding = isLandingNavigation
        isLandingNavigation = wasLanding || interrupted != nil
        // Passive layout must not interrupt native zoom or momentum with a no-op scroll command.
        if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: false) }
        updateRendererWindow()
        isLandingNavigation = wasLanding
        isCommittingLayout = false
        _ = refreshViewportRetention()
        if let interrupted { acknowledge(interrupted, landed: true, appendingIfNearEnd: false) }
#if DEBUG
        onLayoutCommitted?()
#endif
    }

    private func frames(width: CGFloat) -> [CGRect] {
        let spacing: CGFloat = snapshot?.isWebtoon == true ? 0 : 8
        var frames: [CGRect] = []
        frames.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            // A divider sits directly on top of the page it introduces.
            if index > 0, !Self.isDivider(rows[index - 1]) { y += spacing }
            let height = self.height(of: row, width: width)
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        return frames
    }

    private static func isDivider(_ row: MangaContinuousRow) -> Bool {
        if case .divider = row { return true }
        return false
    }

    private func height(of row: MangaContinuousRow, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        switch row {
        case .previousChapter:
            let prompt = previousPrompt()
            return measured(prompt.measurementKey, width: width, minimum: Self.promptHeight) { prompt }
        case .nextChapter:
            let prompt = nextPrompt()
            return measured(prompt.measurementKey, width: width, minimum: Self.promptHeight) { prompt }
        case .divider(let pageID):
            guard let chapter = pagesByID[pageID]?.chapter else { return 1 }
            return measured("divider|\(chapter.key)", width: width, minimum: 1) {
                MangaContinuousChapterDivider(chapter: chapter)
            }
        case .page(let pageID):
            guard let page = pagesByID[pageID] else { return 1 }
            switch page.page.content {
            case .url:
                guard let key = imageKeyByPageID[pageID] else { return imageHeight(width: width, ratio: Self.fallbackImageRatio) }
                let ratio = pixelSizes[key].map { $0.height / $0.width } ?? Self.fallbackImageRatio
                let height = imageHeight(width: width, ratio: ratio)
                // A failed page needs room for its message and Try Again, however wide the image.
                return failedKeys.contains(key) ? max(height, Self.promptHeight) : height
            case .text(let text):
                return measured("text|\(pageID)", width: width, minimum: 1) { MangaContinuousTextPage(text: text) }
            }
        }
    }

    /// The row height of an image shown `width` points wide: the image's height rounded down to a
    /// whole screen pixel. The image overhangs its row by less than a pixel and is clipped there,
    /// so it covers the row completely and the next row starts exactly where it ends. Rounding up
    /// instead leaves a strip of background between consecutive pages.
    private func imageHeight(width: CGFloat, ratio: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return max((width * ratio * scale).rounded(.down), 1) / scale
    }

    /// The fitting height of a text page, prompt or divider at `width`, cached per content, width
    /// and text size.
    private func measured<Content: View>(
        _ key: String,
        width: CGFloat,
        minimum: CGFloat,
        _ content: () -> Content
    ) -> CGFloat {
        let cacheKey = "\(key)|\(width)|\(traitCollection.preferredContentSizeCategory.rawValue)"
        if let height = measuredHeights[cacheKey] { return height }
        let fitting = UIHostingController(rootView: content())
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(fitting.height.rounded(.up), minimum)
        measuredHeights[cacheKey] = height
        return height
    }

    func pageFrame(_ pageID: String) -> CGRect? {
        guard let index = rowIndexByPageID[pageID], layout.frames.indices.contains(index) else { return nil }
        return layout.frames[index]
    }

    /// The page under the middle of the viewport, and how far its top sits below the top of the
    /// viewport (negative when it starts above it). When a divider or gap is there instead, the
    /// page below it: a page grows downwards, so a page above that grows cannot move what is
    /// below, but one used as the anchor would push it away. Only without a page below, the
    /// nearest one above.
    func visibleAnchor() -> (pageID: String, pixelOffset: CGFloat)? {
        let viewport = documentViewport
        let midline = viewport.midY
        let candidates = visiblePageIDs().compactMap { id in pageFrame(id).map { (id: id, frame: $0) } }
        let anchor = candidates.first { $0.frame.minY <= midline && midline < $0.frame.maxY }
            ?? candidates.first { $0.frame.minY > midline }
            ?? candidates.last
        guard let anchor else { return nil }
        return (anchor.id, (anchor.frame.minY - viewport.minY) * scrollView.zoomScale)
    }

    func visiblePageIDs() -> [String] {
        let viewport = documentViewport
        guard viewport.height > 0 else { return [] }
        return layout.rowIndices(in: viewport).compactMap { index in
            guard case .page(let id) = rows[index] else { return nil }
            let frame = layout.frames[index]
            let overlap = min(frame.maxY, viewport.maxY) - max(frame.minY, viewport.minY)
            return overlap > 1 ? id : nil
        }
    }

    // MARK: - Images

    private func observeImages() {
        var descriptors: [String: ReaderPageImageDescriptor] = [:]
        for page in snapshot?.pages ?? [] {
            guard case .url(let value) = page.page.content, let url = URL(string: value) else { continue }
            descriptors[page.id] = ReaderPageImageDescriptor(
                pageID: page.id,
                request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: page.page.headers)
            )
        }
        imageKeyByPageID = descriptors.mapValues(\.key)
        let liveKeys = Set(imageKeyByPageID.values)
        cancelImageObservations { !liveKeys.contains($0) }
        pixelSizes = pixelSizes.filter { liveKeys.contains($0.key) }
        failedKeys.formIntersection(liveKeys)
        pendingImageLayouts = pendingImageLayouts.filter { liveKeys.contains($0.key) }
        let session = viewModel.imageSession
        for descriptor in descriptors.values where imageObservations[descriptor.key] == nil {
            let key = descriptor.key
            imageObservations[key] = session.observe(key) { [weak self] state in
                self?.imageStateChanged(state, key: key)
            }
            // Sizes known now (including images still in memory) are laid out from the start,
            // instead of moving rows when the page appears.
            if let size = Self.validSize(session.knownPixelSize(for: descriptor)) { pixelSizes[key] = size }
            if case .failed = session.state(for: key).phase { failedKeys.insert(key) }
        }
    }

    private func cancelImageObservations(where shouldCancel: (ReaderPageImageKey) -> Bool) {
        for (key, observation) in imageObservations where shouldCancel(key) {
            observation.cancel()
            imageObservations[key] = nil
        }
    }

    private func imageStateChanged(_ state: ReaderPageImageState, key: ReaderPageImageKey) {
        guard !isInvalidated, imageObservations[key] != nil else { return }
        let current = pendingImageLayouts[key] ?? (pixelSizes[key], failedKeys.contains(key))
        let size = Self.validSize(state.pixelSize) ?? current.size
        let failed: Bool
        if case .failed = state.phase { failed = true } else { failed = false }
        guard size != current.size || failed != current.failed else { return }
        if deferImageLayout(of: key) {
            pendingImageLayouts[key] = (size, failed)
            return
        }
        commitAnchored {
            pixelSizes[key] = size
            pendingImageLayouts[key] = nil
            if failed { failedKeys.insert(key) } else { failedKeys.remove(key) }
        }
        reportViewport()
    }

    /// Native zoom and scrolling own the document while they run. A resize mid-zoom moves the
    /// focus, and correcting the offset for a resize above the anchor stops momentum; those wait
    /// until the motion ends. Resizes at or below the anchor need no correction and apply at once.
    private func deferImageLayout(of key: ReaderPageImageKey) -> Bool {
        if isChangingZoom || scrollView.isZooming { return true }
        guard scrollView.isDragging || scrollView.isDecelerating,
              let anchor = visibleAnchor(), let anchorRow = rowIndexByPageID[anchor.pageID] else { return false }
        return imageKeyByPageID.contains { pageID, pageKey in
            pageKey == key && (rowIndexByPageID[pageID] ?? Int.max) < anchorRow
        }
    }

    private func commitPendingImageLayouts() {
        guard !pendingImageLayouts.isEmpty, !isInvalidated else { return }
        let pending = pendingImageLayouts
        pendingImageLayouts = [:]
        commitAnchored {
            for (key, layout) in pending where imageObservations[key] != nil {
                pixelSizes[key] = layout.size
                if layout.failed { failedKeys.insert(key) } else { failedKeys.remove(key) }
            }
        }
    }

    private static func validSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }

    // MARK: - Navigation and viewport

    private func navigate(to request: MangaScrollRequest) {
        guard !isInvalidated else { return }
        pendingNavigation = request
        performPendingNavigation()
    }

    private func performPendingNavigation() {
        guard let request = pendingNavigation, scrollView.bounds.height > 0,
              let frame = pageFrame(request.pageID) else { return }
        viewportEpoch &+= 1
        let maximum = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let target = CGPoint(x: scrollView.contentOffset.x, y: min(max(frame.minY * scrollView.zoomScale, 0), maximum))
        pendingNavigation = nil
        if request.animated && target != scrollView.contentOffset {
            animatingNavigation = request
            scrollView.setContentOffset(target, animated: true)
        } else {
            animatingNavigation = nil
            isLandingNavigation = true
            scrollView.setContentOffset(target, animated: false)
            updateRendererWindow()
            isLandingNavigation = false
            _ = refreshViewportRetention()
            acknowledge(request, landed: true, appendingIfNearEnd: false)
            settleIfAtRest()
        }
    }

    /// Ends a jump. One that landed makes its page current even if a sliver of the page above
    /// shows; one a drag took over leaves the choice to what is on screen.
    private func acknowledge(_ request: MangaScrollRequest, landed: Bool, appendingIfNearEnd: Bool) {
        recordViewportChange()
        let epoch = viewportEpoch
        // Consume only the request still owned by the view model. If geometry changes before
        // delivery, acknowledge the current viewport rather than publishing a stale landing.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInvalidated, self.viewModel.scrollTarget == request else { return }
            let isCurrentLanding = landed && self.viewportEpoch == epoch
            let pageIDs = self.visiblePageIDs()
            self.viewModel.consumeScrollTarget(request)
            guard self.pendingNavigation == nil, !self.isChangingZoom,
                  !self.scrollView.isZooming, !self.scrollView.isZoomBouncing else { return }
            guard !pageIDs.isEmpty else { return }
            self.lastReportedPageIDs = pageIDs
            self.viewModel.continuousViewportChanged(
                pageIDs,
                preferredPageID: isCurrentLanding ? request.pageID : nil
            )
            if appendingIfNearEnd { self.appendIfNearEnd() }
        }
    }

    /// Eviction protection is synchronous and never advances reading progress.
    private func refreshViewportRetention() -> [String] {
        guard !isInvalidated, !isCommittingLayout, !isLandingNavigation else { return [] }
        let pageIDs = visiblePageIDs()
        viewportRetention.update(pageIDs)
        return pageIDs
    }

    /// Reports the pages on screen when they change. A restore or jump not yet started owns the
    /// position, so nothing is reported until it is applied; an animated jump's passing pages are
    /// reported, and its landing makes its page current.
    private func reportViewport() {
        let pageIDs = refreshViewportRetention()
        recordViewportChange()
        guard !isInvalidated, pendingNavigation == nil, !isLandingNavigation,
              !isCommittingLayout, !isChangingZoom, !scrollView.isZooming, !scrollView.isZoomBouncing else { return }
        guard !pageIDs.isEmpty, pageIDs != lastReportedPageIDs else { return }
        let epoch = viewportEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            let deliveredPageIDs: [String]
            if self.viewportEpoch == epoch {
                deliveredPageIDs = pageIDs
            } else {
                guard self.pendingNavigation == nil, !self.isLandingNavigation,
                      !self.isCommittingLayout, !self.isChangingZoom,
                      !self.scrollView.isZooming, !self.scrollView.isZoomBouncing else { return }
                deliveredPageIDs = self.visiblePageIDs()
            }
            guard !deliveredPageIDs.isEmpty, deliveredPageIDs != self.lastReportedPageIDs else { return }
            self.lastReportedPageIDs = deliveredPageIDs
            self.viewModel.continuousViewportChanged(deliveredPageIDs)
        }
    }

    /// Scheduling a report is not a viewport change. Native movement and geometry invalidate
    /// captured landings; duplicate delegate callbacks for the same bounds do not.
    private func recordViewportChange() {
        let bounds = scrollView.bounds
        let scale = scrollView.zoomScale
        guard bounds != observedViewportBounds || scale != observedZoomScale else { return }
        observedViewportBounds = bounds
        observedZoomScale = scale
        viewportEpoch &+= 1
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        recordViewportChange()
        updateRendererWindow()
        // A programmatic jump can end momentum without a deceleration callback.
        commitPendingImageLayoutsIfSettled()
        reportViewport()
        let isUserScroll = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if isUserScroll && !isChangingZoom && !scrollView.isZooming { appendIfNearEnd() }
    }

    /// Applies deferred image layout once neither zoom, a touch, momentum nor an animated jump
    /// owns the position. Animated scrolls start only from navigation, tracked as `animatingNavigation`.
    private func commitPendingImageLayoutsIfSettled() {
        guard !isCommittingLayout, !isChangingZoom, animatingNavigation == nil, !scrollView.isZooming,
              !scrollView.isDragging, !scrollView.isDecelerating else { return }
        commitPendingImageLayouts()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        guard let request = animatingNavigation else {
            commitPendingImageLayoutsIfSettled()
            settleIfAtRest()
            return
        }
        animatingNavigation = nil
        acknowledge(request, landed: true, appendingIfNearEnd: true)
        commitPendingImageLayoutsIfSettled()
        settleIfAtRest()
        reportViewport()
    }

    /// A page or chapter jump can end a fling without a deceleration callback; once nothing
    /// moves the viewport, chapters held loaded meanwhile can be dropped.
    private func settleIfAtRest() {
        guard !isCommittingLayout, !isChangingZoom, animatingNavigation == nil, !scrollView.isZooming,
              !scrollView.isDragging, !scrollView.isDecelerating else { return }
        viewportSettled()
    }

    /// A drag takes over from a jump still animating: the jump is over, and the page on screen
    /// is whatever the drag shows.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        viewportRetention.setMoving(true)
        guard let request = animatingNavigation else { return }
        animatingNavigation = nil
        acknowledge(request, landed: false, appendingIfNearEnd: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === self.scrollView, !decelerate, !isChangingZoom else { return }
        commitPendingImageLayouts()
        viewportSettled()
        reportViewport()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !isChangingZoom else { return }
        commitPendingImageLayouts()
        viewportSettled()
        reportViewport()
    }

    /// The user stopped moving the viewport: chapters held loaded meanwhile can be dropped now,
    /// with their position correction applied at rest instead of during the gesture.
    private func viewportSettled() {
        viewportRetention.setMoving(false)
        viewModel.continuousViewportSettled()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === self.scrollView ? documentView : nil
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isChangingZoom = true
        viewportRetention.setMoving(true)
        viewportEpoch &+= 1
        lastReportedPageIDs = []
        if let request = animatingNavigation {
            animatingNavigation = nil
            acknowledge(request, landed: false, appendingIfNearEnd: false)
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        recordViewportChange()
        updateRendererWindow()
        _ = refreshViewportRetention()
        commitPendingImageLayoutsIfSettled()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isChangingZoom = false
        commitPendingImageLayouts()
        updateRendererWindow()
        if !scrollView.isDragging, !scrollView.isDecelerating { viewportSettled() }
        reportViewport()
    }

    /// Asks for the next chapter when the user scrolls near the bottom of the last page. Only
    /// the user's own scrolling counts: inserting rows never starts another load.
    private func appendIfNearEnd() {
        guard let snapshot, snapshot.nextChapter != nil, !snapshot.loadingNext, !snapshot.appendFailed,
              view.window != nil, let lastPage = snapshot.pages.last, let frame = pageFrame(lastPage.id) else {
            return
        }
        let viewport = documentViewport
        guard frame.maxY - viewport.maxY <= viewport.height * Self.appendDistanceInViewports else { return }
        let revision = snapshot.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInvalidated, self.snapshot?.revision == revision else { return }
            self.viewModel.appendNextChapter()
        }
    }

    // MARK: - Cells

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MangaContinuousHostingCell.reuseID,
            for: indexPath
        )
        (cell as? MangaContinuousHostingCell)?.configure(row: rows[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !isInvalidated, rows.indices.contains(indexPath.item),
              let cell = cell as? MangaContinuousHostingCell else { return }
        let row = rows[indexPath.item]
        cell.host(content(for: row), row: row, parent: self)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // The callback's old index path may no longer describe the current snapshot.
        (cell as? MangaContinuousHostingCell)?.stopDisplaying()
    }

    private func content(for row: MangaContinuousRow) -> AnyView {
        switch row {
        case .previousChapter:
            return AnyView(previousPrompt())
        case .nextChapter:
            return AnyView(nextPrompt())
        case .divider(let pageID):
            guard let chapter = pagesByID[pageID]?.chapter else { return AnyView(EmptyView()) }
            return AnyView(MangaContinuousChapterDivider(chapter: chapter))
        case .page(let pageID):
            guard let page = pagesByID[pageID] else { return AnyView(EmptyView()) }
            return pageContent(page)
        }
    }

    private func pageContent(_ page: FlatPage) -> AnyView {
        switch page.page.content {
        case .url(let url):
            return AnyView(MangaImage(
                urlStr: url,
                headers: page.page.headers,
                session: viewModel.imageSession,
                pageID: page.id,
                fillsRowWidth: true,
                interaction: .continuous(onTap: { [weak self] in self?.onToggleUI() }),
                imageLabel: String(localized: "Page \(page.chapterPosition + 1)", comment: "Accessibility label of a manga page; number is its position in the chapter")
            ))
        case .text(let text):
            return AnyView(MangaContinuousTextPage(text: text))
        }
    }

    private func previousPrompt() -> MangaContinuousChapterPrompt {
        let boundary = snapshot?.previousBoundary ?? .end
        return MangaContinuousChapterPrompt(
            chapter: boundary.candidate,
            isNext: false,
            phase: snapshot?.loadingPrevious == true ? .loading : snapshot?.prependFailed == true ? .failed : .tap,
            notice: ReaderBoundaryNotice.pages(for: boundary, isNext: false),
            action: { [weak self] in self?.viewModel.prependPreviousChapter() }
        )
    }

    private func nextPrompt() -> MangaContinuousChapterPrompt {
        let boundary = snapshot?.nextBoundary ?? .end
        return MangaContinuousChapterPrompt(
            chapter: boundary.candidate,
            isNext: true,
            phase: snapshot?.loadingNext == true ? .loading : snapshot?.appendFailed == true ? .failed : .tap,
            notice: ReaderBoundaryNotice.pages(for: boundary, isNext: true),
            action: { [weak self] in
                guard let self else { return }
                if self.snapshot?.appendFailed == true {
                    self.viewModel.retryAppendNextChapter()
                } else {
                    self.viewModel.appendNextChapter()
                }
            }
        )
    }
}

/// Places rows at frames the controller computed; nothing is measured during layout.
@MainActor
final class MangaContinuousCollectionViewLayout: UICollectionViewLayout {
    private(set) var frames: [CGRect] = []
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var contentSize: CGSize = .zero

    func setFrames(_ frames: [CGRect]) {
        guard self.frames != frames else { return }
        self.frames = frames
        attributes = frames.enumerated().map { index, frame in
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = frame
            return attribute
        }
        contentSize = CGSize(width: frames.first?.width ?? 0, height: frames.last?.maxY ?? 0)
        invalidateLayout()
    }

    override var collectionViewContentSize: CGSize { contentSize }

    /// Indices of rows intersecting `rect`, found by binary search over the ordered frames.
    func rowIndices(in rect: CGRect) -> Range<Int> {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY <= rect.minY { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < frames.count, frames[end].minY < rect.maxY { end += 1 }
        return low..<end
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        Array(attributes[rowIndices(in: rect)])
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

@MainActor
private final class MangaContinuousHostingCell: UICollectionViewCell {
    static let reuseID = "MangaContinuousHostingCell"
    private var hostingController: UIHostingController<AnyView>?
    private var row: MangaContinuousRow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: MangaContinuousRow) {
        if self.row != row { stopDisplaying() }
        self.row = row
    }

    /// Only displayed cells own a live hosted subtree and its visible image lease.
    func host(_ content: AnyView, row: MangaContinuousRow, parent: UIViewController) {
        configure(row: row)
        let rootView = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .id(row)
        )
        let controller: UIHostingController<AnyView>
        if let existing = hostingController {
            controller = existing
            controller.rootView = rootView
        } else {
            controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            hostingController = controller
        }
        let attaching = controller.parent !== parent
        if attaching { parent.addChild(controller) }
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if controller.view.superview !== contentView { contentView.addSubview(controller.view) }
        if attaching { controller.didMove(toParent: parent) }
    }

    func stopDisplaying() {
        if let hostingController { Self.detach(hostingController) }
    }

    static func detach(_ controller: UIHostingController<AnyView>) {
        controller.rootView = AnyView(EmptyView())
        guard controller.parent != nil || controller.view.superview != nil else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopDisplaying()
        row = nil
    }
}

/// A text page: body text with standard padding. Measured and drawn from the same view.
private struct MangaContinuousTextPage: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
    }
}

private struct MangaContinuousChapterDivider: View {
    let chapter: Manga.Chapter

    var body: some View {
        VStack(spacing: 14) {
            rule
            VStack(spacing: 6) {
                Text("Next Chapter")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white.opacity(0.35))
                    .textCase(.uppercase)
                Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber))
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            rule
        }
        .padding(.vertical, 40)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 24)
    }
}

private struct MangaContinuousChapterPrompt: View {
    enum Phase {
        case tap
        case loading
        case failed
    }

    let chapter: Manga.Chapter?
    let isNext: Bool
    let phase: Phase
    /// Set where the reader stops at this neighbor; the prompt then only says why and does nothing.
    let notice: ReaderBoundaryNotice?
    let action: () -> Void

    var body: some View {
        if notice != nil {
            // Where reading stops there is nothing to press: the prompt only says why.
            content.accessibilityElement(children: .combine)
        } else {
            Button(action: action) { content }
                .disabled(phase == .loading)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            if let notice {
                Image(systemName: notice.systemImage)
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            } else {
                switch phase {
                case .loading:
                    ProgressView().tint(.white)
                case .tap:
                    Image(systemName: isNext ? "arrow.down.circle" : "arrow.up.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                }
            }
            Text(prompt)
                .foregroundColor(.white)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let chapter {
                Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber))
                    .foregroundColor(.gray)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
        .padding(40)
    }

    /// Identifies everything that affects this prompt's height.
    var measurementKey: String {
        "prompt|\(isNext)|\(phase)|\(notice?.text ?? "")|\(chapter.map { ReaderChapterTitle.text(title: $0.title, number: $0.chapterNumber) } ?? "")"
    }

    private var prompt: String {
        if let notice { return notice.text }
        switch (phase, isNext) {
        case (.tap, true): return String(localized: "Tap to Load Next Chapter")
        case (.tap, false): return String(localized: "Tap to Load Previous Chapter")
        case (.loading, true): return String(localized: "Loading Next Chapter...")
        case (.loading, false): return String(localized: "Loading Previous Chapter...")
        case (.failed, true): return String(localized: "Couldn't load the next chapter. Tap to try again.")
        case (.failed, false): return String(localized: "Couldn't load the previous chapter. Tap to try again.")
        }
    }
}
