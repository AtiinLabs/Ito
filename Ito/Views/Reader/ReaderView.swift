import SwiftUI
import ito_runner

// MARK: - ReaderView

struct ReaderView: View {
    @ObservedObject private var viewModel: MangaReaderViewModel
    /// The route is asking, preparing or laying out a handoff; the pager's notice then reads as loading.
    let isHandoffBusy: Bool
    let onPresentationReady: (UUID, UUID) -> Void
    let onInitialImageVisibleLeaseAcquired: (UUID, UUID) -> Void
    let signIn: PluginSignInSheets
    @State private var showSettings = false
    @State private var showUI = true
    @State private var showSignIn = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The route owns the reader; this view only draws it and reports what the route asked to be told.
    init(
        viewModel: MangaReaderViewModel,
        isHandoffBusy: Bool,
        onPresentationReady: @escaping (UUID, UUID) -> Void,
        onInitialImageVisibleLeaseAcquired: @escaping (UUID, UUID) -> Void,
        signIn: PluginSignInSheets
    ) {
        self.viewModel = viewModel
        self.isHandoffBusy = isHandoffBusy
        self.onPresentationReady = onPresentationReady
        self.onInitialImageVisibleLeaseAcquired = onInitialImageVisibleLeaseAcquired
        self.signIn = signIn
    }

    var body: some View {
        GeometryReader { geometry in
            readerBody(
                safeArea: geometry.safeAreaInsets,
                showsSpread: NovelReaderLayout.showsSpread(
                    windowSize: geometry.size,
                    verticallyRegular: verticalSizeClass == .regular
                )
            )
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showUI)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(
                viewer: Binding(
                    get: { viewModel.overrideViewer },
                    set: { viewModel.setViewerOverride($0) }
                ),
                defaultViewer: viewModel.defaultViewer,
                preloadCount: Binding(
                    get: { viewModel.preloadImageCount },
                    set: { viewModel.setPreloadImageCount($0) }
                ),
                askBeforeSwitchingGroups: Binding(
                    get: { viewModel.askBeforeSwitchingGroups },
                    set: { viewModel.setAskBeforeSwitchingGroups($0) }
                )
            )
        }
        .sheet(isPresented: $showSignIn, onDismiss: { viewModel.retry() }) {
            if let target = signIn.target(pluginID: viewModel.pluginID) {
                signIn.sheet(for: target)
            }
        }
        .task { viewModel.start() }
        .onAppear { viewModel.appear() }
        .onDisappear { viewModel.disappear() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { viewModel.cancelGroupSwitch() }
        }
        .alert(
            String(localized: "Switch groups?", comment: "Reader consent title: open one exact upload from another translation group"),
            // The buttons decide: a setter that cancelled could run before Continue's action.
            isPresented: Binding(get: { viewModel.groupSwitchConsent != nil }, set: { _ in }),
            presenting: viewModel.groupSwitchConsent
        ) { consent in
            Button(String(localized: "Open This Upload", comment: "Reader consent alert button: opens the one upload from another translation group, for this reading only")) { viewModel.confirmGroupSwitch(consent.id) }
            Button("Cancel", role: .cancel) { viewModel.cancelGroupSwitch() }
        } message: { consent in
            Text(consent.message)
        }
    }

    private func readerBody(safeArea: EdgeInsets, showsSpread: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.loadPhase {
            case .idle, .loading:
                ProgressView("Loading Chapter...")
                    .foregroundColor(.white)
            case .failure(let error, let needsSignIn):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.7))
                    Text("Couldn't load this chapter")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button("Try Again") { viewModel.retry() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.top, 4)
                    if needsSignIn, signIn.target(pluginID: viewModel.pluginID) != nil {
                        Button("Sign In") { showSignIn = true }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                    if viewModel.canReadDownloadedCopy {
                        Button {
                            viewModel.readDownloadedCopy()
                        } label: {
                            Text("Read Downloaded Copy",
                                 comment: "Reader error: reopen this chapter from its saved copy after reading it online failed")
                        }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                }
                .padding(32)
            case .content:
                readComponent()
                    .ignoresSafeArea()
            }

            if showUI {
                VStack {
                    ReaderHeaderView(
                        title: viewModel.entry.title,
                        chapterTitle: ReaderChapterTitle.text(
                            title: viewModel.currentChapter.title,
                            number: viewModel.currentChapter.chapterNumber
                        ),
                        onDismiss: { dismiss() }
                    )

                    Spacer()

                    ReaderFooterView(
                        displayIndex: viewModel.isPaged
                            ? viewModel.pagedDisplayIndex
                            : viewModel.continuousChapterPage.index,
                        displayTotal: viewModel.isPaged
                            ? viewModel.pagedPages.count
                            : viewModel.continuousChapterPage.count,
                        hasPrev: viewModel.boundaryBefore(viewModel.currentChapter).canNavigate,
                        hasNext: viewModel.boundaryAfter(viewModel.currentChapter).canNavigate,
                        overrideViewer: Binding(
                            get: { viewModel.overrideViewer },
                            set: { viewModel.setViewerOverride($0) }
                        ),
                        safeAreaBottom: safeArea.bottom > 0 ? safeArea.bottom : 34,
                        // Paged right-to-left turns pages leftwards; the footer follows.
                        isRightToLeft: viewModel.isPaged
                            && (viewModel.activeViewer == .Rtl || viewModel.activeViewer == .Default),
                        onPrevChapter: { viewModel.goToPreviousChapter() },
                        onNextChapter: { viewModel.goToNextChapter() },
                        onPrevPage: { viewModel.previousPage() },
                        onNextPage: { viewModel.nextPage() },
                        onSettings: { showSettings.toggle() }
                    )
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .onAppear { viewModel.setPagedSpreadLayout(showsSpread) }
        .onChange(of: showsSpread) { viewModel.setPagedSpreadLayout($0) }
    }

    // MARK: - Reader components

    @ViewBuilder
    private func readComponent() -> some View {
        if viewModel.isPaged {
            pagedReader()
        } else {
            continuousReader
        }
    }

    // MARK: - Paged Reader (RTL/LTR)

    /// Each page view owns its tap: a SwiftUI tap around a page's UIKit zoom view would also
    /// fire for the taps the page already handles, toggling the controls twice.
    private func pagedReader() -> some View {
        let chapter = viewModel.currentChapter
        let pages = viewModel.pagedPages
        let spreads = viewModel.pagedSpreads
        let previous = viewModel.boundaryBefore(chapter)
        let next = viewModel.boundaryAfter(chapter)
        let isRightToLeft = viewModel.activeViewer == .Rtl || viewModel.activeViewer == .Default
        return MangaPagedReaderView(
            chapterKey: chapter.key,
            pageCount: spreads.count,
            hasPrevious: !previous.isEnd,
            hasNext: !next.isEnd,
            index: viewModel.pagedSpreadPosition,
            isRightToLeft: isRightToLeft,
            content: { position in
                // Pages keep a left-to-right layout: the reading direction only orders them, and
                // a right-to-left environment would mirror the page's UIKit zoom view.
                pagedPosition(
                    position,
                    chapter: chapter,
                    pages: pages,
                    spreads: spreads,
                    isRightToLeft: isRightToLeft,
                    previous: previous,
                    next: next
                )
            },
            onIndexChange: { viewModel.setPagedSpreadPosition($0) }
        )
    }

    /// A pager position: the previous chapter's loading page (-1) or where reading stops before it, a
    /// spread of pages, or the same for the next chapter.
    @ViewBuilder
    private func pagedPosition(
        _ position: Int,
        chapter: Manga.Chapter,
        pages: [Page],
        spreads: [Range<Int>],
        isRightToLeft: Bool,
        previous: ReaderChapterBoundary<Manga.Chapter>,
        next: ReaderChapterBoundary<Manga.Chapter>
    ) -> some View {
        if position < 0 {
            neighborView(previous, isNext: false)
        } else if spreads.indices.contains(position) {
            pagedSpread(
                spreads[position],
                chapter: chapter,
                pages: pages,
                isRightToLeft: isRightToLeft
            )
        } else {
            neighborView(next, isNext: true)
        }
    }

    /// One pager position: a spread when the spread layout is on, its pages side by side in reading
    /// order, centered in the space the pager gives this view; otherwise the position's single page.
    @ViewBuilder
    private func pagedSpread(
        _ range: Range<Int>,
        chapter: Manga.Chapter,
        pages: [Page],
        isRightToLeft: Bool
    ) -> some View {
        if viewModel.pagedSpreadLayout {
            let positions = MangaSpreadLayout.order(range, isRightToLeft: isRightToLeft)
            let aspects = positions.map { MangaSpreadLayout.aspect(viewModel.pagedPixelAspect(at: $0)) }
            GeometryReader { geometry in
                // Each page gets an explicit x, so the order on screen does not depend on the layout
                // direction the spread is hosted in. The block is centered in the space this view is given.
                let frames = MangaSpreadLayout.frames(aspects: aspects, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(positions.enumerated()), id: \.offset) { offset, position in
                        pageImage(
                            for: pages[position],
                            number: position + 1,
                            pageID: FlatPage.id(chapterKey: chapter.key, position: position)
                        )
                        .frame(width: frames[offset].width, height: frames[offset].height)
                        .offset(x: frames[offset].minX, y: frames[offset].minY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .environment(\.layoutDirection, .leftToRight)
        } else {
            pageImage(
                for: pages[range.lowerBound],
                number: range.lowerBound + 1,
                pageID: FlatPage.id(chapterKey: chapter.key, position: range.lowerBound)
            )
        }
    }

    @ViewBuilder
    private func neighborView(_ boundary: ReaderChapterBoundary<Manga.Chapter>, isNext: Bool) -> some View {
        if boundary.isHandoff, isHandoffBusy, let chapter = boundary.candidate {
            // The route is preparing it: the pager rests on its loading page, as for a chapter of this reader.
            loadingChapterView(chapter: chapter, isNext: isNext)
        } else if let notice = ReaderBoundaryNotice.pages(for: boundary, isNext: isNext) {
            boundaryNoticeView(notice, chapter: boundary.candidate, isNext: isNext)
        } else if let chapter = boundary.chapter {
            loadingChapterView(chapter: chapter, isNext: isNext)
        }
    }

    // MARK: - Continuous Reader (Vertical/Webtoon)

    /// Handles every tap itself: a SwiftUI tap gesture around a UIKit view would also fire for
    /// taps the pages already handle.
    private var continuousReader: some View {
        MangaContinuousReaderView(
            viewModel: viewModel,
            onToggleUI: toggleUI,
            onInitialLayout: reportInitialContinuousLayout,
            onImageVisibleLease: reportRendererImageLease
        )
    }

    /// The continuous renderer applied the destination's first position.
    private func reportInitialContinuousLayout() {
        guard case .staged(let requestID, let visitID) = viewModel.presentationMode else { return }
        onPresentationReady(requestID, visitID)
    }

    // MARK: - Shared views

    private func boundaryNoticeView(_ notice: ReaderBoundaryNotice, chapter: Manga.Chapter?, isNext: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: notice.systemImage)
                .font(.system(size: 40))
                .foregroundColor(.white)
                .accessibilityHidden(true)
            Text(notice.text)
                .foregroundColor(.white)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let chapter {
                Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber))
                    .foregroundColor(.gray)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .center)
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(notice.requestsGroupConsent || notice.requestsHandoff ? .isButton : [])
        .contentShape(Rectangle())
        .onTapGesture {
            if notice.requestsHandoff {
                // The tap on the notice the pager rests on is the paged edge itself, and a deliberate tap
                // asks again after a cancelled or failed attempt, which the latch would otherwise swallow.
                viewModel.releaseHandoffLatch()
                viewModel.requestHandoff(
                    direction: isNext ? .next : .previous,
                    position: isNext ? .start : .end,
                    trigger: .pagedEdge,
                    atLoadedEdge: false
                )
            } else if notice.requestsGroupConsent {
                viewModel.requestGroupSwitch(isNext ? .next : .previous, opensAtEnd: !isNext)
            } else {
                toggleUI()
            }
        }
    }

    private func loadingChapterView(chapter: Manga.Chapter, isNext: Bool) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white)
            Text(isNext ? "Loading Next Chapter..." : "Loading Previous Chapter...")
                .foregroundColor(.white)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber))
                .foregroundColor(.gray)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .center)
        .padding(40)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleUI)
    }

    /// `number` is the page's place in its chapter, read out for image pages; text pages read
    /// their own text.
    @ViewBuilder
    private func pageImage(for page: Page, number: Int, pageID: String) -> some View {
        switch page.content {
        case .url(let urlString):
            MangaImage(
                urlStr: urlString,
                headers: page.headers,
                session: viewModel.imageSession,
                pageID: pageID,
                interaction: .pagedZoom(onTap: toggleUI),
                imageLabel: String(localized: "Page \(number)", comment: "Accessibility label of a manga page; number is its position in the chapter"),
                onVisibleLeaseAcquired: { key in reportInitialImage(key, position: number - 1) },
                onPixelSize: { viewModel.setPagedPixelSize($0, pageID: pageID) }
            )
        case .text(let text):
            Text(text)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleUI)
                .onAppear { reportInitialLayout(position: number - 1) }
        }
    }

    /// A destination built behind the visible reader reports that its first page is on screen.
    private func reportInitialLayout(position: Int) {
        guard case .staged(let requestID, let visitID) = viewModel.presentationMode,
              viewModel.pagedPageIsShown(position) else { return }
        onPresentationReady(requestID, visitID)
    }

    /// The first image holds a lease of this renderer now, which is when the route's own lease can go.
    private func reportInitialImage(_ key: ReaderPageImageKey, position: Int) {
        reportRendererImageLease(key)
        reportInitialLayout(position: position)
    }

    /// This renderer holds a visible lease on the image `key`; if it is the first image the route proved, the
    /// route's own lease can go once that image is ready.
    private func reportRendererImageLease(_ key: ReaderPageImageKey) {
        guard let requestID = viewModel.arrivalRequestID, key == viewModel.preparedImageKey else { return }
        onInitialImageVisibleLeaseAcquired(requestID, viewModel.routeVisitID)
    }

    private func toggleUI() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showUI.toggle()
        }
    }
}
// MARK: - Reader Settings

struct ReaderSettingsView: View {
    @Binding var viewer: Manga.Viewer
    let defaultViewer: Manga.Viewer
    @Binding var preloadCount: Int
    @Binding var askBeforeSwitchingGroups: Bool

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Reading Mode")) {
                    Picker("Mode", selection: $viewer) {
                        ForEach(Self.modes, id: \.self) { mode in
                            Text(Self.modeName(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section(
                    header: Text("Preloading"),
                    footer: Text("Number of images ahead of your current position to preload. Higher values use more data but reduce loading times.")
                ) {
                    Picker("Preload Images", selection: $preloadCount) {
                        ForEach(ImagePreloadCountPreference.allCases, id: \.self) { option in
                            Text(option.localizedTitle)
                                .tag(option.rawValue)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $askBeforeSwitchingGroups) {
                        Text("Ask before switching groups",
                             comment: "Reader setting, off by default: require confirmation before Next, Previous or Resume opens another translation group's upload")
                    }
                }

                Section(footer: Text(automaticModeDescription)) {}
            }
            .navigationTitle("Reader Settings")
            .navigationBarItems(
                trailing: Button("Done") { dismiss() }
            )
        }
    }

    /// What Automatic means for this series.
    private var automaticModeDescription: String {
        defaultViewer == .Default
            ? String(localized: "Automatic reads right to left, since this series does not specify a mode.")
            : String(localized: "Automatic uses this series' mode: \(Self.modeName(defaultViewer)).")
    }

    static let modes: [Manga.Viewer] = [.Default, .Rtl, .Ltr, .Vertical, .Webtoon]

    static func modeName(_ mode: Manga.Viewer) -> String {
        switch mode {
        case .Default: return String(localized: "Automatic", comment: "Reading mode: follow the series' default direction")
        case .Rtl: return String(localized: "Right to Left", comment: "Reading mode")
        case .Ltr: return String(localized: "Left to Right", comment: "Reading mode")
        case .Vertical: return String(localized: "Vertical", comment: "Reading mode")
        case .Webtoon: return String(localized: "Webtoon", comment: "Reading mode")
        }
    }
}

// MARK: - Reader HUD Components

private struct ReaderHeaderView: View {
    let title: String
    let chapterTitle: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(chapterTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityLabel("Close Reader")
        }
        .padding(.horizontal)
        // The header's container already keeps clear of the top safe area.
        .padding(.top, 8)
    }
}

private struct ReaderFooterView: View {
    let displayIndex: Int
    let displayTotal: Int
    let hasPrev: Bool
    let hasNext: Bool
    @Binding var overrideViewer: Manga.Viewer
    let safeAreaBottom: CGFloat
    let isRightToLeft: Bool

    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onSettings: () -> Void

    private var canGoBack: Bool { displayIndex > 0 }
    private var canGoForward: Bool { displayIndex < displayTotal - 1 }

    var body: some View {
        HStack {
            chapterButton(
                systemName: "backward.end.fill",
                label: isRightToLeft ? String(localized: "Next Chapter") : String(localized: "Previous Chapter"),
                isAvailable: isRightToLeft ? hasNext : hasPrev,
                action: isRightToLeft ? onNextChapter : onPrevChapter
            )

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Reader Settings")

            Spacer()

            HStack(spacing: 24) {
                pageButton(
                    systemName: "chevron.left",
                    label: isRightToLeft ? String(localized: "Next Page") : String(localized: "Previous Page"),
                    isEnabled: isRightToLeft ? canGoForward : canGoBack,
                    action: isRightToLeft ? onNextPage : onPrevPage
                )

                Text("\(displayTotal == 0 ? 0 : displayIndex + 1) / \(displayTotal)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundColor(.white)
                    .frame(minWidth: 60, alignment: .center)
                    .accessibilityLabel(
                        "Page \(displayTotal == 0 ? 0 : displayIndex + 1) of \(displayTotal)"
                    )

                pageButton(
                    systemName: "chevron.right",
                    label: isRightToLeft ? String(localized: "Previous Page") : String(localized: "Next Page"),
                    isEnabled: isRightToLeft ? canGoBack : canGoForward,
                    action: isRightToLeft ? onPrevPage : onNextPage
                )
            }

            Spacer()

            Menu {
                Picker("Reading Mode", selection: $overrideViewer) {
                    ForEach(ReaderSettingsView.modes, id: \.self) { mode in
                        Text(ReaderSettingsView.modeName(mode)).tag(mode)
                    }
                }
            } label: {
                Image(systemName: "book.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Reading Mode")

            Spacer()

            chapterButton(
                systemName: "forward.end.fill",
                label: isRightToLeft ? String(localized: "Previous Chapter") : String(localized: "Next Chapter"),
                isAvailable: isRightToLeft ? hasPrev : hasNext,
                action: isRightToLeft ? onPrevChapter : onNextChapter
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 20)
        .padding(.bottom, safeAreaBottom)
    }

    @ViewBuilder
    private func chapterButton(
        systemName: String,
        label: String,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isAvailable {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel(label)
        } else {
            Color.clear
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    private func pageButton(
        systemName: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.bold))
                .foregroundColor(isEnabled ? .white : .white.opacity(0.3))
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
