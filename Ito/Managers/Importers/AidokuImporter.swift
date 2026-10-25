import Foundation
import ito_runner
// MARK: - Aidoku Schemas
private struct AidokuBackup: Decodable {
    var library: [AidokuLibraryManga]?
    var history: [AidokuHistory]?
    var manga: [AidokuManga]?
    var categories: [AidokuCategory]?
    var date: Date
}

private struct AidokuLibraryManga: Decodable {
    var mangaId: String
    var sourceId: String
    var lastOpened: Date
    var lastUpdated: Date
    var dateAdded: Date
    var categories: [String]?
}

private struct AidokuManga: Decodable {
    var id: String
    var sourceId: String
    var title: String
    var author: String?
    var artist: String?
    var desc: String?
    var tags: [String]?
    var cover: String?
    var url: String?
    var status: Int
    var nsfw: Int
    var viewer: Int
}

private struct AidokuCategory: Decodable {
    var title: String?
    var sort: Int?

    enum CodingKeys: String, CodingKey {
        case title, sort
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(), let str = try? singleValue.decode(String.self) {
            title = str
            sort = 0
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        sort = try container.decodeIfPresent(Int.self, forKey: .sort)
    }
}

private struct AidokuHistory: Decodable {
    var dateRead: Date
    var sourceId: String
    var chapterId: String
    var mangaId: String
    var progress: Int?
    var total: Int?
    var completed: Bool
}

public struct AidokuImporter: BackupImporter {
    private let resolver: PluginResolver

    @MainActor
    public init(resolver: PluginResolver) {
        self.resolver = resolver
    }
    public func canHandle(url: URL) -> Bool {
        return url.pathExtension.lowercased() == "aib" || url.pathExtension.lowercased() == "json"
    }

    public func parse(url: URL) async throws -> ImportedBackup {
        guard let rawData = try? Data(contentsOf: url) else {
            throw URLError(.cannotOpenFile)
        }

        var backup: AidokuBackup

        if let bplist = try? PropertyListDecoder().decode(AidokuBackup.self, from: rawData) {
            backup = bplist
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            backup = try decoder.decode(AidokuBackup.self, from: rawData)
        }

        var importedCategories: [LibraryCategory] = []
        var importedItems: [LibraryItem] = []
        var importedLinks: [ItemCategoryLink] = []
        var importedHistory: [ReadingHistoryRecord] = []

        // Track resolutions per foreign source for the migration report
        var resolutionCache: [String: PluginResolution] = [:]
        var sourceItemIds: [String: [String]] = [:]

        // 1. Map Categories
        // We track title -> UUID to easily create links
        var categoryHashMap: [String: String] = [:]

        if let backupCats = backup.categories {
            for (idx, aidokuCat) in backupCats.enumerated() {
                guard let title = aidokuCat.title, !title.isEmpty else { continue }
                let newCat = LibraryCategory(
                    id: UUID().uuidString,
                    name: title,
                    sortOrder: aidokuCat.sort ?? idx,
                    isSystemCategory: false,
                    createdAt: backup.date
                )
                importedCategories.append(newCat)
                categoryHashMap[title] = newCat.id
            }
        }

        // Ensure "Uncategorized" exists as fallback? Ito automatically forces System Categories. We rely on the mapper for Uncategorized.

        // 2. Map Manga & Library Links
        if let aidokuLibrary = backup.library, let aidokuMangas = backup.manga {
            for libItem in aidokuLibrary {
                // Find matching manga metadata
                guard let mangaMeta = aidokuMangas.first(where: { $0.id == libItem.mangaId && $0.sourceId == libItem.sourceId }) else { continue }

                // Resolve plugin (cached per source)
                let resolution: PluginResolution
                if let cached = resolutionCache[libItem.sourceId] {
                    resolution = cached
                } else {
                    resolution = resolver.resolve(foreignId: libItem.sourceId)
                    resolutionCache[libItem.sourceId] = resolution
                }
                let resolvedPluginId = resolution.resolvedId
                let globallyUniqueId = libItem.mangaId
                sourceItemIds[libItem.sourceId, default: []].append(globallyUniqueId)

                // Synthesize Manga payload
                let syntheticManga = Manga(
                    key: libItem.mangaId,
                    title: mangaMeta.title,
                    authors: mangaMeta.author != nil ? [mangaMeta.author!] : nil,
                    artist: mangaMeta.artist,
                    description: mangaMeta.desc ?? "",
                    tags: mangaMeta.tags ?? [],
                    cover: mangaMeta.cover ?? "",
                    url: mangaMeta.url ?? "",
                    status: mapAidokuStatus(mangaMeta.status)
                )

                let encoder = JSONEncoder()
                let payloadData = (try? encoder.encode(syntheticManga)) ?? Data()

                let importedLibraryItem = LibraryItem(
                    id: globallyUniqueId,
                    title: mangaMeta.title,
                    coverUrl: mangaMeta.cover,
                    pluginId: resolvedPluginId,
                    isAnime: false,
                    pluginType: .manga,
                    rawPayload: payloadData,
                    anilistId: nil
                )
                importedItems.append(importedLibraryItem)

                // Process Links explicitly for this Manga
                if let catNames = libItem.categories, !catNames.isEmpty {
                    for catName in catNames {
                        if let resolvedCatId = categoryHashMap[catName] {
                            let link = ItemCategoryLink(
                                itemId: importedLibraryItem.id,
                                categoryId: resolvedCatId,
                                addedAt: libItem.dateAdded
                            )
                            importedLinks.append(link)
                        } else {
                            // Synthesize missing categories on the fly
                            let newCat = LibraryCategory(id: UUID().uuidString, name: catName, sortOrder: 99, isSystemCategory: false, createdAt: backup.date)
                            importedCategories.append(newCat)
                            categoryHashMap[catName] = newCat.id

                            let link = ItemCategoryLink(itemId: importedLibraryItem.id, categoryId: newCat.id, addedAt: libItem.dateAdded)
                            importedLinks.append(link)
                        }
                    }
                } else {
                    // Send to Uncategorized System category manually matching UUID?
                    // BackupManager logic handles mapping any missing links automatically! 
                    // Wait, BackupManager relies on 'link.categoryId == backupSystemCatId' mapping.
                    // Let's create a temporary System Category so the BackupManager can identify it!
                    let temporarySystemId = UUID().uuidString
                    if !categoryHashMap.keys.contains("SYSTEM_UNCATEGORIZED") {
                        let sysCat = LibraryCategory(id: temporarySystemId, name: "Uncategorized", sortOrder: -1, isSystemCategory: true, createdAt: backup.date)
                        importedCategories.append(sysCat)
                        categoryHashMap["SYSTEM_UNCATEGORIZED"] = temporarySystemId
                    }

                    let link = ItemCategoryLink(itemId: importedLibraryItem.id, categoryId: categoryHashMap["SYSTEM_UNCATEGORIZED"]!, addedAt: libItem.dateAdded)
                    importedLinks.append(link)
                }
            }
        }

        // 3. Map History
        if let aidokuHistory = backup.history {
            for hist in aidokuHistory {
                let histResolution: PluginResolution
                if let cached = resolutionCache[hist.sourceId] {
                    histResolution = cached
                } else {
                    histResolution = resolver.resolve(foreignId: hist.sourceId)
                    resolutionCache[hist.sourceId] = histResolution
                }
                let resolvedPluginId = histResolution.resolvedId
                let itemGlobalId = "\(resolvedPluginId)_\(hist.mangaId)"

                let record = ReadingHistoryRecord(
                    id: UUID().uuidString,
                    libraryItemId: itemGlobalId,
                    mediaKey: itemGlobalId,
                    title: "Unknown Title", // We recover title asynchronously via DB later or UI
                    coverUrl: nil,
                    pluginId: resolvedPluginId,
                    mediaKind: .manga,
                    chapterKey: hist.chapterId,
                    chapterTitle: "Chapter \(hist.progress ?? 0)",
                    readAt: hist.dateRead
                )
                importedHistory.append(record)
            }
        }

        // Build migration report
        let unresolvedPlugins = resolutionCache.compactMap { foreignId, resolution -> MigrationReport.UnresolvedPlugin? in
            guard resolution.needsAttention else { return nil }
            return MigrationReport.UnresolvedPlugin(
                foreignId: foreignId,
                resolvedId: resolution.resolvedId,
                confidence: resolution.confidence,
                isInstalled: resolution.isInstalled,
                affectedItemIds: sourceItemIds[foreignId] ?? [],
                candidates: resolution.candidates
            )
        }

        let report = MigrationReport(
            unresolvedPlugins: unresolvedPlugins,
            totalItemsImported: importedItems.count,
            totalItemsSkipped: 0
        )

        return ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: backup.date),
            capabilities: [
                BackupCapabilityRecord(
                    component: .libraryCore,
                    representation: libraryRepresentation(
                        categories: importedCategories,
                        items: importedItems,
                        links: importedLinks
                    )
                ),
                BackupCapabilityRecord(
                    component: .readingHistory,
                    representation: importedHistory.isEmpty
                        ? .representedEmpty
                        : .representedNonempty
                )
            ],
            categories: importedCategories,
            items: importedItems,
            links: importedLinks,
            history: importedHistory,
            preferences: [],
            migrationReport: report.hasIssues ? report : nil
        )
    }

    private func libraryRepresentation(
        categories: [LibraryCategory],
        items: [LibraryItem],
        links: [ItemCategoryLink]
    ) -> BackupRepresentation {
        categories.isEmpty && items.isEmpty && links.isEmpty
            ? .representedEmpty
            : .representedNonempty
    }

    private func mapAidokuStatus(_ status: Int) -> Manga.Status {
        switch status {
        case 1: return .Ongoing
        case 2: return .Completed
        case 3: return .Cancelled
        case 4: return .Hiatus
        default: return .Unknown
        }
    }
}
