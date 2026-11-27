import SwiftUI
import UIKit
import ito_runner

struct NovelPagingReaderView: View {
    let imageSession: ReaderPageImageSession
    let loadedChapters: [NovelLoadedChapter]
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let theme: NovelTheme
    let prefetchChapters: Bool
    let onLoadNextChapter: () -> Void
    /// The next chapter failed to load; `onRetryNextChapter` tries again.
    let appendFailed: Bool
    let onRetryNextChapter: () -> Void
    /// Why reading stops after the last loaded chapter, when the next one cannot be opened here.
    let boundaryNotice: ReaderBoundaryNotice?
    @Binding var currentChapter: Novel.Chapter
    /// A place to open at once pages exist; reported back through `onRestoreAnchorApplied`.
    let restoreAnchor: NovelReadingAnchor?
    let onRestoreAnchorApplied: (NovelReadingAnchor) -> Void
    /// Called with the chapter, offset and whether the page is the chapter's last.
    let onPositionChanged: (UUID, Int, Bool) -> Void
    /// Why reading stops before the first loaded chapter, when the previous one cannot be opened here.
    var previousBoundaryNotice: ReaderBoundaryNotice?
    /// Asked when the reader's notice offers consent for, or continuing in the other reader with, the next chapter.
    var onBoundaryNoticeTap: () -> Void = {}
    var onPreviousBoundaryNoticeTap: () -> Void = {}
    /// Told with the paginated layout's generation and the chapter shown once pages are laid out and the
    /// requested place applied.
    let onInitialLayoutApplied: (Int, UUID) -> Void
    /// Told when laying the pages out produced no result and was not replaced.
    let onLayoutFailed: () -> Void
    /// Told with the request's key whenever an illustration page holds a visible lease on its image.
    let onInitialImageVisibleLease: (ReaderPageImageKey) -> Void

    @State private var paginatedCache: [UUID: [NovelPaginationPage]] = [:]
    @State private var flattenedPages: [NovelPaginationPage] = []
    /// Page index ranges shown together over `flattenedPages`: one page, or two side by side in a spread.
    @State private var spreads: [Range<Int>] = []
    /// The width of one page's text column for the current window and font size.
    @State private var textWidth: CGFloat = 0
    @State private var currentPageIndex: Int = 0
    /// The exact place last reported, so a relayout reopens at the same text.
    @State private var readingAnchor: NovelReadingAnchor?
    @State private var pageSize: CGSize = .zero
    /// Bumped for each pagination request; a result from an older request is dropped.
    @State private var paginationGeneration = 0
    @State private var paginationTask: Task<Void, Never>?
    /// The off-main layout itself; cancelled when a newer request replaces it.
    @State private var layoutTask: Task<[NovelPaginationPage]?, Never>?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            // The width inside the horizontal safe-area insets, clear of the Duo status column.
            let size = CGSize(width: geo.size.width - insets.leading - insets.trailing, height: geo.size.height)

            ZStack {
                if flattenedPages.isEmpty {
                    ProgressView("Paginating...")
                        .tint(theme.textColor)
                        .foregroundColor(theme.textColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PageViewController(
                        pages: flattenedPages,
                        spreads: spreads,
                        imageSession: imageSession,
                        currentPage: $currentPageIndex,
                        textWidth: textWidth,
                        textColor: theme.textColor,
                        onImageVisibleLease: onInitialImageVisibleLease,
                        onPageChanged: { newIndex in
                            if newIndex >= 0 && newIndex < flattenedPages.count {
                                let newChap = flattenedPages[newIndex].chapter
                                if newChap.key != currentChapter.key {
                                    currentChapter = newChap
                                }
                                reportPosition(of: flattenedPages, spreads: spreads, at: newIndex)

                                // Prefetch trigger
                                if prefetchChapters && newIndex >= flattenedPages.count - 3 {
                                    onLoadNextChapter()
                                }
                            }
                        }
                    )

                    // Footer Overlays (Battery & Page Counter)
                    VStack {
                        Spacer()
                        HStack {
                            BatteryIndicator(theme: theme)
                                .padding(.leading, 16)

                            Spacer()

                            Text(Self.chapterPageLabel(of: flattenedPages, at: currentPageIndex))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(theme.textColor.opacity(0.5))
                                .padding(.trailing, 16)
                        }
                        .padding(.bottom, 8)
                    }
                    .allowsHitTesting(false)

                    if let boundaryNotice, shownPages.upperBound == flattenedPages.count {
                        noticeCapsule(boundaryNotice, onTap: onBoundaryNoticeTap)
                    }

                    if let previousBoundaryNotice, shownPages.lowerBound == 0 {
                        noticeCapsule(previousBoundaryNotice, onTap: onPreviousBoundaryNoticeTap, atTop: true)
                    }

                    if appendFailed, boundaryNotice == nil, shownPages.lowerBound >= flattenedPages.count - 3 {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Text("Couldn't load the next chapter")
                                    .font(.footnote)
                                Button("Try Again", action: onRetryNextChapter)
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundColor(theme.textColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(theme.backgroundColor.opacity(0.95), in: Capsule())
                            .overlay(Capsule().stroke(theme.textColor.opacity(0.2), lineWidth: 1))
                            .padding(.bottom, 32)
                        }
                    }
                }
            }
            .padding(.leading, geo.safeAreaInsets.leading)
            .padding(.trailing, geo.safeAreaInsets.trailing)
            .onAppear {
                if pageSize == .zero && size.width > 0 {
                    pageSize = size
                    repaginate(configuration(size: size))
                }
            }
            // Each change passes its new value: the view's own copy may not have caught up yet.
            .onChange(of: size) { newSize in
                guard newSize != pageSize else { return }
                pageSize = newSize
                repaginate(configuration(size: newSize), discardingLayout: true)
            }
            .onChange(of: verticalSizeClass) { _ in
                // The width class depends on the vertical size class, so a change re-lays out the pages.
                repaginate(configuration(size: size), discardingLayout: true)
            }
            .onChange(of: loadedChapters) { _ in
                repaginate(configuration(size: size))
            }
            .onChange(of: fontSize) { newSize in
                repaginate(configuration(size: size, fontSize: newSize), discardingLayout: true)
            }
            .onChange(of: fontFamily) { newFamily in
                repaginate(configuration(size: size, fontFamily: newFamily), discardingLayout: true)
            }
            .onChange(of: lineSpacing) { newSpacing in
                repaginate(configuration(size: size, lineSpacing: newSpacing), discardingLayout: true)
            }
            .onChange(of: theme) { newTheme in
                // Colour does not move page breaks: recolour the laid-out pages instead.
                let color = UIColor(newTheme.textColor)
                paginatedCache = paginatedCache.mapValues { $0.map { $0.recolored(color) } }
                repaginate(configuration(size: size, theme: newTheme))
            }
            .onDisappear {
                paginationTask?.cancel()
                layoutTask?.cancel()
            }
        }
    }

    /// The notice at a loaded chapter's edge. One that offers consent or a continuation is a button.
    private func noticeCapsule(
        _ notice: ReaderBoundaryNotice,
        onTap: @escaping () -> Void,
        atTop: Bool = false
    ) -> some View {
        let isAction = notice.requestsGroupConsent || notice.requestsHandoff
        return VStack {
            if !atTop { Spacer() }
            HStack(spacing: 8) {
                Image(systemName: notice.systemImage)
                    .accessibilityHidden(true)
                Text(notice.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isAction ? .isButton : [])
            .font(.footnote)
            .foregroundColor(theme.textColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.backgroundColor.opacity(0.95), in: Capsule())
            .overlay(Capsule().stroke(theme.textColor.opacity(0.2), lineWidth: 1))
            .padding(atTop ? .top : .bottom, 32)
            .onTapGesture { if isAction { onTap() } }
            if atTop { Spacer() }
        }
        .allowsHitTesting(isAction)
    }

    /// What the pages are laid out for: the engine inputs, whether two pages share a spread, and the text width.
    private struct PagingLayout {
        let configuration: NovelPaginationConfiguration
        let spread: Bool
        let textWidth: CGFloat
    }

    /// The pagination inputs and text column for a window of `size` at the given settings.
    private func configuration(
        size: CGSize,
        fontSize: Double? = nil,
        fontFamily: NovelFont? = nil,
        lineSpacing: Double? = nil,
        theme: NovelTheme? = nil
    ) -> PagingLayout {
        let resolvedFontSize = fontSize ?? self.fontSize
        let spread = NovelReaderLayout.showsSpread(
            widthClass: WidthClass.make(size: size, verticallyRegular: verticalSizeClass == .regular)
        )
        let width = NovelReaderLayout.pageTextWidth(
            availableWidth: size.width,
            fontSize: resolvedFontSize,
            spread: spread
        )
        return PagingLayout(
            configuration: NovelPaginationConfiguration(
                // The engine insets each page by the page inset on both sides, so the container adds them back.
                containerSize: CGSize(width: width + 2 * NovelReaderLayout.pageInset, height: size.height),
                fontSize: resolvedFontSize,
                fontFamily: fontFamily ?? self.fontFamily,
                lineSpacing: lineSpacing ?? self.lineSpacing,
                textColor: UIColor((theme ?? self.theme).textColor)
            ),
            spread: spread,
            textWidth: width
        )
    }

    /// Lays out chapters that have no pages yet, off the main thread, then shows the pages at
    /// the reader's current place. `discardingLayout` lays every chapter out again.
    private func repaginate(
        _ pagingLayout: PagingLayout,
        discardingLayout: Bool = false
    ) {
        let configuration = pagingLayout.configuration
        guard configuration.containerSize.width > 0,
              configuration.containerSize.height > 0 else { return }
        if discardingLayout {
            paginatedCache.removeAll()
        }
        let chapters = loadedChapters
        let missing = chapters
            .filter { paginatedCache[$0.id] == nil }
            .map { NovelPaginationChapter(id: $0.id, chapter: $0.chapter, pages: $0.pages) }
        paginationGeneration += 1
        let generation = paginationGeneration
        paginationTask?.cancel()
        layoutTask?.cancel()
        guard !missing.isEmpty else {
            showPages(of: chapters, layout: pagingLayout)
            return
        }
        let layout = Task.detached(priority: .userInitiated) {
            NovelPaginationEngine.paginate(chapters: missing, configuration: configuration)
        }
        layoutTask = layout
        paginationTask = Task { @MainActor in
            let pages = await layout.value
            guard generation == paginationGeneration else { return }
            guard let pages else {
                // A layout that produced nothing and was not replaced failed; a replaced one is not a result.
                if !Task.isCancelled { onLayoutFailed() }
                return
            }
            let byChapter = Dictionary(grouping: pages, by: \.chapterID)
            for chapter in missing {
                paginatedCache[chapter.id] = byChapter[chapter.id] ?? []
            }
            showPages(of: chapters, layout: pagingLayout)
        }
    }

    /// Shows the laid-out pages of `chapters`, opening at the pending restore place if any, then at
    /// the place last reported, so a relayout keeps the same text on screen.
    private func showPages(of chapters: [NovelLoadedChapter], layout: PagingLayout) {
        let loadedIDs = Set(chapters.map(\.id))
        paginatedCache = paginatedCache.filter { loadedIDs.contains($0.key) }
        let pages = chapters.flatMap { paginatedCache[$0.id] ?? [] }
        let pageSpreads = NovelReaderLayout.spreads(count: pages.count, spread: layout.spread) { index in
            pages[index].image == nil && pages[index + 1].image == nil
                && pages[index].chapterID == pages[index + 1].chapterID
        }

        let newIndex: Int
        let exactOffset: Int?
        if let restoreAnchor, let index = Self.pageIndex(for: restoreAnchor, in: pages) {
            newIndex = index
            exactOffset = restoreAnchor.offset
            onRestoreAnchorApplied(restoreAnchor)
        } else if let readingAnchor, let index = Self.pageIndex(for: readingAnchor, in: pages) {
            newIndex = index
            exactOffset = readingAnchor.offset
        } else {
            newIndex = min(currentPageIndex, max(0, pages.count - 1))
            exactOffset = nil
        }
        // A spread opens at its first page. The exact offset falls within the page at `newIndex`,
        // which lies in that spread, so the reported place is never before the one reached.
        let shownStart = NovelReaderLayout.spreadIndex(containing: newIndex, in: pageSpreads)
            .map { pageSpreads[$0].lowerBound } ?? newIndex
        flattenedPages = pages
        spreads = pageSpreads
        textWidth = layout.textWidth
        currentPageIndex = shownStart
        reportPosition(of: pages, spreads: pageSpreads, at: shownStart, exactOffset: exactOffset)
        if pages.indices.contains(newIndex) {
            // The pages are laid out and the requested place is the one shown.
            onInitialLayoutApplied(paginationGeneration, pages[newIndex].chapterID)
        }
        // Opening or restoring near the end loads the next chapter, as a swipe there would.
        if prefetchChapters && newIndex >= pages.count - 3 {
            onLoadNextChapter()
        }
    }

    /// "3/12": the page's place within its own chapter, as the manga reader counts.
    static func chapterPageLabel(of pages: [NovelPaginationPage], at index: Int) -> String {
        guard pages.indices.contains(index) else { return "" }
        let chapterID = pages[index].chapterID
        let chapterPages = pages.indices.filter { pages[$0].chapterID == chapterID }
        let position = (chapterPages.firstIndex(of: index) ?? 0) + 1
        return "\(position)/\(chapterPages.count)"
    }

    /// The page in the anchor's chapter that contains its offset.
    static func pageIndex(for anchor: NovelReadingAnchor, in pages: [NovelPaginationPage]) -> Int? {
        pages.indices.last { index in
            pages[index].chapterID == anchor.chapterID && pages[index].startOffset <= anchor.offset
        } ?? pages.firstIndex { $0.chapterID == anchor.chapterID }
    }

    /// The pages on screen: the spread that holds the current page.
    private var shownPages: Range<Int> {
        NovelReaderLayout.spreadIndex(containing: currentPageIndex, in: spreads).map { spreads[$0] }
            ?? (currentPageIndex..<(currentPageIndex + 1))
    }

    /// Reports the place as the start of the page at `index`, or as `exactOffset` when the reader is
    /// at a known offset within that page. The reported place is never before the page's start.
    private func reportPosition(
        of pages: [NovelPaginationPage],
        spreads: [Range<Int>],
        at index: Int,
        exactOffset: Int? = nil
    ) {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        let offset = max(exactOffset ?? page.startOffset, page.startOffset)
        let lastOnScreen = NovelReaderLayout.spreadIndex(containing: index, in: spreads)
            .map { spreads[$0].upperBound - 1 } ?? index
        readingAnchor = NovelReadingAnchor(chapterID: page.chapterID, offset: offset)
        onPositionChanged(page.chapterID, offset, pages[lastOnScreen].isLastInChapter)
    }
}

// MARK: - UIPageViewController Wrapper

struct PageViewController: UIViewControllerRepresentable {
    let pages: [NovelPaginationPage]
    /// Page index ranges shown together: one page, or two side by side in a spread.
    let spreads: [Range<Int>]
    let imageSession: ReaderPageImageSession
    @Binding var currentPage: Int
    /// The width of one page's text column.
    let textWidth: CGFloat
    /// For image pages' loading and error content.
    let textColor: Color
    /// Told with the request's key whenever an illustration page holds a visible lease on its image.
    let onImageVisibleLease: (ReaderPageImageKey) -> Void
    /// Told with the first page index of the spread shown.
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear

        if let firstVC = context.coordinator.makePageContentVC(containingPage: currentPage) {
            pvc.setViewControllers([firstVC], direction: .forward, animated: false)
        }

        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldPages = coordinator.parent.pages
        let oldSpreads = coordinator.parent.spreads
        coordinator.parent = self

        // Pages added after the existing ones are served by the data source, except when the
        // last page is showing: the page controller may already have been told there is no
        // next page, so the shown spread is set again. Changed pages or spreads, or a current
        // page outside the shown spread, also need the shown spread replaced. A text width change
        // always comes with repaginated pages, so it needs no separate check.
        let existingChanged = pages.count < oldPages.count
            || zip(oldPages, pages).contains(where: { $0.0.string !== $0.1.string })
        let spreadsChanged = spreads.count < oldSpreads.count
            || zip(oldSpreads, spreads).contains(where: { $0.0 != $0.1 })
        let shown = pvc.viewControllers?.first as? PageContentViewController
        let appendedAfterShownLastPage = pages.count > oldPages.count
            && shown?.pageRange.upperBound == oldPages.count
        let showsCurrentPage = shown?.pageRange.contains(currentPage) == true
        guard existingChanged || spreadsChanged || appendedAfterShownLastPage || !showsCurrentPage else { return }
        if coordinator.isTransitioning {
            // Replacing pages in the middle of a swipe confuses the page controller.
            coordinator.needsRefresh = true
        } else {
            coordinator.showPage(in: pvc, at: currentPage)
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageViewController
        var isTransitioning = false
        var needsRefresh = false

        init(_ parent: PageViewController) {
            self.parent = parent
        }

        /// Shows the spread that holds `page`, clamped to the available pages.
        func showPage(in pvc: UIPageViewController, at page: Int) {
            needsRefresh = false
            let target = min(page, max(0, parent.pages.count - 1))
            if let vc = makePageContentVC(containingPage: target) {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            }
        }

        /// A controller for the spread that holds `page`.
        func makePageContentVC(containingPage page: Int) -> PageContentViewController? {
            guard let spread = NovelReaderLayout.spreadIndex(containing: page, in: parent.spreads) else { return nil }
            let range = parent.spreads[spread]
            let vc = PageContentViewController()
            vc.pageRange = range
            vc.pages = Array(parent.pages[range])
            vc.textWidth = parent.textWidth
            vc.imageSession = parent.imageSession
            vc.foreground = parent.textColor
            vc.onImageVisibleLease = parent.onImageVisibleLease
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController, vc.pageRange.lowerBound > 0 else { return nil }
            return makePageContentVC(containingPage: vc.pageRange.lowerBound - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController else { return nil }
            return makePageContentVC(containingPage: vc.pageRange.upperBound)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isTransitioning = false
            var shown = parent.currentPage
            if completed,
               let vc = pageViewController.viewControllers?.first as? PageContentViewController {
                // After a relayout during the swipe, the spread swiped to belongs to the old
                // layout: find its text in the new one instead of trusting its old index.
                let page = needsRefresh ? index(ofTextOn: vc) : vc.pageRange.lowerBound
                shown = spreadStart(containing: page)
                parent.currentPage = shown
                parent.onPageChanged(shown)
            }
            if needsRefresh {
                showPage(in: pageViewController, at: shown)
            }
        }

        /// The first page of the spread that holds `page`.
        private func spreadStart(containing page: Int) -> Int {
            guard let spread = NovelReaderLayout.spreadIndex(containing: page, in: parent.spreads) else { return page }
            return parent.spreads[spread].lowerBound
        }

        /// The page in the new layout that holds the text the controller was showing.
        private func index(ofTextOn vc: PageContentViewController) -> Int {
            guard let page = vc.pages.first,
                  let index = NovelPagingReaderView.pageIndex(
                      for: NovelReadingAnchor(chapterID: page.chapterID, offset: page.startOffset),
                      in: parent.pages
                  ) else { return min(vc.pageRange.lowerBound, max(0, parent.pages.count - 1)) }
            return index
        }
    }
}

class PageContentViewController: UIViewController {
    /// The page indexes this controller shows: one page, or both pages of a spread.
    var pageRange: Range<Int> = 0..<0
    var pages: [NovelPaginationPage] = []
    var imageSession: ReaderPageImageSession!
    var textWidth: CGFloat = 0
    var foreground: Color = .primary
    var onImageVisibleLease: ((ReaderPageImageKey) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        if let image = pages.first?.image {
            // Illustration pages are never paired, so the image fills the page.
            showImage(image)
        } else if pages.count == 2 {
            showSpread()
        } else if let page = pages.first {
            showSingleText(page)
        }
    }

    /// A text column for one page. Long-press selection stays on; the built-in double tap is disabled.
    private func makeTextView(_ string: NSAttributedString) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.attributedText = string

        // Disable UITextView's built-in double tap to remove selection conflicts,
        // users can still long-press to select text.
        for recognizer in textView.gestureRecognizers ?? [] {
            if let tapRecognizer = recognizer as? UITapGestureRecognizer, tapRecognizer.numberOfTapsRequired == 2 {
                tapRecognizer.isEnabled = false
            }
        }
        return textView
    }

    /// One text column, centered at the readable width.
    private func showSingleText(_ page: NovelPaginationPage) {
        let textView = makeTextView(page.string)
        view.addSubview(textView)
        let width = textView.widthAnchor.constraint(equalToConstant: textWidth)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            width
        ])
    }

    /// Two text columns side by side, centered as one block of two columns and the gutter.
    private func showSpread() {
        let row = UIStackView(arrangedSubviews: [makeTextView(pages[0].string), makeTextView(pages[1].string)])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = NovelReaderLayout.spreadGutter
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        let width = row.widthAnchor.constraint(equalToConstant: 2 * textWidth + NovelReaderLayout.spreadGutter)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            width
        ])
    }

    /// An illustration fills the page, loaded the same way as in continuous mode.
    private func showImage(_ image: NovelPageImage) {
        let host = UIHostingController(
            rootView: MangaImage(
                urlStr: image.url,
                headers: image.headers,
                session: imageSession,
                pageID: "novel-paged-\(pages.first?.chapterID.uuidString ?? "")-\(pageRange.lowerBound)",
                foreground: foreground,
                interaction: .passive,
                onVisibleLeaseAcquired: onImageVisibleLease
            )
        )
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        host.didMove(toParent: self)
    }
}

// MARK: - Battery Indicator

struct BatteryIndicator: View {
    let theme: NovelTheme
    @State private var level: Float = -1.0
    @State private var state: UIDevice.BatteryState = .unknown

    var body: some View {
        Group {
            if level >= 0 {
                HStack(spacing: 4) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 10, weight: .regular))
                    Text("\(Int(level * 100))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                }
                .foregroundColor(theme.textColor.opacity(0.5))
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
            state = UIDevice.current.batteryState
        }
        .onDisappear {
            // Monitoring costs power and nothing else in the app reads the battery.
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            level = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            state = UIDevice.current.batteryState
        }
    }

    private var batteryIcon: String {
        if state == .charging || state == .full {
            return "battery.100.bolt"
        }
        if level > 0.85 { return "battery.100" }
        if level > 0.60 { return "battery.75" }
        if level > 0.35 { return "battery.50" }
        if level > 0.10 { return "battery.25" }
        return "battery.0"
    }
}
