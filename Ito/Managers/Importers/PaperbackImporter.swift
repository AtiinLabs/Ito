import Foundation
import ZIPFoundation
import ito_runner

// MARK: - Paperback Schemas

private struct PBRef: Decodable {
    let type: String
    let id: String
}

private struct PBLibraryManga: Decodable {
    let id: String
    let primarySource: PBRef
    let libraryTabs: [String]?
    let dateBookmarked: Double?
    let lastRead: Double?
    let lastUpdated: Double?
}

private struct PBSourceManga: Decodable {
    let id: String
    let sourceId: String
    let mangaId: String
    let mangaInfo: PBRef
}

private struct PBTagSection: Decodable {
    let id: String
    let label: String
    let tags: [PBTag]
}

private struct PBTag: Decodable {
    let id: String
    let label: String
}

private struct PBMangaInfo: Decodable {
    let id: String
    let titles: [String]?
    let author: String?
    let artist: String?
    let status: String?
    let desc: String?
    let image: String?
    let tags: [PBTagSection]?
}

private struct PBChapter: Decodable {
    let id: String
    let chapterId: String
    let chapNum: Float
    let volume: Float?
    let name: String?
    let langCode: String?
    let time: Double?
    let sourceManga: PBRef
}

private struct PBChapterProgress: Decodable {
    let chapter: PBRef
    let totalPages: Int?
    let lastPage: Int?
    let completed: Bool
    let time: Double?
}

public struct PaperbackImporter: BackupImporter {
    private let resolver: PluginResolver

    @MainActor
    public init(resolver: PluginResolver) {
        self.resolver = resolver
    }

    public func canHandle(url: URL) -> Bool {
        return url.pathExtension.lowercased() == "pas4" || url.pathExtension.lowercased() == "zip"
    }

    // Apple Core Data Epoch (Jan 1 2001) conversion
    private func decodeCocoaTime(_ ts: Double?) -> Date? {
        guard let ts = ts, ts != -63114076800 else { return nil } // -63114076800 is unix epoch treated as never
        return Date(timeIntervalSinceReferenceDate: ts)
    }

    public func parse(url: URL) async throws -> ImportedBackup {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        let archive = try Archive(url: url, accessMode: .read)

        var libraryData = Data()
        var sourceData = Data()
        var mangaData = Data()
        var chapterData = Data()
        var prog1Data = Data()
        var prog2Data = Data()

        for entry in archive {
            let path = entry.path
            var targetData = Data()
            _ = try archive.extract(entry, bufferSize: 4096, skipCRC32: true) { data in
                targetData.append(data)
            }
            if path == "__LIBRARY_MANGA_V4" { libraryData = targetData } else if path == "__SOURCE_MANGA_V4" { sourceData = targetData } else if path == "__MANGA_INFO_V4" { mangaData = targetData } else if path == "__CHAPTER_V4" { chapterData = targetData } else if path == "__CHAPTER_PROGRESS_MARKER_V4-1" { prog1Data = targetData } else if path == "__CHAPTER_PROGRESS_MARKER_V4-2" { prog2Data = targetData }
        }

        // Decode
        let decoder = JSONDecoder()

        let libs = try? decoder.decode([String: PBLibraryManga].self, from: libraryData)
        let sources = try? decoder.decode([String: PBSourceManga].self, from: sourceData)
        let infos = try? decoder.decode([String: PBMangaInfo].self, from: mangaData)
        let chapters = try? decoder.decode([String: PBChapter].self, from: chapterData)

        let p1 = (try? decoder.decode([String: PBChapterProgress].self, from: prog1Data)) ?? [:]
        let p2 = (try? decoder.decode([String: PBChapterProgress].self, from: prog2Data)) ?? [:]
        var progress = p1
        progress.merge(p2) { curr, _ in curr }

        var importedCategories: [LibraryCategory] = []
        var importedItems: [LibraryItem] = []
        var importedLinks: [ItemCategoryLink] = []
        var importedHistory: [ReadingHistoryRecord] = []

        // Track resolutions per foreign source for the migration report
        var resolutionCache: [String: PluginResolution] = [:]
        var sourceItemIds: [String: [String]] = [:]

        var categoryHashMap: [String: String] = [:]

        guard let validLibs = libs, let validSources = sources, let validInfos = infos else {
            throw URLError(.cannotParseResponse)
        }

        for lib in validLibs.values {
            guard let src = validSources[lib.primarySource.id] else { continue }
            guard let info = validInfos[src.mangaInfo.id] else { continue }

            // Resolve plugin (cached per source)
            let resolution: PluginResolution
            if let cached = resolutionCache[src.sourceId] {
                resolution = cached
            } else {
                resolution = resolver.resolve(foreignId: src.sourceId)
                resolutionCache[src.sourceId] = resolution
            }
            let resolvedPluginId = resolution.resolvedId
            let globallyUniqueId = src.mangaId
            sourceItemIds[src.sourceId, default: []].append(globallyUniqueId)

            // Map status
            var targetStatus: Manga.Status = .Unknown
            if let statStr = info.status?.lowercased() {
                if statStr == "ongoing" { targetStatus = .Ongoing } else if statStr == "completed" { targetStatus = .Completed } else if statStr == "cancelled" || statStr == "canceled" { targetStatus = .Cancelled } else if statStr == "hiatus" { targetStatus = .Hiatus }
            }

            // Extract flat tags
            var flatTags: [String] = []
            if let tagSections = info.tags {
                for section in tagSections {
                    for t in section.tags {
                        flatTags.append(t.label)
                    }
                }
            }

            let syntheticManga = Manga(
                key: src.mangaId,
                title: info.titles?.first ?? "Unknown Title",
                authors: info.author != nil ? [info.author!] : nil,
                artist: info.artist,
                description: info.desc ?? "",
                tags: flatTags.isEmpty ? nil : flatTags,
                cover: info.image ?? "",
                url: "", // Not strictly provided by paperback at root
                status: targetStatus
            )

            let encoder = JSONEncoder()
            let payloadData = (try? encoder.encode(syntheticManga)) ?? Data()

            var importedLibraryItem = LibraryItem(
                id: globallyUniqueId,
                title: info.titles?.first ?? "Unknown Title",
                coverUrl: info.image,
                pluginId: resolvedPluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: payloadData,
                anilistId: nil
            )

            if let checkTs = lib.dateBookmarked { importedLibraryItem.lastCheckedAt = decodeCocoaTime(checkTs) }
            if let updateTs = lib.lastUpdated { importedLibraryItem.lastUpdatedAt = decodeCocoaTime(updateTs) }

            importedItems.append(importedLibraryItem)

            // Categories mapping
            var assignedCategoryIds: [String] = []
            if let tabs = lib.libraryTabs, !tabs.isEmpty {
                for tab in tabs {
                    if let mappedId = categoryHashMap[tab] {
                        assignedCategoryIds.append(mappedId)
                    } else {
                        let newCatId = UUID().uuidString
                        let newCat = LibraryCategory(id: newCatId, name: tab, sortOrder: 99, isSystemCategory: false, createdAt: decodeCocoaTime(lib.dateBookmarked) ?? Date())
                        importedCategories.append(newCat)
                        categoryHashMap[tab] = newCatId
                        assignedCategoryIds.append(newCatId)
                    }
                }
            } else {
                // Synthesize missing categories manually if empty (to avoid them becoming floating objects)
                let temporarySystemId = UUID().uuidString
                if !categoryHashMap.keys.contains("SYSTEM_UNCATEGORIZED") {
                    let sysCat = LibraryCategory(id: temporarySystemId, name: "Uncategorized", sortOrder: -1, isSystemCategory: true, createdAt: Date())
                    importedCategories.append(sysCat)
                    categoryHashMap["SYSTEM_UNCATEGORIZED"] = temporarySystemId
                }
                assignedCategoryIds.append(categoryHashMap["SYSTEM_UNCATEGORIZED"]!)
            }

            for catId in assignedCategoryIds {
                let link = ItemCategoryLink(
                    itemId: globallyUniqueId,
                    categoryId: catId,
                    addedAt: decodeCocoaTime(lib.dateBookmarked) ?? Date()
                )
                importedLinks.append(link)
            }
        }

        // Map History
        if let chaptersDict = chapters {
            for chap in chaptersDict.values {
                guard let prog = progress[chap.id] else { continue }
                if !prog.completed && (prog.lastPage ?? 0) <= 0 { continue } // Skip completely unread

                guard let src = validSources[chap.sourceManga.id] else { continue }

                let histResolution: PluginResolution
                if let cached = resolutionCache[src.sourceId] {
                    histResolution = cached
                } else {
                    histResolution = resolver.resolve(foreignId: src.sourceId)
                    resolutionCache[src.sourceId] = histResolution
                }
                let resolvedPluginId = histResolution.resolvedId
                let itemGlobalId = "\(resolvedPluginId)_\(src.mangaId)"

                let record = ReadingHistoryRecord(
                    id: UUID().uuidString,
                    libraryItemId: itemGlobalId,
                    mediaKey: itemGlobalId,
                    title: "Unknown Title", // Recovered natively by UI later
                    coverUrl: nil,
                    pluginId: resolvedPluginId,
                    mediaKind: .manga,
                    chapterKey: chap.chapterId,
                    chapterTitle: chap.name ?? "Chapter \(chap.chapNum)",
                    readAt: decodeCocoaTime(prog.time) ?? Date()
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
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Date()),
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
}
