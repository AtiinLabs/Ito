import Nuke
import NukeUI
import SwiftUI

/// The Discover banner hero: one page per trending item, drawn from AniList's banner artwork with the cover as the
/// foreground poster. Each page opens that item's Discover detail.
///
/// The carousel pages on its own every `DiscoverHeroMetrics.autoAdvanceInterval` seconds, but only while it is on
/// screen, the app is active, and neither Reduce Motion nor VoiceOver is on. A page the person swipes to stays for a
/// full interval. Touches are not tracked with a drag gesture, because a drag gesture over the pages would keep their
/// links from firing.
struct DiscoverHeroCarousel<Destination: View>: View {
    let items: [DiscoverMedia]
    let width: CGFloat
    /// The area the Discover home shows, in `DiscoverHeroMetrics.coordinateSpaceName`. The hero is on screen while it
    /// overlaps this area.
    let viewport: CGSize
    /// Whether the hero is on screen, as reported by the home through `DiscoverHeroVisibilityKey`.
    let isOnScreen: Bool
    let makeDestination: (DiscoverMedia) -> Destination

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    /// Restarts the timer whenever what it depends on changes, so no timer outlives a layout change. The selection is
    /// part of the key: a page the person swiped to stays for a full interval.
    private struct AutoAdvanceKey: Equatable {
        let ids: [Int]
        let selection: Int
        let isEnabled: Bool
    }

    private var autoAdvanceKey: AutoAdvanceKey {
        AutoAdvanceKey(
            ids: items.map(\.id),
            selection: selection,
            // Reduce Motion and VoiceOver users page by hand; the timer never moves a focused page.
            isEnabled: items.count > 1
                && !reduceMotion
                && !isVoiceOverRunning
                && scenePhase == .active
                && isOnScreen
        )
    }

    private var height: CGFloat {
        DiscoverHeroMetrics.height(forWidth: width)
    }

    /// The page shown, clamped so a shrinking item list never indexes past its end.
    private var currentIndex: Int {
        min(selection, max(items.count - 1, 0))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items.indices, id: \.self) { index in
                page(items[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if items.count > 1 {
                pageIndicator
                    .padding(12)
            }
        }
        .accessibilityAdjustableAction { direction in
            let count = items.count
            guard count > 1 else { return }
            switch direction {
            case .increment: selection = (currentIndex + 1) % count
            case .decrement: selection = (currentIndex + count - 1) % count
            default: break
            }
        }
        .accessibilityValue(
            String(
                localized: "Banner \(currentIndex + 1) of \(items.count)",
                comment: "Accessibility value for the Discover banner hero: which banner is shown out of how many."
            )
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DiscoverHeroVisibilityKey.self,
                    value: proxy.frame(in: .named(DiscoverHeroMetrics.coordinateSpaceName))
                        .intersects(CGRect(origin: .zero, size: viewport))
                )
            }
        )
        .onChange(of: items.count) { count in
            selection = min(selection, max(count - 1, 0))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        }
        .task(id: autoAdvanceKey) {
            guard autoAdvanceKey.isEnabled else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(DiscoverHeroMetrics.autoAdvanceInterval * 1_000_000_000))
            } catch {
                return
            }
            let count = items.count
            withAnimation(.easeInOut) {
                selection = (currentIndex + 1) % count
            }
        }
    }

    private func page(_ media: DiscoverMedia) -> some View {
        NavigationLink(destination: makeDestination(media)) {
            ZStack(alignment: .bottomLeading) {
                artwork(media)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Color(.systemBackground).opacity(0.9), location: 0.75),
                        .init(color: Color(.systemBackground), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                HStack(alignment: .bottom, spacing: 14) {
                    poster(media)
                    details(media)
                }
                .padding(16)
            }
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artwork(_ media: DiscoverMedia) -> some View {
        if let url = (media.bannerImage ?? media.coverImage).flatMap(URL.init(string:)) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .processors([.resize(width: width * 2)])
            .frame(width: width, height: height)
            .clipped()
            .accessibilityHidden(true)
        } else {
            Color.gray.opacity(0.3)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func poster(_ media: DiscoverMedia) -> some View {
        if let url = media.coverImage.flatMap(URL.init(string:)) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .processors([.resize(width: 240)])
            .frame(width: 100, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
            .accessibilityHidden(true)
        }
    }

    private func details(_ media: DiscoverMedia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let format = media.format {
                    Text(DiscoverOptionLabels.format(format))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = media.cleanDescription, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Dots that show the page; decorative, because the accessibility value already gives the position.
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                Capsule()
                    .fill(index == currentIndex ? Color.accentColor : Color.white.opacity(0.5))
                    .frame(width: index == currentIndex ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .animation(.easeInOut(duration: 0.2), value: currentIndex)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Reports whether the Discover banner hero overlaps the Discover home's visible area.
struct DiscoverHeroVisibilityKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}
