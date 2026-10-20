import SwiftUI
import ito_runner

struct NovelReaderView: View {
    @StateObject private var viewModel: NovelReaderViewModel
    @State private var showUI = true
    @State private var showSettings = false

    @Environment(\.dismiss) private var dismiss

    /// `viewModel` is evaluated once, when SwiftUI first creates this view's state.
    init(viewModel: @autoclosure @escaping () -> NovelReaderViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        GeometryReader { geometry in
            readerBody(
                safeAreaTop: geometry.safeAreaInsets.top > 0
                    ? geometry.safeAreaInsets.top
                    : 44,
                safeAreaBottom: geometry.safeAreaInsets.bottom > 0
                    ? geometry.safeAreaInsets.bottom
                    : 34
            )
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showUI)
        .task { viewModel.start() }
        .onAppear { viewModel.appear() }
        .onDisappear { viewModel.disappear() }
    }

    private func readerBody(
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        ZStack {
            viewModel.theme.backgroundColor.edgesIgnoringSafeArea(.all)

            switch viewModel.loadPhase {
            case .idle, .loading:
                VStack {
                    ProgressView("Loading Chapter...")
                }
            case .failure(let error):
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.largeTitle)
                    Text("Failed to load chapter")
                        .font(.headline)
                        .padding(.top)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Try Again") { viewModel.retry() }
                        .padding()
                }
            case .content:
                readerContent(safeAreaBottom: safeAreaBottom)
            }

            if showUI {
                VStack {
                    NovelReaderHeaderView(
                        title: viewModel.novel.title,
                        chapterTitle: chapterTitle(viewModel.currentChapter),
                        safeAreaTop: safeAreaTop,
                        onDismiss: { dismiss() }
                    )

                    Spacer()

                    NovelReaderFooterView(
                        hasPrev: viewModel.previousChapter != nil,
                        hasNext: viewModel.nextChapter != nil,
                        safeAreaBottom: safeAreaBottom,
                        onPrevChapter: { viewModel.goToPreviousChapter() },
                        onNextChapter: { viewModel.goToNextChapter() },
                        onSettings: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSettings = true
                            }
                        }
                    )
                }
                .transition(.opacity)
                .ignoresSafeArea(edges: .bottom)
            }

            if showSettings {
                settingsOverlay(safeAreaBottom: safeAreaBottom)
            }
        }
    }

    @ViewBuilder
    private func readerContent(safeAreaBottom: CGFloat) -> some View {
        if viewModel.isPaging {
            NovelPagingReaderView(
                loadedChapters: viewModel.loadedChapters,
                fontSize: viewModel.fontSize,
                fontFamily: viewModel.fontFamily,
                lineSpacing: viewModel.lineSpacing,
                theme: viewModel.theme,
                prefetchChapters: viewModel.prefetchChapters,
                onLoadNextChapter: { viewModel.loadNextChapter() },
                currentChapter: Binding(
                    get: { viewModel.currentChapter },
                    set: { viewModel.pagedChapterChanged($0) }
                ),
                restoreAnchor: viewModel.restoreAnchor,
                onRestoreAnchorApplied: { viewModel.consumeRestoreAnchor($0) },
                onPositionChanged: { chapterID, offset, isLast in
                    viewModel.readingPositionChanged(
                        chapterID: chapterID,
                        offset: offset,
                        reachedEnd: isLast
                    )
                }
            )
            .simultaneousGesture(toggleUIGesture)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CGFloat(viewModel.lineSpacing)) {
                        ForEach(viewModel.loadedChapters) { loadedChapter in
                            Text(chapterTitle(loadedChapter.chapter))
                                .font(
                                    viewModel.fontFamily.swiftUIFont(
                                        size: CGFloat(viewModel.fontSize) + 6,
                                        weight: .bold
                                    )
                                )
                                .foregroundColor(viewModel.theme.textColor)
                                .padding(.vertical)
                                .padding(.horizontal)
                                .onAppear {
                                    viewModel.continuousChapterTitleAppeared(loadedChapter)
                                }

                            ForEach(Array(loadedChapter.pages.enumerated()), id: \.offset) { index, page in
                                pageText(for: page)
                                    .id(blockID(loadedChapter.id, index))
                                    .onAppear {
                                        viewModel.continuousPageAppeared(
                                            chapterID: loadedChapter.id,
                                            pageIndex: index
                                        )
                                    }
                            }

                            // Only scrolls into view at the end of the chapter's text.
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    viewModel.continuousChapterEndAppeared(chapterID: loadedChapter.id)
                                }
                        }

                        endOfListRow

                        Color.clear.frame(height: safeAreaBottom + 80)
                    }
                }
                .onAppear { applyRestoreAnchor(with: proxy) }
                .onChange(of: viewModel.restoreAnchor) { _ in applyRestoreAnchor(with: proxy) }
            }
            .simultaneousGesture(toggleUIGesture)
        }
    }

    /// After the last loaded chapter: loading, a failed load to retry, or (with Seamless
    /// Reading off) a button that adds the next chapter below.
    @ViewBuilder
    private var endOfListRow: some View {
        if viewModel.isLoadingNext {
            ProgressView()
                .tint(viewModel.theme.textColor)
                .frame(maxWidth: .infinity)
                .padding()
        } else if let last = viewModel.loadedChapters.last,
                  let next = viewModel.chapterAfter(last.chapter) {
            if viewModel.appendFailed {
                VStack(spacing: 8) {
                    Text("Couldn't load the next chapter")
                        .font(.subheadline)
                        .foregroundColor(viewModel.theme.textColor)
                    Button("Try Again") { viewModel.retryNextChapter() }
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if !viewModel.prefetchChapters {
                Button(action: { viewModel.loadNextChapter() }) {
                    VStack(spacing: 4) {
                        Text("Next Chapter")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                        Text(chapterTitle(next))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(viewModel.theme.textColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
        }
    }

    private func blockID(_ chapterID: UUID, _ index: Int) -> String {
        "\(chapterID.uuidString)#\(index)"
    }

    private func applyRestoreAnchor(with proxy: ScrollViewProxy) {
        guard let anchor = viewModel.restoreAnchor,
              let loaded = viewModel.loadedChapters.first(where: { $0.id == anchor.chapterID })
        else { return }
        let block = NovelTextOffsets.blockIndex(containing: anchor.offset, in: loaded.pages)
        proxy.scrollTo(blockID(anchor.chapterID, block), anchor: .top)
        viewModel.consumeRestoreAnchor(anchor)
    }

    private var toggleUIGesture: some Gesture {
        TapGesture().onEnded {
            withAnimation(.easeInOut(duration: 0.2)) {
                showUI.toggle()
            }
        }
    }

    private func settingsOverlay(safeAreaBottom: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSettings = false
                    }
                }
                .transition(.opacity)
                .zIndex(10)

            VStack(spacing: 0) {
                Spacer()

                NovelReaderSettingsView(
                    fontSize: Binding(
                        get: { viewModel.fontSize },
                        set: { viewModel.setFontSize($0) }
                    ),
                    lineSpacing: Binding(
                        get: { viewModel.lineSpacing },
                        set: { viewModel.setLineSpacing($0) }
                    ),
                    fontFamily: Binding(
                        get: { viewModel.fontFamily },
                        set: { viewModel.setFontFamily($0) }
                    ),
                    theme: Binding(
                        get: { viewModel.theme },
                        set: { viewModel.setTheme($0) }
                    ),
                    isPaging: Binding(
                        get: { viewModel.isPaging },
                        set: { viewModel.setIsPaging($0) }
                    ),
                    prefetchChapters: Binding(
                        get: { viewModel.prefetchChapters },
                        set: { viewModel.setPrefetchChapters($0) }
                    )
                )
                .frame(height: 280)
                .padding(.bottom, safeAreaBottom)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(24)
                .environment(\.colorScheme, .dark)
            }
            .edgesIgnoringSafeArea(.bottom)
            .transition(.move(edge: .bottom))
            .zIndex(11)
        }
    }

    @ViewBuilder
    private func pageText(for page: Page) -> some View {
        switch page.content {
        case .text(let text):
            SelectableTextView(
                text: text,
                font: viewModel.fontFamily.uiFont(size: CGFloat(viewModel.fontSize)),
                textColor: UIColor(viewModel.theme.textColor)
            )
            .padding(.horizontal)
            .padding(.vertical, 4)
        case .url(let urlString):
            MangaImage(urlStr: urlString, headers: page.headers)
                .padding(.horizontal)
        }
    }

    private func chapterTitle(_ chapter: Novel.Chapter) -> String {
        if let number = chapter.chapter {
            if let title = chapter.title, !title.isEmpty {
                return "Chapter \(number.formatted()) - \(title)"
            }
            return "Chapter \(number.formatted())"
        }
        return chapter.title ?? "Unknown Chapter"
    }
}

// MARK: - Novel Reader HUD Components

private struct NovelReaderHeaderView: View {
    let title: String
    let chapterTitle: String
    let safeAreaTop: CGFloat
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
        }
        .padding(.horizontal)
        .padding(.top, safeAreaTop)
    }
}

private struct NovelReaderFooterView: View {
    let hasPrev: Bool
    let hasNext: Bool
    let safeAreaBottom: CGFloat

    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack {
            if hasPrev {
                Button(action: onPrevChapter) {
                    Image(systemName: "backward.end.fill")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            if hasNext {
                Button(action: onNextChapter) {
                    Image(systemName: "forward.end.fill")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 20)
        .padding(.bottom, safeAreaBottom > 0 ? safeAreaBottom : 16)
    }
}

// MARK: - Novel Reader Settings Models & View

enum NovelTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case white = "White"
    case cream = "Cream"
    case mint = "Mint"
    case sepia = "Sepia"
    case dark = "Dark"
    var id: String { rawValue }

    var backgroundColor: Color {
        switch self {
        case .system: return Color(UIColor.systemBackground)
        case .white: return Color.white
        case .cream: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .mint: return Color(red: 0.88, green: 0.93, blue: 0.93)
        case .sepia: return Color(red: 0.85, green: 0.77, blue: 0.68)
        case .dark: return Color(white: 0.1)
        }
    }

    var textColor: Color {
        switch self {
        case .system: return Color.primary
        case .white: return Color.black
        case .cream: return Color(red: 0.2, green: 0.2, blue: 0.2)
        case .mint: return Color(red: 0.15, green: 0.2, blue: 0.25)
        case .sepia: return Color(red: 0.27, green: 0.20, blue: 0.13)
        case .dark: return Color(white: 0.85)
        }
    }
}

enum SettingsTab {
    case typography
    case theme
    case reading
}

enum NovelFont: String, CaseIterable, Identifiable {
    case system = "System"
    case serif = "Serif"
    case monospaced = "Monospace"
    case rounded = "Rounded"
    case lora = "Lora"
    case karla = "Karla"
    case rubik = "Rubik"
    case cardo = "Cardo"
    case nunito = "Nunito"
    case merriweather = "Merriweather"

    var id: String { rawValue }

    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system: return .system(size: size, weight: weight, design: .default)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .lora: return .custom(weight == .bold ? "Lora-Bold" : "Lora-Regular", size: size)
        case .karla: return .custom(weight == .bold ? "Karla-Bold" : "Karla-Regular", size: size)
        case .rubik: return .custom(weight == .bold ? "Rubik-Bold" : "Rubik-Regular", size: size)
        case .cardo: return .custom(weight == .bold ? "Cardo-Bold" : "Cardo-Regular", size: size)
        case .nunito: return .custom(weight == .bold ? "Nunito-Bold" : "Nunito-Regular", size: size)
        case .merriweather: return .custom(weight == .bold ? "Merriweather-Bold" : "Merriweather-Regular", size: size)
        }
    }

    nonisolated func uiFont(size: CGFloat, isBold: Bool = false) -> UIFont {
        let fallback = isBold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        switch self {
        case .system, .rounded: return fallback
        case .serif: return UIFont(name: isBold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: size) ?? fallback
        case .monospaced: return UIFont(name: isBold ? "Menlo-Bold" : "Menlo", size: size) ?? fallback
        case .lora: return UIFont(name: isBold ? "Lora-Bold" : "Lora-Regular", size: size) ?? fallback
        case .karla: return UIFont(name: isBold ? "Karla-Bold" : "Karla-Regular", size: size) ?? fallback
        case .rubik: return UIFont(name: isBold ? "Rubik-Bold" : "Rubik-Regular", size: size) ?? fallback
        case .cardo: return UIFont(name: isBold ? "Cardo-Bold" : "Cardo-Regular", size: size) ?? fallback
        case .nunito: return UIFont(name: isBold ? "Nunito-Bold" : "Nunito-Regular", size: size) ?? fallback
        case .merriweather: return UIFont(name: isBold ? "Merriweather-Bold" : "Merriweather-Regular", size: size) ?? fallback
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor

    class SelfSizingTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            let size = sizeThatFits(CGSize(width: bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width, height: .greatestFiniteMagnitude))
            return size
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != intrinsicContentSize {
                invalidateIntrinsicContentSize()
            }
        }
    }

    func makeUIView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Disable UITextView's built-in double tap to remove selection conflicts,
        // users can still long-press to select text.
        for recognizer in textView.gestureRecognizers ?? [] {
            if let tapRecognizer = recognizer as? UITapGestureRecognizer, tapRecognizer.numberOfTapsRequired == 2 {
                tapRecognizer.isEnabled = false
            }
        }

        return textView
    }

    func updateUIView(_ uiView: SelfSizingTextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        if uiView.font != font { uiView.font = font }
        if uiView.textColor != textColor { uiView.textColor = textColor }
        uiView.invalidateIntrinsicContentSize()
    }
}

struct NovelReaderSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var fontFamily: NovelFont
    @Binding var theme: NovelTheme
    @Binding var isPaging: Bool
    @Binding var prefetchChapters: Bool

    @State private var activeTab: SettingsTab = .typography
    @State private var brightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        VStack(spacing: 20) {
            // Drag Handle
            Capsule()
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 40, height: 5)
                .padding(.top, 12)

            // Core Controls
            VStack {
                if activeTab == .typography {
                    typographyTab
                } else if activeTab == .theme {
                    themeTab
                } else {
                    readingTab
                }
            }
            .frame(height: 170, alignment: .top)

            // Bottom Toolbar (Footer)
            HStack {
                Spacer()

                Button(action: { activeTab = .typography }) {
                    Image(systemName: "textformat")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .typography ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()

                Button(action: { activeTab = .theme }) {
                    Image(systemName: "sun.max.fill")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .theme ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()

                Button(action: { activeTab = .reading }) {
                    Image(systemName: "book.fill")
                        .font(.title2)
                        .frame(width: 60, height: 44)
                        .foregroundColor(activeTab == .reading ? .primary : Color(UIColor.tertiaryLabel))
                }

                Spacer()
            }
            .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemBackground))
    }

    private var typographyTab: some View {
        HStack(spacing: 16) {
            // Left Column: Font Size Stepper
            VStack(spacing: 0) {
                Button(action: { fontSize += 2 }) {
                    Text("A⁺")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.secondarySystemBackground))
                }

                Divider()

                Button(action: { if fontSize > 10 { fontSize -= 2 } }) {
                    Text("A⁻")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.tertiarySystemBackground))
                }
            }
            .foregroundColor(.primary)
            .frame(width: 70, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Right Column
            VStack(spacing: 16) {
                // Top Row: Font Family Selector
                Menu {
                    ForEach(NovelFont.allCases) { f in
                        Button(f.rawValue) { fontFamily = f }
                    }
                } label: {
                    HStack {
                        Image(systemName: "textformat")
                            .font(.title3)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading fonts")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                            Text(fontFamily.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(height: 62)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Bottom Row: Navigation Mode Toggle
                HStack(spacing: 4) {
                    Button(action: { isPaging = false }) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.up.and.down")
                            Text("Scrolling")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(!isPaging ? Color(UIColor.secondarySystemBackground) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(!isPaging ? .primary : .secondary)
                    }

                    Button(action: { isPaging = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.left.and.right")
                            Text("Paging")
                                .font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isPaging ? Color(UIColor.secondarySystemBackground) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundColor(isPaging ? .primary : .secondary)
                    }
                }
                .padding(4)
                .frame(height: 62)
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(UIColor.secondarySystemBackground), lineWidth: 2)
                )
            }
        }
        .padding(.horizontal)
    }

    private var themeTab: some View {
        VStack(spacing: 20) {
            // Theme Color Selector
            HStack(spacing: 0) {
                ForEach(NovelTheme.allCases) { t in
                    Spacer()
                    Button(action: { theme = t }) {
                        ZStack {
                            if t == .system {
                                ZStack {
                                    Circle().fill(Color.white).frame(width: 44, height: 44)
                                    Circle().fill(Color.black).mask(HStack(spacing: 0) { Spacer(); Rectangle() })
                                }
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            } else {
                                Circle()
                                    .fill(t.backgroundColor)
                                    .frame(width: 44, height: 44)
                            }

                            if t == .dark {
                                Image(systemName: "moon.stars.fill")
                                    .foregroundColor(.gray)
                            }

                            if theme == t {
                                Circle()
                                    .stroke(Color.primary, lineWidth: 2)
                                    .frame(width: 50, height: 50)

                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor((t == .dark || t == .system) ? .gray : .black)
                            }
                        }
                        .frame(width: 50, height: 50)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 16)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Custom Brightness Slider
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(height: 60)

                    Capsule()
                        .fill(Color(UIColor.systemGray3))
                        .frame(width: max(60, geo.size.width * brightness), height: 60)

                    HStack {
                        Image(systemName: "sun.min.fill")
                            .font(.title3)
                            .foregroundColor(Color(UIColor.tertiaryLabel))

                        Spacer()

                        Image(systemName: "sun.max.fill")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 20)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let percent = value.location.x / geo.size.width
                            let newBrightness = max(0, min(1, percent))

                            if abs(brightness - newBrightness) > 0.01 {
                                brightness = newBrightness
                                UIScreen.main.brightness = newBrightness
                            }
                        }
                )
            }
            .frame(height: 60)
            .onAppear {
                brightness = UIScreen.main.brightness
            }
        }
        .padding(.horizontal)
    }

    private var readingTab: some View {
        VStack(spacing: 20) {
            Toggle(isOn: $prefetchChapters) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seamless Reading")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Automatically fetch and append the next chapter as you approach the end of the current one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.primary)
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal)
    }
}
