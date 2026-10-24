import SwiftUI
import NukeUI
import Nuke
import ito_runner

// MARK: - ReaderView

struct ReaderView: View {
    @StateObject private var viewModel: MangaReaderViewModel
    @State private var continuousPosition = MangaContinuousScrollPositionCoordinator()
    @State private var showSettings = false
    @State private var showUI = true

    @Environment(\.dismiss) private var dismiss

    /// `viewModel` is evaluated once, when SwiftUI first creates this view's state.
    init(viewModel: @autoclosure @escaping () -> MangaReaderViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())

    }

    var body: some View {
        GeometryReader { geometry in
            readerBody(
                safeAreaBottom: geometry.safeAreaInsets.bottom > 0
                    ? geometry.safeAreaInsets.bottom
                    : 34
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
                )
            )
        }
        .task { viewModel.start() }
        .onAppear { viewModel.appear() }
        .onDisappear { viewModel.disappear() }
    }

    private func readerBody(safeAreaBottom: CGFloat) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.loadPhase {
            case .idle, .loading:
                ProgressView("Loading Chapter...")
                    .foregroundColor(.white)
            case .failure(let error):
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
                }
                .padding(32)
            case .content:
                readComponent
                    // Pages handle their own taps (so a double tap can zoom); this covers
                    // the space around them.
                    .onTapGesture(perform: toggleUI)
                    .ignoresSafeArea()
            }

            if showUI {
                VStack {
                    ReaderHeaderView(
                        title: viewModel.entry.title,
                        chapterTitle: ReaderChapterTitle.text(
                            title: viewModel.currentChapter.title,
                            number: viewModel.currentChapter.chapter
                        ),
                        onDismiss: { dismiss() }
                    )

                    Spacer()

                    ReaderFooterView(
                        displayIndex: viewModel.isPaged
                            ? viewModel.pagedIndex
                            : viewModel.continuousChapterPage.index,
                        displayTotal: viewModel.isPaged
                            ? viewModel.pagedPages.count
                            : viewModel.continuousChapterPage.count,
                        hasPrev: viewModel.chapterBefore(viewModel.currentChapter) != nil,
                        hasNext: viewModel.chapterAfter(viewModel.currentChapter) != nil,
                        overrideViewer: Binding(
                            get: { viewModel.overrideViewer },
                            set: { viewModel.setViewerOverride($0) }
                        ),
                        safeAreaBottom: safeAreaBottom,
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
    }

    // MARK: - Reader components

    @ViewBuilder
    private var readComponent: some View {
        if viewModel.isPaged {
            pagedReader
        } else {
            continuousReader
        }
    }

    // MARK: - Paged Reader (RTL/LTR)

    private var pagedReader: some View {
        TabView(
            selection: Binding(
                get: { viewModel.pagedIndex },
                set: { viewModel.setPagedIndex($0) }
            )
        ) {
            if let previous = viewModel.chapterBefore(viewModel.currentChapter) {
                loadingChapterView(chapter: previous, isNext: false, prompt: .loading)
                    .tag(-1)
            }

            ForEach(Array(viewModel.pagedPages.enumerated()), id: \.offset) { position, page in
                pageImage(for: page, number: position + 1)
                    .tag(position)
            }

            if let next = viewModel.chapterAfter(viewModel.currentChapter) {
                loadingChapterView(chapter: next, isNext: true, prompt: .loading)
                    .tag(viewModel.pagedPages.count)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .id(viewModel.currentChapter.key)
        .environment(
            \.layoutDirection,
            (viewModel.activeViewer == .Rtl || viewModel.activeViewer == .Default)
                ? .rightToLeft
                : .leftToRight
        )
    }

    // MARK: - Continuous Reader (Vertical/Webtoon)

    private var continuousReader: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: viewModel.activeViewer == .Webtoon ? 0 : 8) {
                    if let previous = viewModel.previousChapterForFirstSegment {
                        Button(action: { viewModel.prependPreviousChapter() }) {
                            loadingChapterView(
                                chapter: previous,
                                isNext: false,
                                prompt: viewModel.loadingPrevChapter
                                    ? .loading
                                    : (viewModel.prependFailed ? .failed : .tap)
                            )
                        }
                        .disabled(viewModel.loadingPrevChapter)
                    }

                    ForEach(viewModel.flatPages) { flatPage in
                        VStack(spacing: 0) {
                            if flatPage.chapterPosition == 0 && flatPage.segmentIndex > 0 {
                                chapterDivider(for: flatPage.chapter)
                            }

                            pageImage(for: flatPage.page, number: flatPage.chapterPosition + 1)
                                .background(MangaContinuousPageGeometryReporter(pageID: flatPage.id))
                                .id(flatPage.id)
                        }
                    }

                    if viewModel.loadingNextChapter {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let next = viewModel.nextChapterForLastSegment {
                        if viewModel.appendFailed {
                            Button(action: { viewModel.retryAppendNextChapter() }) {
                                loadingChapterView(chapter: next, isNext: true, prompt: .failed)
                            }
                        } else {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { viewModel.appendNextChapter() }
                        }
                    }
                }
                .coordinateSpace(name: "manga.continuous.content")
                .background { MangaContinuousContentBoundsReporter() }
            }
            .coordinateSpace(name: "manga.continuous.viewport")
            .overlay { MangaContinuousViewportReporter() }
            .onPreferenceChange(MangaContinuousGeometryPreferenceKey.self) { geometry in
                let correction = continuousPosition.update(geometry, viewModel: viewModel)
                if let target = viewModel.scrollTarget {
                    if continuousPosition.isSettled(target) {
                        viewModel.consumeScrollTarget(target)
                    } else if !target.animated, !target.waitsForLayout || correction != nil {
                        let request = correction ?? target
                        proxy.scrollTo(
                            request.pageID,
                            anchor: UnitPoint(x: 0.5, y: request.alignmentY)
                        )
                    }
                } else if let correction {
                    proxy.scrollTo(
                        correction.pageID,
                        anchor: UnitPoint(x: 0.5, y: correction.alignmentY)
                    )
                }
            }
            .onChange(of: viewModel.scrollTarget) { target in
                guard let target else { return }
                // The mutation's preference pass decides whether native anchoring needs help.
                guard !target.waitsForLayout else { return }
                continuousPosition.cancelRestoration()
                if target.animated {
                    withAnimation {
                        proxy.scrollTo(
                            target.pageID,
                            anchor: UnitPoint(x: 0.5, y: target.alignmentY)
                        )
                    }
                    viewModel.consumeScrollTarget(target)
                } else {
                    proxy.scrollTo(
                        target.pageID,
                        anchor: UnitPoint(x: 0.5, y: target.alignmentY)
                    )
                    if continuousPosition.isSettled(target) {
                        viewModel.consumeScrollTarget(target)
                    }
                }
            }
            // A target set before this view existed (a restored page, a mode switch) never
            // changes while it is on screen, so scroll to it once here.
            .onAppear {
                guard let target = viewModel.scrollTarget else { return }
                guard !target.waitsForLayout else { return }
                continuousPosition.cancelRestoration()
                if target.animated {
                    withAnimation {
                        proxy.scrollTo(
                            target.pageID,
                            anchor: UnitPoint(x: 0.5, y: target.alignmentY)
                        )
                    }
                    viewModel.consumeScrollTarget(target)
                } else {
                    proxy.scrollTo(
                        target.pageID,
                        anchor: UnitPoint(x: 0.5, y: target.alignmentY)
                    )
                    if continuousPosition.isSettled(target) {
                        viewModel.consumeScrollTarget(target)
                    }
                }
            }

        }
    }

    // MARK: - Shared views

    private func chapterDivider(for chapter: Manga.Chapter) -> some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 24)

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

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 40)
    }

    private enum ChapterLoadPrompt {
        case tap
        case loading
        case failed
    }

    @ViewBuilder
    private func loadingChapterView(
        chapter: Manga.Chapter,
        isNext: Bool,
        prompt: ChapterLoadPrompt
    ) -> some View {
        VStack(spacing: 16) {
            switch prompt {
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
            Text(Self.promptText(prompt, isNext: isNext))
                .foregroundColor(.white)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(ReaderChapterTitle.text(title: chapter.title, number: chapter.chapter))
                .foregroundColor(.gray)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .center)
        .padding(40)
    }

    private static func promptText(_ prompt: ChapterLoadPrompt, isNext: Bool) -> String {
        switch (prompt, isNext) {
        case (.tap, true): return "Tap to Load Next Chapter"
        case (.tap, false): return "Tap to Load Previous Chapter"
        case (.loading, true): return "Loading Next Chapter..."
        case (.loading, false): return "Loading Previous Chapter..."
        case (.failed, true): return "Couldn't load the next chapter. Tap to try again."
        case (.failed, false): return "Couldn't load the previous chapter. Tap to try again."
        }
    }

    /// `number` is the page's place in its chapter, read out for image pages; text pages read
    /// their own text.
    @ViewBuilder
    private func pageImage(for page: Page, number: Int) -> some View {
        switch page.content {
        case .url(let urlString):
            MangaImage(
                urlStr: urlString,
                headers: page.headers,
                onImageTap: toggleUI,
                imageLabel: "Page \(number)"
            )
        case .text(let text):
            Text(text)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .center)
        }
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
                            Text(option == .none ? "Off" : "\(option.rawValue) images")
                                .tag(option.rawValue)
                        }
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
            ? "Automatic reads right to left, since this series does not specify a mode."
            : "Automatic uses this series' mode: \(Self.modeName(defaultViewer))."
    }

    static let modes: [Manga.Viewer] = [.Default, .Rtl, .Ltr, .Vertical, .Webtoon]

    static func modeName(_ mode: Manga.Viewer) -> String {
        switch mode {
        case .Default: return "Automatic"
        case .Rtl: return "Right to Left"
        case .Ltr: return "Left to Right"
        case .Vertical: return "Vertical"
        case .Webtoon: return "Webtoon"
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
                label: isRightToLeft ? "Next Chapter" : "Previous Chapter",
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
                    label: isRightToLeft ? "Next Page" : "Previous Page",
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
                    label: isRightToLeft ? "Previous Page" : "Next Page",
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
                label: isRightToLeft ? "Previous Chapter" : "Next Chapter",
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

// MARK: - Manga Image Loader

struct MangaImage: View {
    let urlStr: String
    let headers: [String: String]?
    /// Colour of the loading, error and placeholder content: white on the manga reader's black,
    /// the reading theme's text colour in the novel reader.
    var foreground: Color = .white
    /// When set, the loaded image can be pinched and double-tapped to zoom, and a single tap
    /// calls this. Loading and error states are never zoomable, so Try Again stays tappable.
    var onImageTap: (() -> Void)?
    /// What VoiceOver reads for the loaded image.
    var imageLabel = "Illustration"

    /// Bumped by Try Again so `LazyImage` starts a fresh request.
    @State private var attempt = 0

    var body: some View {
        if let url = URL(string: urlStr) {
            LazyImage(request: ImageRequest(urlRequest: createRequest(url: url))) { state in
                if let image = state.image {
                    loadedImage(image)
                } else if state.error != nil {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(foreground.opacity(0.7))
                            .font(.largeTitle)
                        Text("Couldn't load this page")
                            .font(.subheadline)
                            .foregroundColor(foreground.opacity(0.8))
                        Button("Try Again") { attempt += 1 }
                            .buttonStyle(.bordered)
                            .tint(foreground)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
                    .padding(40)
                } else {
                    ProgressView()
                        .tint(foreground)
                        .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
                        .padding(40)
                }
            }
            .id(attempt)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .foregroundColor(foreground.opacity(0.5))
                    .font(.largeTitle)
                Text("This page has no valid image address")
                    .font(.subheadline)
                    .foregroundColor(foreground.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
            .padding(40)
        }
    }

    @ViewBuilder
    private func loadedImage(_ image: Image) -> some View {
        if let onImageTap {
            ZoomablePage(onTap: onImageTap) {
                image.resizable().scaledToFit()
            }
            .accessibilityLabel(imageLabel)
        } else {
            image
                .resizable()
                .scaledToFit()
                .accessibilityLabel(imageLabel)
        }
    }

    func createRequest(url: URL) -> URLRequest {
        NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: headers)
    }
}
