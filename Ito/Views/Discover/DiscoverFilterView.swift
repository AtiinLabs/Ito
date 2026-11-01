import SwiftUI

struct DiscoverFilterView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let mediaType: DiscoverMediaType
    let filters: DiscoverFilters
    var onApply: (DiscoverFilters) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var localFilters: DiscoverFilters = DiscoverFilters()
    @State private var tagSearchText = ""

    private var animeFormats: [String] {
        ["TV", "TV_SHORT", "MOVIE", "SPECIAL", "OVA", "ONA", "MUSIC"]
    }

    private var mangaFormats: [String] {
        ["MANGA", "ONE_SHOT", "NOVEL"]
    }

    private var formats: [String] {
        mediaType == .anime ? animeFormats : mangaFormats
    }

    private let statuses = ["RELEASING", "FINISHED", "NOT_YET_RELEASED", "CANCELLED", "HIATUS"]

    private let countries = ["JP", "KR", "CN", "TW"]

    private let seasons = ["WINTER", "SPRING", "SUMMER", "FALL"]

    private var filteredTags: [DiscoverTag] {
        let nonAdult = viewModel.availableTags.filter { $0.isAdult != true }
        if tagSearchText.isEmpty { return nonAdult }
        return nonAdult.filter { $0.name.localizedCaseInsensitiveContains(tagSearchText) }
    }

    var body: some View {
        NavigationView {
            List {
                if viewModel.filterLoadState == .failed {
                    filterLoadFailureSection
                }
                sortSection
                yearSeasonSection
                genreSection
                formatSection
                statusSection
                countrySection
                tagSection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        localFilters = DiscoverFilters()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        onApply(localFilters)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .onAppear {
                localFilters = filters
                viewModel.loadFilterOptionsIfNeeded()
            }
        }
        .interactiveDismissDisabled(localFilters != filters)
    }

    // MARK: - Sort

    private var filterLoadFailureSection: some View {
        Section {
            HStack {
                Text("Some filter options couldn't be loaded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    viewModel.retryFilterOptions()
                }
            }
        }
    }

    private var sortSection: some View {
        Section("Sort By") {
            Picker("Sort By", selection: $localFilters.sort) {
                ForEach([DiscoverSort.trending, .popularity, .score, .newest], id: \.self) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - Year & Season

    private var yearSeasonSection: some View {
        Section {
            HStack {
                Text("Year")
                Spacer()
                if let year = localFilters.year {
                    Text(String(year))
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { year },
                        set: { localFilters.year = $0 }
                    ), in: 1970...2030)
                    .labelsHidden()
                    .frame(width: 100)

                    Button {
                        localFilters.year = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Set") {
                        localFilters.year = viewModel.currentYear
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }

            if localFilters.year != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Season")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons, id: \.self) { value in
                                let isSelected = localFilters.season == value
                                Button {
                                    localFilters.season = isSelected ? nil : value
                                } label: {
                                    Text(DiscoverOptionLabels.season(value))
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                                        .foregroundColor(isSelected ? .itoOnAccent : .primary)
                                        .cornerRadius(16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Year & Season")
        }
    }

    // MARK: - Genres (Tri-state)

    private var genreSection: some View {
        Section {
            if viewModel.availableGenres.isEmpty {
                filterOptionPlaceholder
            } else {
                triStateHint
                WrappingHStack(items: viewModel.availableGenres) { genre in
                    triStateChip(
                        label: genre,
                        included: localFilters.genres,
                        excluded: localFilters.excludedGenres,
                        onTap: { cycleGenre(genre) }
                    )
                }
            }
        } header: {
            HStack {
                Text("Genres")
                let total = localFilters.genres.count + localFilters.excludedGenres.count
                if total > 0 {
                    Text("(\(total))")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        Section("Format") {
            ForEach(formats, id: \.self) { value in
                Button {
                    localFilters.format = localFilters.format == value ? nil : value
                } label: {
                    HStack {
                        Text(DiscoverOptionLabels.format(value)).foregroundColor(.primary)
                        Spacer()
                        if localFilters.format == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.format == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            ForEach(statuses, id: \.self) { value in
                Button {
                    localFilters.status = localFilters.status == value ? nil : value
                } label: {
                    HStack {
                        Text(DiscoverOptionLabels.status(value)).foregroundColor(.primary)
                        Spacer()
                        if localFilters.status == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.status == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Country

    private var countrySection: some View {
        Section("Country") {
            ForEach(countries, id: \.self) { value in
                Button {
                    localFilters.countryOfOrigin = localFilters.countryOfOrigin == value ? nil : value
                } label: {
                    HStack {
                        Text(DiscoverOptionLabels.country(value)).foregroundColor(.primary)
                        Spacer()
                        if localFilters.countryOfOrigin == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .accessibilityAddTraits(localFilters.countryOfOrigin == value ? .isSelected : [])
            }
        }
    }

    // MARK: - Tags (Tri-state with search)

    private var tagSection: some View {
        Section {
            if viewModel.availableTags.isEmpty {
                filterOptionPlaceholder
            } else {
                // Inline search field for tags
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search tags...", text: $tagSearchText)
                        .disableAutocorrection(true)
                    if !tagSearchText.isEmpty {
                        Button {
                            tagSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)

                if !tagSearchText.isEmpty || !(localFilters.tags.isEmpty && localFilters.excludedTags.isEmpty) {
                    triStateHint
                }

                WrappingHStack(items: filteredTags.map { $0.name }) { tagName in
                    triStateChip(
                        label: tagName,
                        included: localFilters.tags,
                        excluded: localFilters.excludedTags,
                        onTap: { cycleTag(tagName) }
                    )
                }

                if filteredTags.isEmpty && !tagSearchText.isEmpty {
                    Text("No tags matching \"\(tagSearchText)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        } header: {
            HStack {
                Text("Tags")
                let total = localFilters.tags.count + localFilters.excludedTags.count
                if total > 0 {
                    Text("(\(total))")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Tri-State Helpers

    @ViewBuilder
    private var filterOptionPlaceholder: some View {
        switch viewModel.filterLoadState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        case .failed:
            Text("Options unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .loaded:
            Text("No options available")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var triStateHint: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                Text("Include")
            }
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Exclude")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private func triStateChip(label: String, included: [String], excluded: [String], onTap: @escaping () -> Void) -> some View {
        let isIncluded = included.contains(label)
        let isExcluded = excluded.contains(label)

        return Button(action: onTap) {
            HStack(spacing: 4) {
                if isExcluded {
                    Image(systemName: "minus")
                        .font(.caption2.weight(.bold))
                }
                Text(label)
                    .strikethrough(isExcluded)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(chipBackground(included: isIncluded, excluded: isExcluded))
            .foregroundColor(chipForeground(included: isIncluded, excluded: isExcluded))
            .cornerRadius(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chipBackground(included: Bool, excluded: Bool) -> Color {
        if included { return Color.accentColor }
        if excluded { return Color.red }
        return Color(.tertiarySystemFill)
    }

    private func chipForeground(included: Bool, excluded: Bool) -> Color {
        if included { return .itoOnAccent }
        if excluded { return .white }
        return .primary
    }

    private func cycleGenre(_ item: String) {
        if localFilters.genres.contains(item) {
            localFilters.genres.removeAll { $0 == item }
            localFilters.excludedGenres.append(item)
        } else if localFilters.excludedGenres.contains(item) {
            localFilters.excludedGenres.removeAll { $0 == item }
        } else {
            localFilters.genres.append(item)
        }
    }

    private func cycleTag(_ item: String) {
        if localFilters.tags.contains(item) {
            localFilters.tags.removeAll { $0 == item }
            localFilters.excludedTags.append(item)
        } else if localFilters.excludedTags.contains(item) {
            localFilters.excludedTags.removeAll { $0 == item }
        } else {
            localFilters.tags.append(item)
        }
    }
}

// MARK: - Option labels

/// Display names for AniList option values. The values are API data and are sent as they are;
/// only the labels people see are copy. A value without a label shows its own words.
enum DiscoverOptionLabels {
    static func format(_ value: String) -> String {
        switch value {
        case "TV": return String(localized: "TV", comment: "Anime format: TV series")
        case "TV_SHORT": return String(localized: "TV Short", comment: "Anime format: short TV series")
        case "MOVIE": return String(localized: "Movie", comment: "Anime format: movie")
        case "SPECIAL": return String(localized: "Special", comment: "Anime format: special episode or release")
        case "OVA": return String(localized: "OVA", comment: "Anime format: original video animation")
        case "ONA": return String(localized: "ONA", comment: "Anime format: original net animation")
        case "MUSIC": return String(localized: "Music", comment: "Anime format: music video")
        case "MANGA": return String(localized: "Manga", comment: "Manga format")
        case "ONE_SHOT": return String(localized: "One Shot", comment: "Manga format: single chapter")
        case "NOVEL": return String(localized: "Novel", comment: "Manga format: light novel")
        default: return words(value)
        }
    }

    static func status(_ value: String) -> String {
        switch value {
        case "RELEASING": return String(localized: "Releasing", comment: "Series status: still airing or publishing")
        case "FINISHED": return String(localized: "Finished", comment: "Series status: complete")
        case "NOT_YET_RELEASED": return String(localized: "Upcoming", comment: "Series status: not released yet")
        case "CANCELLED": return String(localized: "Cancelled", comment: "Series status")
        case "HIATUS": return String(localized: "Hiatus", comment: "Series status: paused")
        default: return words(value)
        }
    }

    static func country(_ value: String) -> String {
        switch value {
        case "JP": return String(localized: "Japan", comment: "Country of origin")
        case "KR": return String(localized: "South Korea", comment: "Country of origin")
        case "CN": return String(localized: "China", comment: "Country of origin")
        case "TW": return String(localized: "Taiwan", comment: "Country of origin")
        default: return words(value)
        }
    }

    static func season(_ value: String) -> String {
        switch value {
        case "WINTER": return String(localized: "Winter", comment: "Anime season")
        case "SPRING": return String(localized: "Spring", comment: "Anime season")
        case "SUMMER": return String(localized: "Summer", comment: "Anime season")
        case "FALL": return String(localized: "Fall", comment: "Anime season: autumn")
        default: return words(value)
        }
    }

    private static func words(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Wrapping HStack (iOS 15 compatible)

struct WrappingHStack<Item: Hashable, ItemView: View>: View {
    let items: [Item]
    let viewForItem: (Item) -> ItemView
    let spacing: CGFloat

    init(items: [Item], spacing: CGFloat = 8, @ViewBuilder viewForItem: @escaping (Item) -> ItemView) {
        self.items = items
        self.spacing = spacing
        self.viewForItem = viewForItem
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(items, id: \.self) { item in
                    viewForItem(item)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }
}
