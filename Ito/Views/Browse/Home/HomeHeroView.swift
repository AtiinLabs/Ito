import SwiftUI
import UIKit
import NukeUI
import Nuke
import ito_runner

/// The featured carousel: a page per item with its artwork, title, actions and summary. It turns on its own timer,
/// which runs only while the carousel is visible and the user is not touching it.
struct HomeHeroView<Destination: View>: View {
    let section: FeaturedSection
    let layoutMode: HomeLayoutMode
    let width: CGFloat
    let height: CGFloat
    /// The area the home shows, in the home's coordinate space. The carousel is on screen while it overlaps it.
    let viewport: CGSize
    let isOnScreen: Bool
    /// The "See all" link for the carousel's listing, when the source gave one.
    let seeAll: AnyView?
    let makeDestination: (MediaEntry, MediaDetailOpenIntent?) -> Destination

    @Environment(\.sourceCoverRequests) private var coverRequests
    @Environment(\.imageSourceID) private var imageSourceID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var isTouched = false
    @State private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    /// Restarts the timer whenever what it depends on changes, so no timer outlives a layout change.
    private struct AutoAdvanceKey: Equatable {
        let ids: [MediaEntryIdentity]
        let interval: TimeInterval
        let isEnabled: Bool
    }

    private var autoAdvanceKey: AutoAdvanceKey {
        AutoAdvanceKey(
            ids: section.items.map(\.id),
            interval: section.autoAdvance,
            // Reduce Motion and VoiceOver users page by hand; the timer never moves a focused page.
            isEnabled: section.items.count > 1
                && !reduceMotion
                && !isVoiceOverRunning
                && scenePhase == .active
                && isOnScreen
                && !isTouched
        )
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(section.items.indices, id: \.self) { index in
                page(section.items[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: width, height: height)
        .background(Color(.systemBackground))
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isTouched = true }
                .onEnded { _ in isTouched = false }
        )
        .accessibilityAdjustableAction { direction in
            let count = section.items.count
            guard count > 1 else { return }
            switch direction {
            case .increment: selection = (selection + 1) % count
            case .decrement: selection = (selection + count - 1) % count
            default: break
            }
        }
        .accessibilityValue(
            String(localized: "Item \(min(selection, section.items.count - 1) + 1) of \(section.items.count)",
                   comment: "Accessibility value for the featured carousel: which item is shown out of how many.")
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HomeHeroVisibilityKey.self,
                    value: proxy.frame(in: .named(HomeLayoutMetrics.coordinateSpaceName))
                        .intersects(CGRect(origin: .zero, size: viewport))
                )
            }
        )
        .onChange(of: section.items.count) { count in
            selection = min(selection, max(count - 1, 0))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        }
        .task(id: autoAdvanceKey) {
            guard autoAdvanceKey.isEnabled else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(section.autoAdvance * 1_000_000_000))
                } catch {
                    return
                }
                let count = section.items.count
                withAnimation(.easeInOut) {
                    selection = (selection + 1) % count
                }
            }
        }
    }

    private func page(_ card: FeaturedCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(card)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Color(.systemBackground).opacity(0.9), location: 0.75),
                    .init(color: Color(.systemBackground), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 10) {
                if section.items.count > 1 || seeAll != nil {
                    HStack(alignment: .center) {
                        if section.items.count > 1 {
                            pageDots
                        }
                        Spacer(minLength: 0)
                        if let seeAll {
                            seeAllLink(seeAll)
                        }
                    }
                }
                if layoutMode == .sideBySide, let poster = card.cover ?? card.backdrop {
                    FeaturedArtwork(url: poster, processingWidth: columnPosterWidth * 2)
                        .frame(width: columnPosterWidth, height: columnPosterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 6)
                        .accessibilityHidden(true)
                }
                titleBlock(card)
                actions(card)
                if let summary = card.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    @ViewBuilder
    private func artwork(_ card: FeaturedCard) -> some View {
        switch layoutMode {
        case .narrow:
            narrowArtwork(card)
        case .sideBySide:
            columnArtwork(card)
        }
    }

    /// The banner fills the carousel. Without one, the cover is 2:3, so at the carousel's width it is taller than the
    /// carousel; it is cropped from the top, where faces are, and the gradient carries the text.
    @ViewBuilder
    private func narrowArtwork(_ card: FeaturedCard) -> some View {
        if let banner = card.banner {
            FeaturedArtwork(url: banner, processingWidth: width * 2)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        } else {
            coverArtwork(card.cover)
        }
    }

    /// The cover fit to the carousel's width, cropped from the top.
    @ViewBuilder
    private func coverArtwork(_ cover: URL?) -> some View {
        Group {
            if let cover {
                LazyImage(request: coverRequests.request(cover, pluginID: imageSourceID)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: width)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .processors([.resize(width: width * 2)])
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
    }

    /// The side-by-side column blurs its backdrop behind the poster, so the wide image adds color without competing
    /// with the poster or the text. The scale keeps the blur's soft edge outside the column.
    private func columnArtwork(_ card: FeaturedCard) -> some View {
        Group {
            if let backdrop = card.backdrop {
                FeaturedArtwork(url: backdrop, processingWidth: width)
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(1.1)
        .blur(radius: 24)
        .clipped()
        .accessibilityHidden(true)
    }

    /// The column's poster keeps the 2:3 cover shape at about 38% of the column's height, and never wider than the
    /// text beside it.
    private var columnPosterHeight: CGFloat {
        min(height * 0.38, (width - 32) * 1.5)
    }

    private var columnPosterWidth: CGFloat {
        columnPosterHeight * 2 / 3
    }

    /// The logo replaces the title text once it loads. Until then, and when it fails, the title stays, so the page
    /// always has a visible name.
    private func titleBlock(_ card: FeaturedCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let badge = card.badge {
                badgeView(badge, tint: tint(card))
            }
            titleView(card)
            if let tagline = card.tagline {
                Text(verbatim: tagline)
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            factsView(card)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func titleView(_ card: FeaturedCard) -> some View {
        if let logo = card.logo {
            LazyImage(request: coverRequests.request(logo, pluginID: imageSourceID)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(width * 0.7, 280), maxHeight: 64, alignment: .leading)
                        .accessibilityLabel(Text(verbatim: card.title))
                } else {
                    titleText(card)
                }
            }
            .processors([.resize(width: 560)])
        } else {
            titleText(card)
        }
    }

    private func titleText(_ card: FeaturedCard) -> some View {
        Text(verbatim: card.title)
            .font(.title2.weight(.bold))
            .lineLimit(2)
    }

    /// The structured chips when the item has them; otherwise the status, genres and unit count.
    @ViewBuilder
    private func factsView(_ card: FeaturedCard) -> some View {
        if card.chips.isEmpty {
            metadata(card)
        } else {
            chipRow(card)
        }
    }

    private func chipRow(_ card: FeaturedCard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(card.chips.indices, id: \.self) { index in
                    chipText(card.chips[index], kind: card.entry.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
            }
        }
    }

    /// Each chip is one text, never joined with another. The rating is the SDK's 0 to 10 score, shown to one decimal.
    private func chipText(_ chip: FeaturedChipDisplay, kind: MediaKind) -> Text {
        switch chip {
        case .year(let year):
            return Text(verbatim: String(year))
        case .rating(let score):
            return Text(verbatim: "★ " + score.formatted(.number.precision(.fractionLength(1))))
        case .units(let count):
            return Text(verbatim: unitText(count, kind: kind))
        case .genre(let text), .format(let text), .text(let text):
            return Text(verbatim: text)
        }
    }

    private func badgeView(_ badge: FeaturedBadgeDisplay, tint: Color) -> some View {
        Text(verbatim: badgeText(badge))
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint))
    }

    private func badgeText(_ badge: FeaturedBadgeDisplay) -> String {
        switch badge {
        case .new:
            return String(localized: "New", comment: "Featured badge: the series was added to the source recently.")
        case .trending(let rank):
            if let rank {
                return String(localized: "Trending #\(rank)", comment: "Featured badge: the series is trending, with its rank on the source.")
            }
            return String(localized: "Trending", comment: "Featured badge: the series is trending on the source.")
        case .popular:
            return String(localized: "Popular", comment: "Featured badge: the series is among the most popular on the source.")
        case .updated:
            return String(localized: "Updated", comment: "Featured badge: the series has new units since the source last changed it.")
        case .custom(let label):
            return label
        }
    }

    private func seeAllLink(_ destination: AnyView) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 2) {
                Text(verbatim: String(localized: "See All", comment: "Featured carousel link: opens the full listing the carousel comes from."))
                Image(systemName: "chevron.right")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// The dots sit on a material capsule: over a blurred or bright cover, faint dots alone disappear.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(section.items.indices, id: \.self) { index in
                Circle()
                    .fill(index == min(selection, section.items.count - 1) ? Color.primary : Color.primary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityHidden(true)
    }

    /// Status, the first genres and the unit count, each its own text: the parts are never joined into one string.
    private func metadata(_ card: FeaturedCard) -> some View {
        var parts: [String] = []
        if let status = card.status { parts.append(status) }
        parts.append(contentsOf: card.genres.prefix(2))
        if let count = card.unitCount { parts.append(unitText(count, kind: card.entry.kind)) }
        return HStack(spacing: 6) {
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 {
                    Text(verbatim: "·")
                }
                Text(verbatim: parts[index])
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func actions(_ card: FeaturedCard) -> some View {
        HStack(spacing: 12) {
            NavigationLink(destination: makeDestination(card.entry, primaryIntent(card))) {
                Text(verbatim: primaryTitle(card))
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(tint(card)))
            }
            NavigationLink(destination: makeDestination(card.entry, .save)) {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
            }
            .accessibilityLabel(String(localized: "Add to Library", comment: "Featured carousel button: adds the shown series to the library."))
        }
        .buttonStyle(.plain)
    }

    /// Start opens the series at its first unread or unwatched unit; details opens it without a resume target.
    private func primaryIntent(_ card: FeaturedCard) -> MediaDetailOpenIntent? {
        switch card.action {
        case .start:
            return .resume(preferredScanlator: nil)
        case .details:
            return nil
        }
    }

    private func primaryTitle(_ card: FeaturedCard) -> String {
        switch card.action {
        case .start:
            return startTitle(for: card.entry.kind)
        case .details:
            return String(localized: "View Details", comment: "Featured carousel button: opens the series' details.")
        }
    }

    /// The source's accent when it reads at WCAG AA with white text, else the app's accent.
    private func tint(_ card: FeaturedCard) -> Color {
        card.accent.map { Color(featuredRGB: $0) } ?? Color.accentColor
    }

    private func startTitle(for kind: MediaKind) -> String {
        switch kind {
        case .anime:
            String(localized: "Start Watching", comment: "Featured carousel button: opens the anime series at its first unwatched episode.")
        case .manga, .novel:
            String(localized: "Start Reading", comment: "Featured carousel button: opens the series at its first unread chapter.")
        }
    }

    private func unitText(_ count: Int, kind: MediaKind) -> String {
        switch kind {
        case .anime:
            String(localized: "\(count) episodes", comment: "Featured carousel metadata: how many episodes the source lists.")
        case .manga, .novel:
            String(localized: "\(count) chapters", comment: "Featured carousel metadata: how many chapters the source lists.")
        }
    }
}

/// A later featured component, shown inline as a row of 16:9 banners. Each banner opens its entry like a shelf card.
struct HomeBannerRow<Destination: View>: View {
    let banners: [FeaturedCard]
    let bannerWidth: CGFloat
    let makeDestination: (MediaEntry) -> Destination

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(banners) { banner in
                    NavigationLink(destination: makeDestination(banner.entry)) {
                        BannerCard(card: banner, width: bannerWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct BannerCard: View {
    let card: FeaturedCard
    let width: CGFloat

    var body: some View {
        let height = width * 9 / 16
        ZStack(alignment: .bottomLeading) {
            if let backdrop = card.backdrop {
                FeaturedArtwork(url: backdrop, processingWidth: width * 2)
            } else {
                Color.gray.opacity(0.3)
            }
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let tagline = card.tagline {
                    Text(verbatim: tagline)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(10)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A plugin image through the source's cover pipeline, filling its frame. The caller frames and clips it.
struct FeaturedArtwork: View {
    let url: URL
    let processingWidth: CGFloat

    @Environment(\.sourceCoverRequests) private var coverRequests
    @Environment(\.imageSourceID) private var imageSourceID

    var body: some View {
        LazyImage(request: coverRequests.request(url, pluginID: imageSourceID)) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .processors([.resize(width: processingWidth)])
        .clipped()
    }
}

private extension Color {
    /// A `0xRRGGBB` color from the SDK.
    init(featuredRGB rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// Whether the carousel overlaps the home's visible area. Reported only when it changes, so scrolling does not
/// re-render the home.
struct HomeHeroVisibilityKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}
