import SwiftUI

struct DiscoverFilterView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let mediaType: DiscoverMediaType
    let filters: DiscoverFilters
    var onApply: (DiscoverFilters) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var localFilters: DiscoverFilters = DiscoverFilters()
    @State private var tagSearchText = ""

    private var animeFormats: [(String, String)] {
        [("TV", "TV"), ("TV_SHORT", "TV Short"), ("MOVIE", "Movie"),
         ("SPECIAL", "Special"), ("OVA", "OVA"), ("ONA", "ONA"), ("MUSIC", "Music")]
    }

    private var mangaFormats: [(String, String)] {
        [("MANGA", "Manga"), ("ONE_SHOT", "One Shot"), ("NOVEL", "Novel")]
    }

    private var formats: [(String, String)] {
        mediaType == .anime ? animeFormats : mangaFormats
    }

    private let statuses: [(String, String)] = [
        ("RELEASING", "Releasing"), ("FINISHED", "Finished"),
        ("NOT_YET_RELEASED", "Upcoming"), ("CANCELLED", "Cancelled"), ("HIATUS", "Hiatus")
    ]

    private let countries: [(String, String)] = [
        ("JP", "Japan"), ("KR", "South Korea"), ("CN", "China"), ("TW", "Taiwan")
    ]

    private let seasons: [(String, String)] = [
        ("WINTER", "Winter"), ("SPRING", "Spring"), ("SUMMER", "Summer"), ("FALL", "Fall")
    ]

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
                            ForEach(seasons, id: \.0) { value, label in
                                let isSelected = localFilters.season == value
                                Button {
                                    localFilters.season = isSelected ? nil : value
                                } label: {
                                    Text(label)
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
            ForEach(formats, id: \.0) { value, label in
                Button {
                    localFilters.format = localFilters.format == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
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
            ForEach(statuses, id: \.0) { value, label in
                Button {
                    localFilters.status = localFilters.status == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
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
            ForEach(countries, id: \.0) { value, label in
                Button {
                    localFilters.countryOfOrigin = localFilters.countryOfOrigin == value ? nil : value
                } label: {
                    HStack {
                        Text(label).foregroundColor(.primary)
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
