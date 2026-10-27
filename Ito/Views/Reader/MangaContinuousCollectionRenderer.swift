import Combine
import SwiftUI
import UIKit
import ito_runner

/// The continuous (Vertical/Webtoon) reader. A collection view with a deterministic layout owns
/// every frame and the scroll offset: each row's height is known before it is laid out, and any
/// change of rows or heights keeps the topmost visible page at the same pixel on screen.
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
    UICollectionViewDataSource, UICollectionViewDelegate {
    /// Prompt rows: a 400-point minimum content height plus 40 points of padding above and below.
    static let promptHeight: CGFloat = 480
    /// Height-to-width ratio reserved for an image page until its decoded size is known.
    static let fallbackImageRatio: CGFloat = 1.435
    /// The next chapter loads once the user scrolls within this many viewport heights of the
    /// bottom of the last page.
    static let appendDistanceInViewports: CGFloat = 1

    let viewModel: MangaReaderViewModel
    var onToggleUI: () -> Void
    let collectionView: UICollectionView
    private let layout = MangaContinuousCollectionViewLayout()

    private var snapshot: MangaContinuousReaderSnapshot?
    private var rows: [MangaContinuousRow] = []
    private var rowIndexByPageID: [String: Int] = [:]
    private var pagesByID: [String: FlatPage] = [:]
    private var layoutWidth: CGFloat = 0

    private var imageKeyByPageID: [String: ReaderPageImageKey] = [:]
    private var pixelSizes: [ReaderPageImageKey: CGSize] = [:]
    private var imageObservations: [ReaderPageImageKey: ReaderImageObservation] = [:]
    private var measuredHeights: [String: CGFloat] = [:]

    private var subscriptions: Set<AnyCancellable> = []
    private var pendingNavigation: MangaScrollRequest?
    private var animatingNavigation: MangaScrollRequest?
    private var lastReportedPageIDs: [String] = []
    private var isInvalidated = false

#if DEBUG
    /// Called after every layout transaction this controller commits.
    var onLayoutCommitted: (() -> Void)?
#endif

    init(viewModel: MangaReaderViewModel, onToggleUI: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onToggleUI = onToggleUI
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        collectionView.backgroundColor = .black
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(
            MangaContinuousHostingCell.self,
            forCellWithReuseIdentifier: MangaContinuousHostingCell.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
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

    override func loadView() { view = collectionView }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Closing the reader stops the image session and drops its observers; reopening
        // observes every page again.
        cancelImageObservations { _ in true }
        observeImages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.bounds.width != layoutWidth {
            commitAnchored {}
        }
        performPendingNavigation()
        reportViewport()
    }

    /// Stops every callback into the view model; the controller is being removed.
    func invalidate() {
        isInvalidated = true
        subscriptions.removeAll()
        cancelImageObservations { _ in true }
        pendingNavigation = nil
        animatingNavigation = nil
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
        if snapshot.previousChapter != nil { rows.append(.previousChapter) }
        for page in snapshot.pages {
            if page.chapterPosition == 0 && page.segmentIndex > 0 { rows.append(.divider(page.id)) }
            rows.append(.page(page.id))
        }
        if snapshot.nextChapter != nil { rows.append(.nextChapter) }
        return rows
    }

    // MARK: - Layout

    /// Runs `change`, recomputes every frame, and moves the offset by however far the topmost
    /// visible page moved, so that page stays at the same pixel. Runs synchronously: no later
    /// pass corrects the position.
    private func commitAnchored(_ change: () -> Void) {
        let anchor = visibleAnchor()
        change()
        layoutWidth = collectionView.bounds.width
        layout.setFrames(frames(width: layoutWidth))
        var offset = collectionView.contentOffset
        if let anchor, let frame = pageFrame(anchor.pageID) {
            offset.y = frame.minY - anchor.pixelOffset
        }
        if !collectionView.isTracking && !collectionView.isDecelerating {
            let maximum = max(layout.collectionViewContentSize.height - collectionView.bounds.height, 0)
            offset.y = min(max(offset.y, 0), maximum)
        }
        if offset != collectionView.contentOffset {
            collectionView.contentOffset = offset
        }
        collectionView.layoutIfNeeded()
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
                let size = imageKeyByPageID[pageID].flatMap { pixelSizes[$0] }
                let ratio = size.map { $0.height / $0.width } ?? Self.fallbackImageRatio
                return (width * ratio).rounded(.up)
            case .text(let text):
                return Self.textHeight(text, width: width)
            }
        }
    }

    /// A text page is body text with 16 points of padding on every side.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(width - 32, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
            context: nil
        )
        return bounds.height.rounded(.up) + 32
    }

    /// The fitting height of a prompt or divider at `width`, cached per content and width.
    private func measured<Content: View>(
        _ key: String,
        width: CGFloat,
        minimum: CGFloat,
        _ content: () -> Content
    ) -> CGFloat {
        let cacheKey = "\(key)|\(width)"
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

    /// The topmost page with more than one point on screen, and how far its top sits below the
    /// top of the viewport (negative when it starts above it).
    func visibleAnchor() -> (pageID: String, pixelOffset: CGFloat)? {
        guard let first = visiblePageIDs().first, let frame = pageFrame(first) else { return nil }
        return (first, frame.minY - collectionView.contentOffset.y)
    }

    func visiblePageIDs() -> [String] {
        let viewport = collectionView.bounds
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
        var keys: [String: ReaderPageImageKey] = [:]
        for page in snapshot?.pages ?? [] {
            guard case .url(let value) = page.page.content, let url = URL(string: value) else { continue }
            keys[page.id] = ReaderPageImageKey(
                request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: page.page.headers)
            )
        }
        imageKeyByPageID = keys
        let liveKeys = Set(keys.values)
        cancelImageObservations { !liveKeys.contains($0) }
        pixelSizes = pixelSizes.filter { liveKeys.contains($0.key) }
        for key in liveKeys where imageObservations[key] == nil {
            let session = viewModel.imageSession
            imageObservations[key] = session.observe(key) { [weak self] state in
                self?.imageStateChanged(state, key: key)
            }
            if let size = Self.validSize(session.state(for: key).pixelSize) { pixelSizes[key] = size }
        }
    }

    private func cancelImageObservations(where shouldCancel: (ReaderPageImageKey) -> Bool) {
        for (key, observation) in imageObservations where shouldCancel(key) {
            observation.cancel()
            imageObservations[key] = nil
        }
    }

    private func imageStateChanged(_ state: ReaderPageImageState, key: ReaderPageImageKey) {
        guard !isInvalidated, imageObservations[key] != nil,
              let size = Self.validSize(state.pixelSize), pixelSizes[key] != size else { return }
        commitAnchored { pixelSizes[key] = size }
        reportViewport()
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
        guard let request = pendingNavigation, collectionView.bounds.height > 0,
              let frame = pageFrame(request.pageID) else { return }
        pendingNavigation = nil
        let maximum = max(layout.collectionViewContentSize.height - collectionView.bounds.height, 0)
        let target = CGPoint(x: 0, y: min(max(frame.minY, 0), maximum))
        if request.animated && target != collectionView.contentOffset {
            animatingNavigation = request
            collectionView.setContentOffset(target, animated: true)
        } else {
            collectionView.contentOffset = target
            collectionView.layoutIfNeeded()
            acknowledge(request)
        }
    }

    private func acknowledge(_ request: MangaScrollRequest) {
        let pageIDs = visiblePageIDs()
        lastReportedPageIDs = pageIDs
        // Delivered after this UIKit pass, never while SwiftUI or the view model is mid-update.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.viewModel.consumeScrollTarget(request)
            self.viewModel.continuousViewportChanged(pageIDs, preferredPageID: request.pageID)
        }
    }

    /// Reports the pages on screen when they change. A restore or jump in progress owns the
    /// position, so nothing is reported until it lands.
    private func reportViewport() {
        guard !isInvalidated, pendingNavigation == nil, animatingNavigation == nil else { return }
        let pageIDs = visiblePageIDs()
        guard !pageIDs.isEmpty, pageIDs != lastReportedPageIDs else { return }
        lastReportedPageIDs = pageIDs
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.viewModel.continuousViewportChanged(pageIDs)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportViewport()
        let isUserScroll = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if isUserScroll { appendIfNearEnd() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let request = animatingNavigation else { return }
        animatingNavigation = nil
        acknowledge(request)
    }

    /// Asks for the next chapter when the user scrolls near the bottom of the last page. Only
    /// the user's own scrolling counts: inserting rows never starts another load.
    private func appendIfNearEnd() {
        guard let snapshot, snapshot.nextChapter != nil, !snapshot.loadingNext, !snapshot.appendFailed,
              view.window != nil, let lastPage = snapshot.pages.last, let frame = pageFrame(lastPage.id) else {
            return
        }
        let viewport = collectionView.bounds
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
        (cell as? MangaContinuousHostingCell)?.host(content(for: rows[indexPath.item]), parent: self)
        return cell
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
                onImageTap: { [weak self] in self?.onToggleUI() },
                imageLabel: "Page \(page.chapterPosition + 1)"
            ))
        case .text(let text):
            return AnyView(Text(text).foregroundColor(.white).padding().frame(maxWidth: .infinity))
        }
    }

    private func previousPrompt() -> MangaContinuousChapterPrompt {
        let snapshot = snapshot
        return MangaContinuousChapterPrompt(
            chapter: snapshot?.previousChapter,
            isNext: false,
            phase: snapshot?.loadingPrevious == true ? .loading : snapshot?.prependFailed == true ? .failed : .tap,
            action: { [weak self] in self?.viewModel.prependPreviousChapter() }
        )
    }

    private func nextPrompt() -> MangaContinuousChapterPrompt {
        let snapshot = snapshot
        return MangaContinuousChapterPrompt(
            chapter: snapshot?.nextChapter,
            isNext: true,
            phase: snapshot?.loadingNext == true ? .loading : snapshot?.appendFailed == true ? .failed : .tap,
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func host(_ content: AnyView, parent: UIViewController) {
        let rootView = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        )
        if let hostingController {
            hostingController.rootView = rootView
            return
        }
        let controller = UIHostingController(rootView: rootView)
        controller.view.backgroundColor = .clear
        parent.addChild(controller)
        controller.view.frame = contentView.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(controller.view)
        controller.didMove(toParent: parent)
        hostingController = controller
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingController?.rootView = AnyView(EmptyView())
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
                Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapter))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
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
                Text(prompt)
                    .foregroundColor(.white)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let chapter {
                    Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapter))
                        .foregroundColor(.gray)
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
            .padding(40)
        }
        .disabled(phase == .loading)
    }

    /// Identifies everything that affects this prompt's height.
    var measurementKey: String {
        "prompt|\(isNext)|\(phase)|\(chapter.map { ReaderChapterTitle.text(title: $0.title, number: $0.chapter) } ?? "")"
    }

    private var prompt: String {
        switch (phase, isNext) {
        case (.tap, true): return "Tap to Load Next Chapter"
        case (.tap, false): return "Tap to Load Previous Chapter"
        case (.loading, true): return "Loading Next Chapter..."
        case (.loading, false): return "Loading Previous Chapter..."
        case (.failed, true): return "Couldn't load the next chapter. Tap to try again."
        case (.failed, false): return "Couldn't load the previous chapter. Tap to try again."
        }
    }
}
