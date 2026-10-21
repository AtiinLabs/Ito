import SwiftUI
import NukeUI
import Nuke
import ito_runner

private let detailHeroHeight: CGFloat = 340

private struct DetailNavTitleKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct DiscoverDetailView: View {
    @StateObject private var viewModel: DiscoverDetailViewModel
    private let viewFactory: AppViewFactory
    @State private var isDescriptionExpanded = false
    @State private var showNavTitle = false

    init(viewModel: DiscoverDetailViewModel, viewFactory: AppViewFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    private var media: DiscoverMedia { viewModel.media }
    private var resolverViewModel: SourceResolverViewModel { viewModel.sourceResolver }
    private var themeDominant: Color? { viewModel.theme.map { Color(hex: $0.dominantHex) } }
    private var themeSecondary: Color? { viewModel.theme.map { Color(hex: $0.secondaryHex) } }

    private var showingConfirmAlert: Binding<Bool> {
        Binding(
            get: { viewModel.confirmationCandidate != nil },
            set: { _ in }
        )
    }

    private var showingRejectConfirmation: Binding<Bool> {
        Binding(
            get: { viewModel.rejectionCandidate != nil },
            set: { _ in }
        )
    }

    private var cleanDescription: String? {
        guard let desc = media.description, !desc.isEmpty else { return nil }
        return desc.strippingHTML()
    }

    private var navigationBinding: Binding<Bool> {
        Binding(
            get: { resolverViewModel.isSourceDestinationPresented },
            set: { resolverViewModel.navigationBindingDidSet($0) }
        )
    }

    var body: some View {
        ZStack {
            if let themeDominant = themeDominant {
                themeDominant.ignoresSafeArea()
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SharedHeroHeader(
                        title: media.title,
                        backdropURL: media.bannerImage,
                        coverURL: media.coverImage,
                        authorOrStudio: media.titleRomaji != media.title ? media.titleRomaji : nil,
                        statusLabel: media.status?.replacingOccurrences(of: "_", with: " ").capitalized,
                        sourceLabel: media.averageScore != nil ? "★ \(media.averageScore!)%" : (media.format?.replacingOccurrences(of: "_", with: " ") ?? "Discover"),
                        onImageLoaded: { uiImage in
                            viewModel.heroImageLoaded(uiImage)
                        }
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: DetailNavTitleKey.self,
                                value: geo.frame(in: .global).maxY < 0
                            )
                        }
                    )

                    contentSection
                }
            }
            .background(Color.clear)

            // Top-level, stable navigation host
            NavigationLink(
                isActive: navigationBinding,
                destination: {
                    viewFactory.makeSourceDestinationView(
                        resolverViewModel: resolverViewModel
                    )
                },
                label: { EmptyView() }
            )
        }
        .coordinateSpace(name: "scroll")
        .animation(.easeIn(duration: 0.6), value: viewModel.theme)
        .onPreferenceChange(DetailNavTitleKey.self) { heroGone in
            withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = heroGone }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showNavTitle {
                    Text(media.title)
                        .font(.headline)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        .task { viewModel.start() }
        .alert("Reject Source?", isPresented: showingRejectConfirmation, presenting: viewModel.rejectionCandidate) { match in
            Button("Reject", role: .destructive) {
                viewModel.rejectPresentedSource(match)
            }
            Button("Cancel", role: .cancel) { viewModel.cancelRejection() }
        } message: { _ in
            Text("Are you sure you want to reject this match?")
        }
        .alert("Confirm Source?", isPresented: showingConfirmAlert, presenting: viewModel.confirmationCandidate) { match in
            Button("Confirm", role: .none) {
                viewModel.confirmPresentedSource(match)
            }
            Button("Cancel", role: .cancel) { viewModel.cancelConfirmation() }
        } message: { _ in
            Text("This is an ambiguous match. Are you sure you want to link it?")
        }
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let genres = media.genres, !genres.isEmpty {
                tagsRow(tags: genres)
                    .padding(.top, 16)
            }

            if let desc = cleanDescription {
                descriptionSection(desc)
            }

            infoRow

            if viewModel.detailLoadState == .failed {
                HStack(spacing: 12) {
                    Text("Full details could not be refreshed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        viewModel.retryDetails()
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16)
            }

            Divider().padding(.horizontal, 16)

            sourceResolverSection

            if let recommendations = media.recommendations, !recommendations.isEmpty {
                Divider().padding(.horizontal, 16)
                recommendationsSection(recommendations)
            }
        }
        .padding(.bottom, 24)
        .background(Color.clear)
        .frame(maxWidth: UIScreen.main.bounds.width)
        .clipped()
    }

    // MARK: - Info Row

    private var infoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                if let eps = media.episodes {
                    infoChip(label: "Episodes", value: "\(eps)")
                }
                if let chs = media.chapters {
                    infoChip(label: "Chapters", value: "\(chs)")
                }
                if let season = media.season, let year = media.seasonYear {
                    infoChip(label: "Season", value: "\(season.capitalized) \(year)")
                } else if let year = media.seasonYear {
                    infoChip(label: "Year", value: "\(year)")
                }
                if let type = media.format {
                    infoChip(label: "Format", value: type.replacingOccurrences(of: "_", with: " "))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func infoChip(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.itoCardBackground)
        .cornerRadius(10)
    }

    // MARK: - Tags

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill)).cornerRadius(14)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Description

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.subheadline).foregroundStyle(.primary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption.weight(.semibold)).foregroundStyle(themeSecondary ?? Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Source Resolver Section

    private var sourceResolverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read with Plugins")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            if let error = resolverViewModel.pluginSearchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            switch resolverViewModel.state {
            case .idle:
                EmptyView()
            case .savedSource(let mapping, let payload):
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if let plugin = viewModel.installedPlugins[mapping.pluginId],
                           let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundStyle(Color.accentColor).imageScale(.large)
                                .frame(width: 40, height: 40)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(payload.title())
                                .font(.headline)
                                .lineLimit(1)

                            let pluginName = viewModel.installedPlugins[mapping.pluginId]?.info.name
                                ?? mapping.pluginId
                            Text("Saved Source • \(pluginName) • Confirmed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Open") {
                            resolverViewModel.openSavedSource(mapping: mapping, payload: payload)
                        }
                        .font(.caption.weight(.bold))
                        .itoProminentButtonStyle()
                        .disabled(resolverViewModel.processingMatchIdentity != nil)
                    }
                    .padding(.horizontal, 16)

                    Button("Search Other Sources") {
                        resolverViewModel.resolve()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .disabled(resolverViewModel.processingMatchIdentity != nil)
                }
            case .loading(let matches):
                VStack(spacing: 12) {
                    HStack {
                        ProgressView().progressViewStyle(.circular)
                            .padding(.trailing, 8)
                        Text("Searching installed sources...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    if !matches.isEmpty {
                        Divider().padding(.horizontal, 16)
                        matchesList(matches)
                    }
                }
            case .completed(let matches):
                matchesList(matches)
            case .noCompatiblePlugins:
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("No plugins installed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Install plugins from the Browse tab to source content.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            case .empty:
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("No matches found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            case .partialFailure(let matches, let failedPlugins):
                VStack(alignment: .leading, spacing: 12) {
                    if !matches.isEmpty {
                        matchesList(matches)
                        Divider().padding(.horizontal, 16)
                    }

                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Some plugins failed: \(failedPlugins.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
            case .fatalFailure(let error):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.red)
                    Text("Error")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            case .cancelled:
                Text("Search cancelled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func matchesList(_ matches: [MatchedSource]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.sourceIdentity) { index, match in
                ResolvedSourceRow(
                    match: match,
                    installedPlugins: viewModel.installedPlugins,
                    isProcessing: resolverViewModel.isProcessing(match),
                    onConfirm: {
                        if match.decision == .autoConfirm {
                            viewModel.confirmSourceDirectly(match)
                        } else {
                            viewModel.requestConfirmation(for: match)
                        }
                    },
                    onReject: {
                        viewModel.requestRejection(for: match)
                    }
                )
                if index != matches.count - 1 {
                    Divider().padding(.leading, 72)
                }
            }
        }
    }

    // MARK: - Recommendations

    private func recommendationsSection(_ recommendations: [DiscoverMedia]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Like This")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recommendations) { recMedia in
                        NavigationLink(
                            destination: viewFactory.makeDiscoverDetailView(media: recMedia)
                        ) {
                            DiscoverRecommendationCard(media: recMedia)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }
}

struct SourceDestinationHost: View {
    @ObservedObject var resolverViewModel: SourceResolverViewModel
    let viewFactory: AppViewFactory

    var body: some View {
        Group {
            if let route = resolverViewModel.sourceRoute {
                destinationContent(route)
            } else {
                Color.clear
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    resolverViewModel.manualDestinationPopRequested()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                        Text("Back")
                    }
                }
            }
        }
        .onAppear {
            resolverViewModel.destinationDidAppear()
        }
        .onDisappear {
            resolverViewModel.destinationDidDisappear()
        }
    }

    @ViewBuilder
    private func destinationContent(_ route: SourceRoute) -> some View {
        switch route.media {
        case .manga(let manga):
            viewFactory.makeMangaDetailView(
                runner: route.runner,
                media: manga,
                pluginID: route.pluginID
            ) { updated in
                try await route.runner.getMangaUpdate(manga: updated)
            }
        case .anime(let anime):
            viewFactory.makeAnimeDetailView(
                runner: route.runner,
                media: anime,
                pluginID: route.pluginID
            ) { updated in
                try await route.runner.getAnimeUpdate(
                    anime: updated,
                    needsDetails: true,
                    needsEpisodes: true
                )
            }
        }
    }
}

// MARK: - Recommendation Card

private struct DiscoverRecommendationCard: View {
    let media: DiscoverMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                            .frame(width: 110, height: 160)
                            .clipped()
                    } else if state.error != nil {
                        Color.itoCardBackground
                    } else {
                        Color.itoCardBackground.overlay(ProgressView().tint(.gray))
                    }
                }
                .processors([.resize(width: 200)])
                .frame(width: 110, height: 160)
                .cornerRadius(8)
                .clipped()
            } else {
                ZStack {
                    Color.itoCardBackground
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary)
                }
                .frame(width: 110, height: 160)
                .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(media.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 110, alignment: .leading)

                if let score = media.averageScore {
                    Text("★ \(score)%")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: 110)
    }
}

// MARK: - Resolved Source Row

private struct ResolvedSourceRow: View {
    let match: MatchedSource
    let installedPlugins: [String: InstalledPlugin]
    let isProcessing: Bool
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let plugin = installedPlugins[match.pluginID],
               let iconData = plugin.iconData, let uiImage = UIImage(data: iconData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(match.decision == .discard ? 0.4 : 1.0)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(Color.accentColor).imageScale(.large)
                    .frame(width: 40, height: 40)
                    .opacity(match.decision == .discard ? 0.4 : 1.0)
            }

            VStack(alignment: .leading, spacing: 2) {
                let mediaTitle = match.media.title()
                Text(mediaTitle)
                    .font(.headline)
                    .strikethrough(match.decision == .discard)
                    .foregroundStyle(match.decision == .discard ? .secondary : .primary)
                    .lineLimit(1)

                let pluginName = installedPlugins[match.pluginID]?.info.name ?? match.pluginID
                Text("\(pluginName) • \(matchMethodString(match.matchMethod))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            ZStack {
                Menu {
                    Button("Confirm", action: onConfirm)
                    Button("Reject", role: .destructive, action: onReject)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .opacity(match.decision != .discard && !isProcessing ? 1 : 0)
                .disabled(match.decision == .discard || isProcessing)

                if isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .padding(8)
                } else if match.decision == .discard {
                    Button("Revert") {
                        onConfirm()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isProcessing && match.decision != .discard else { return }
            onConfirm()
        }
    }

    private func matchMethodString(_ method: MatchMethod) -> String {
        switch method {
        case .exactPreferred: return "Exact Match"
        case .exactAlternative: return "Exact Alt Match"
        case .fuzzy: return String(format: "Fuzzy (%.0f%%)", match.score * 100)
        case .none: return "No Match"
        }
    }
}

// Extension to safely get title from ResolvedPluginMedia
private extension ResolvedPluginMedia {
    func title() -> String {
        switch self {
        case .manga(let m): return m.title
        case .anime(let a): return a.title
        }
    }
}
