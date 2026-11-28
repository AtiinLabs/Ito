import Foundation
import ito_runner

/// A source home as the screen lays it out: the featured carousel (the hero) and the shelves that remain.
///
/// `SourceViewModel` builds it once when it publishes `homeLayout`, so no view body re-derives which component
/// leads the home. It reads the media models, which are main-actor isolated, so it is main-actor too.
@MainActor
struct HomePresentation {
    /// The carousel. Nil when no component can be featured.
    let featured: FeaturedSection?
    /// Components rendered as shelves, in source order.
    let shelves: [HomeShelf]

    static func make(_ layout: HomeLayout) -> HomePresentation {
        let components = layout.components
        // A native featured component is the source's own carousel. The first one with items leads the home and
        // leaves the shelves; a later one stays inline as banners.
        if let index = components.firstIndex(where: { $0.value.nativeFeatured?.items.isEmpty == false }),
           let featured = components[index].value.nativeFeatured {
            return HomePresentation(
                featured: FeaturedSection(
                    items: featured.items.map { FeaturedCard(item: $0) },
                    autoAdvance: FeaturedSection.autoAdvance(from: featured.autoAdvance),
                    listing: featured.listing
                ),
                shelves: shelves(components, excluding: index)
            )
        }
        // Without a native featured component the home has no carousel. Every component is a shelf, including
        // BigScrollers, which keep their own presentation.
        return HomePresentation(featured: nil, shelves: shelves(components, excluding: nil))
    }

    private static func shelves(_ components: [HomeComponent], excluding hero: Int?) -> [HomeShelf] {
        components.indices.compactMap { index in
            guard index != hero else { return nil }
            let component = components[index]
            return HomeShelf(
                id: index,
                component: component,
                banners: component.value.nativeFeatured?.items.map { FeaturedCard(item: $0) } ?? []
            )
        }
    }
}

/// One component rendered as a shelf, identified by its index in the layout.
@MainActor
struct HomeShelf: Identifiable {
    let id: Int
    let component: HomeComponent
    /// The pages of a native featured component that stays inline as banner cards. Empty for every other component.
    let banners: [FeaturedCard]
}

/// The carousel: its items and how long each one stays before the next.
@MainActor
struct FeaturedSection {
    static let defaultAutoAdvance: TimeInterval = 5

    let items: [FeaturedCard]
    /// Seconds before the carousel turns to the next item.
    let autoAdvance: TimeInterval
    /// The target of the "See all" link, when the source gave one.
    let listing: Listing?

    init(items: [FeaturedCard], autoAdvance: TimeInterval, listing: Listing? = nil) {
        self.items = items
        self.autoAdvance = autoAdvance
        self.listing = listing
    }

    /// The source's interval when it is finite and between 2 and 60 seconds, else the default. An interval outside
    /// that range is ignored rather than clamped, so a broken value never sets the pace.
    static func autoAdvance(from interval: Float32?) -> TimeInterval {
        guard let interval, interval.isFinite, (2...60).contains(interval) else { return defaultAutoAdvance }
        return TimeInterval(interval)
    }
}

/// One item of the carousel. The entry is what the user opens; a native item adds the presentation around it.
@MainActor
struct FeaturedCard: Identifiable {
    let id: MediaEntryIdentity
    let entry: MediaEntry
    let title: String
    /// The entry's 2:3 cover.
    let cover: URL?
    /// The item's wide backdrop, about 16:9. Nil when the item has none.
    let banner: URL?
    /// Transparent title art. It replaces the title text once it loads.
    let logo: URL?
    let tagline: String?
    /// The item's own summary, or the entry's description when the item has none.
    let summary: String?
    /// The source's status, already localized by the media model.
    let status: String?
    /// The source's tags, as plugin text.
    let genres: [String]
    /// The chapters or episodes the source listed, when it listed any.
    let unitCount: Int?
    let badge: FeaturedBadgeDisplay?
    /// The item's structured facts. When empty, the hero shows the status and genres instead.
    let chips: [FeaturedChipDisplay]
    /// A tint for the primary button, `0xRRGGBB`. Nil unless white text reads on it at WCAG AA contrast.
    let accent: UInt32?
    let action: FeaturedAction

    /// The image behind the item: its banner when it has one, else its cover.
    var backdrop: URL? { banner ?? cover }

    init(item: FeaturedItem) {
        switch item.entry {
        case .manga(let media): self.init(item: item, media: media)
        case .anime(let media): self.init(item: item, media: media)
        case .novel(let media): self.init(item: item, media: media)
        }
    }

    private init<Media: MediaDisplayable>(item: FeaturedItem, media: Media) {
        entry = item.entry
        id = item.entry.catalogIdentity
        title = media.title
        cover = media.cover.flatMap { URL(string: $0) }
        banner = item.banner.flatMap { URL(string: $0) }
        logo = item.logo.flatMap { URL(string: $0) }
        tagline = nonEmptyText(item.tagline)
        summary = nonEmptyText(item.summary) ?? nonEmptyText(media.description)
        status = media.displayStatus
        genres = media.tags ?? []
        let listed = media.chapterList?.count ?? 0
        unitCount = listed > 0 ? listed : nil
        badge = item.badge.flatMap { FeaturedBadgeDisplay($0) }
        chips = item.chips.compactMap { FeaturedChipDisplay($0) }
        accent = item.accent.flatMap { Self.readableAccent($0) }
        action = FeaturedAction(native: item.action)
    }

    /// White text must read on the tint at WCAG AA (4.5:1). A lighter tint is dropped rather than darkened, so
    /// the button keeps the app's accent instead of an unreadable color.
    private static func readableAccent(_ rgb: UInt32) -> UInt32? {
        guard rgb <= 0xFFFFFF else { return nil }
        let whiteContrast = 1.05 / (relativeLuminance(rgb) + 0.05)
        return whiteContrast >= 4.5 ? rgb : nil
    }

    /// The WCAG relative luminance of a `0xRRGGBB` color.
    private static func relativeLuminance(_ rgb: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let channel = Double((rgb >> shift) & 0xFF) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// What the primary button of a featured item does.
enum FeaturedAction: Equatable {
    /// Opens the series' details.
    case details
    /// Opens the series at its first unread or unwatched unit.
    case start

    /// The SDK sends `1` for start and `0` for details. Any other value is details, the safe choice for a value a
    /// later SDK adds.
    init(native action: Int32) {
        self = action == 1 ? .start : .details
    }
}

/// A badge over a featured item. The kinds the SDK defines are shown localized; a custom label is the plugin's text.
enum FeaturedBadgeDisplay: Equatable {
    case new
    /// The rank is shown only when it is in the SDK's 1 to 999 range.
    case trending(rank: Int?)
    case popular
    case updated
    /// Plugin text, shown verbatim.
    case custom(String)

    init?(_ badge: FeaturedBadge) {
        let label = nonEmptyText(badge.label)
        switch badge.kind {
        case 0:
            guard let label else { return nil }
            self = .custom(label)
        case 1: self = .new
        case 2:
            let rank = badge.rank.flatMap { (1...999).contains($0) ? Int($0) : nil }
            self = .trending(rank: rank)
        case 3: self = .popular
        case 4: self = .updated
        default:
            // A kind a later SDK adds keeps its label. Without one there is nothing honest to show.
            guard let label else { return nil }
            self = .custom(label)
        }
    }
}

/// A structured fact about a featured item. Each case is shown as its own text, never joined with others.
enum FeaturedChipDisplay: Equatable {
    case year(Int)
    /// The SDK's 0 to 10 score.
    case rating(Double)
    /// A count of the source's units. The view words it for the entry's kind.
    case units(Int)
    case genre(String)
    case format(String)
    case text(String)

    init?(_ chip: FeaturedChip) {
        if let typed = Self.typed(chip) {
            self = typed
        } else if let text = nonEmptyText(chip.text) {
            // A known kind whose number is missing or out of range, and an unknown kind, both show their text.
            self = .text(text)
        } else {
            return nil
        }
    }

    private static func typed(_ chip: FeaturedChip) -> FeaturedChipDisplay? {
        let text = nonEmptyText(chip.text)
        let number = chip.number.flatMap { $0.isFinite ? $0 : nil }
        switch chip.kind {
        case 1:
            guard let number, number.rounded() == number, (1...9999).contains(number) else { return nil }
            return .year(Int(number))
        case 2:
            guard let number, (0...10).contains(number) else { return nil }
            return .rating(number)
        case 3:
            guard let number, number.rounded() == number, (0...1_000_000).contains(number) else { return nil }
            return .units(Int(number))
        case 4: return text.map { .genre($0) }
        case 5: return text.map { .format($0) }
        default: return nil
        }
    }
}

/// Text from the plugin, or nil when it is absent or only whitespace.
private func nonEmptyText(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

@MainActor
private extension HomeComponentValue {
    /// The content of a native featured component.
    var nativeFeatured: FeaturedComponent? {
        switch self {
        case .featured(let featured): featured
        default: nil
        }
    }
}
