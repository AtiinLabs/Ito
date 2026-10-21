import SwiftUI
import UIKit
import os
import ito_runner

struct NovelPagingReaderView: View {
    let loadedChapters: [NovelLoadedChapter]
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let theme: NovelTheme
    let prefetchChapters: Bool
    let onLoadNextChapter: () -> Void
    @Binding var currentChapter: Novel.Chapter
    /// A place to open at once pages exist; reported back through `onRestoreAnchorApplied`.
    let restoreAnchor: NovelReadingAnchor?
    let onRestoreAnchorApplied: (NovelReadingAnchor) -> Void
    /// Called with the chapter, offset and whether the page is the chapter's last.
    let onPositionChanged: (UUID, Int, Bool) -> Void

    @State private var paginatedCache: [UUID: [NovelPaginationPage]] = [:]
    @State private var flattenedPages: [NovelPaginationPage] = []
    @State private var currentPageIndex: Int = 0
    @State private var pageSize: CGSize = .zero
    /// Bumped for each pagination request; a result from an older request is dropped.
    @State private var paginationGeneration = 0
    @State private var paginationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                if flattenedPages.isEmpty {
                    ProgressView("Paginating...")
                        .tint(theme.textColor)
                        .foregroundColor(theme.textColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PageViewController(
                        pages: flattenedPages,
                        currentPage: $currentPageIndex,
                        maxWidth: max(0, size.width - 32),
                        textColor: theme.textColor,
                        onPageChanged: { newIndex in
                            if newIndex >= 0 && newIndex < flattenedPages.count {
                                let newChap = flattenedPages[newIndex].chapter
                                if newChap.key != currentChapter.key {
                                    currentChapter = newChap
                                }
                                reportPosition(of: flattenedPages, at: newIndex)

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
                }
            }
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
            .onChange(of: loadedChapters) { _ in
                repaginate(configuration())
            }
            .onChange(of: fontSize) { newSize in
                repaginate(configuration(fontSize: newSize), discardingLayout: true)
            }
            .onChange(of: fontFamily) { newFamily in
                repaginate(configuration(fontFamily: newFamily), discardingLayout: true)
            }
            .onChange(of: lineSpacing) { newSpacing in
                repaginate(configuration(lineSpacing: newSpacing), discardingLayout: true)
            }
            .onChange(of: theme) { newTheme in
                // Colour does not move page breaks: recolour the laid-out pages instead.
                let color = UIColor(newTheme.textColor)
                paginatedCache = paginatedCache.mapValues { $0.map { $0.recolored(color) } }
                repaginate(configuration(theme: newTheme))
            }
        }
    }

    private func configuration(
        size: CGSize? = nil,
        fontSize: Double? = nil,
        fontFamily: NovelFont? = nil,
        lineSpacing: Double? = nil,
        theme: NovelTheme? = nil
    ) -> NovelPaginationConfiguration {
        NovelPaginationConfiguration(
            containerSize: size ?? pageSize,
            fontSize: fontSize ?? self.fontSize,
            fontFamily: fontFamily ?? self.fontFamily,
            lineSpacing: lineSpacing ?? self.lineSpacing,
            textColor: UIColor((theme ?? self.theme).textColor)
        )
    }

    /// Lays out chapters that have no pages yet, off the main thread, then shows the pages at
    /// the reader's current place. `discardingLayout` lays every chapter out again.
    private func repaginate(
        _ configuration: NovelPaginationConfiguration,
        discardingLayout: Bool = false
    ) {
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
        guard !missing.isEmpty else {
            showPages(of: chapters)
            return
        }
        paginationTask = Task { @MainActor in
            let pages = await Task.detached(priority: .userInitiated) {
                NovelPaginationEngine.paginate(chapters: missing, configuration: configuration)
            }.value
            guard generation == paginationGeneration, let pages else { return }
            let byChapter = Dictionary(grouping: pages, by: \.chapterID)
            for chapter in missing {
                paginatedCache[chapter.id] = byChapter[chapter.id] ?? []
            }
            showPages(of: chapters)
        }
    }

    /// Shows the laid-out pages of `chapters`, opening at the pending restore place if any,
    /// otherwise at the text the reader was on before.
    private func showPages(of chapters: [NovelLoadedChapter]) {
        let place = flattenedPages.indices.contains(currentPageIndex)
            ? NovelReadingAnchor(
                chapterID: flattenedPages[currentPageIndex].chapterID,
                offset: flattenedPages[currentPageIndex].startOffset
            )
            : nil
        let loadedIDs = Set(chapters.map(\.id))
        paginatedCache = paginatedCache.filter { loadedIDs.contains($0.key) }
        let pages = chapters.flatMap { paginatedCache[$0.id] ?? [] }

        let newIndex: Int
        if let restoreAnchor, let index = Self.pageIndex(for: restoreAnchor, in: pages) {
            newIndex = index
            onRestoreAnchorApplied(restoreAnchor)
        } else if let place, let index = Self.pageIndex(for: place, in: pages) {
            newIndex = index
        } else {
            newIndex = min(currentPageIndex, max(0, pages.count - 1))
        }
        flattenedPages = pages
        currentPageIndex = newIndex
        reportPosition(of: pages, at: newIndex)
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

    private func reportPosition(of pages: [NovelPaginationPage], at index: Int) {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        onPositionChanged(page.chapterID, page.startOffset, page.isLastInChapter)
    }
}

// MARK: - UIPageViewController Wrapper

struct PageViewController: UIViewControllerRepresentable {
    let pages: [NovelPaginationPage]
    @Binding var currentPage: Int
    let maxWidth: CGFloat
    /// For image pages' loading and error content.
    let textColor: Color
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

        if let firstVC = context.coordinator.makePageContentVC(index: currentPage) {
            pvc.setViewControllers([firstVC], direction: .forward, animated: false)
        }

        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldPages = coordinator.parent.pages
        coordinator.parent = self

        // Pages added after the existing ones need nothing: the data source serves them. Only
        // changed pages, or a different current page, need the shown page replaced.
        let existingChanged = pages.count < oldPages.count
            || zip(oldPages, pages).contains(where: { $0.0.string !== $0.1.string })
        let shownIndex = (pvc.viewControllers?.first as? PageContentViewController)?.index
        guard existingChanged || shownIndex != currentPage else { return }
        if coordinator.isTransitioning {
            // Replacing pages in the middle of a swipe confuses the page controller.
            coordinator.needsRefresh = true
        } else {
            coordinator.showCurrentPage(in: pvc)
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageViewController
        var isTransitioning = false
        var needsRefresh = false

        init(_ parent: PageViewController) {
            self.parent = parent
        }

        func showCurrentPage(in pvc: UIPageViewController) {
            needsRefresh = false
            let target = min(parent.currentPage, max(0, parent.pages.count - 1))
            if let vc = makePageContentVC(index: target) {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            }
        }

        func makePageContentVC(index: Int) -> PageContentViewController? {
            guard index >= 0 && index < parent.pages.count else { return nil }
            let vc = PageContentViewController()
            vc.index = index
            vc.page = parent.pages[index]
            vc.maxWidth = parent.maxWidth
            vc.foreground = parent.textColor
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController else { return nil }
            return makePageContentVC(index: vc.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController else { return nil }
            return makePageContentVC(index: vc.index + 1)
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
            if completed,
               let vc = pageViewController.viewControllers?.first as? PageContentViewController {
                parent.currentPage = vc.index
                parent.onPageChanged(vc.index)
            }
            if needsRefresh {
                showCurrentPage(in: pageViewController)
            }
        }
    }
}

class PageContentViewController: UIViewController {
    var index: Int = 0
    var page: NovelPaginationPage?
    var maxWidth: CGFloat = 0
    var foreground: Color = .primary

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        if let image = page?.image {
            showImage(image)
            return
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        textView.attributedText = page?.string

        // Disable UITextView's built-in double tap to remove selection conflicts,
        // users can still long-press to select text.
        for recognizer in textView.gestureRecognizers ?? [] {
            if let tapRecognizer = recognizer as? UITapGestureRecognizer, tapRecognizer.numberOfTapsRequired == 2 {
                tapRecognizer.isEnabled = false
            }
        }
    }

    /// An illustration fills the page, loaded the same way as in continuous mode.
    private func showImage(_ image: NovelPageImage) {
        let host = UIHostingController(
            rootView: MangaImage(urlStr: image.url, headers: image.headers, foreground: foreground)
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
