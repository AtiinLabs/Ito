import Foundation
import ito_runner

public struct SourceSearchRequest: Sendable {
    public nonisolated let canonicalProvider: String
    public nonisolated let canonicalMediaId: String
    public nonisolated let mediaType: PluginMediaType
    public nonisolated let preferredTitle: String
    public nonisolated let titleEnglish: String?
    public nonisolated let titleRomaji: String?
    public nonisolated let titleNative: String?
    public nonisolated let synonyms: [String]

    public nonisolated init(canonicalProvider: String, canonicalMediaId: String, mediaType: PluginMediaType, preferredTitle: String, titleEnglish: String?, titleRomaji: String?, titleNative: String?, synonyms: [String]) {
        self.canonicalProvider = canonicalProvider
        self.canonicalMediaId = canonicalMediaId
        self.mediaType = mediaType
        self.preferredTitle = preferredTitle
        self.titleEnglish = titleEnglish
        self.titleRomaji = titleRomaji
        self.titleNative = titleNative
        self.synonyms = synonyms
    }
}

public protocol PluginSearching: Sendable {
    var pluginID: String { get async }
    var pluginVersion: String? { get async }
    var mediaType: PluginMediaType { get async }

    func search(query: String) async throws -> [ResolvedPluginMedia]
}

public struct MatchedSource: Sendable, Equatable {
    public nonisolated let pluginID: String
    public nonisolated let pluginVersion: String?
    public nonisolated let media: ResolvedPluginMedia
    public nonisolated let matchMethod: MatchMethod
    public nonisolated let score: Double
    public nonisolated let decision: MatchDecision

    public nonisolated static func == (lhs: MatchedSource, rhs: MatchedSource) -> Bool {
        lhs.pluginID == rhs.pluginID &&
            lhs.pluginVersion == rhs.pluginVersion &&
            lhs.media.mediaType == rhs.media.mediaType &&
            lhs.media.key() == rhs.media.key() &&
            lhs.matchMethod == rhs.matchMethod &&
            lhs.score == rhs.score &&
            lhs.decision == rhs.decision
    }
}

public struct SourceResolutionResult: Sendable {
    public nonisolated let matches: [MatchedSource]
    public nonisolated let pluginsSearched: Set<String>
    public nonisolated let pluginsSkipped: Set<String>
    public nonisolated let pluginFailures: [String: String]
    public nonisolated let isCancelled: Bool
}

public actor SourceResolver {
    public typealias RejectedMappingProvider = @Sendable (String, String) async -> Bool

    private let plugins: [any PluginSearching]

    public init(plugins: [any PluginSearching]) {
        self.plugins = plugins
    }

    public func resolve(
        request: SourceSearchRequest,
        isRejected: @escaping RejectedMappingProvider = { _, _ in false },
        onYield: @escaping @MainActor @Sendable ([MatchedSource]) async -> Void
    ) async -> SourceResolutionResult {
        var matches: [MatchedSource] = []
        var pluginsSearched = Set<String>()
        var pluginsSkipped = Set<String>()
        var pluginFailures = [String: String]()
        var isCancelled = false

        let input = CanonicalTitleInput(
            preferredTitle: request.preferredTitle,
            titleEnglish: request.titleEnglish,
            titleRomaji: request.titleRomaji,
            titleNative: request.titleNative,
            synonyms: request.synonyms,
            mediaType: request.mediaType
        )

        let queries = Self.buildQueries(for: request)
        guard let primaryQuery = queries.first else {
            return SourceResolutionResult(matches: [], pluginsSearched: [], pluginsSkipped: [], pluginFailures: [:], isCancelled: false)
        }
        let fallbackQuery = queries.dropFirst().first

        await withTaskGroup(of: PluginTaskResult.self) { group in
            var activeCount = 0
            let maxConcurrent = 2
            var pluginIterator = plugins.makeIterator()

            while activeCount < maxConcurrent, let plugin = pluginIterator.next() {
                group.addTask {
                    let pID = await plugin.pluginID
                    if await plugin.mediaType != request.mediaType {
                        return .skipped(pID)
                    }
                    return await self.searchPlugin(plugin: plugin, primaryQuery: primaryQuery, fallbackQuery: fallbackQuery, input: input, isRejected: isRejected)
                }
                activeCount += 1
            }

            while let result = await group.next() {
                activeCount -= 1
                switch result {
                case .success(let pluginMatches, let pluginID):
                    pluginsSearched.insert(pluginID)
                    matches.append(contentsOf: pluginMatches)
                    matches.sort {
                        if $0.score != $1.score { return $0.score > $1.score }
                        let key0 = Self.pluginMediaKey(for: $0.media)
                        let key1 = Self.pluginMediaKey(for: $1.media)
                        if key0 != key1 { return key0 < key1 }
                        return $0.pluginID < $1.pluginID
                    }

                    // partial result streaming
                    let snapshotMatches = matches
                    await onYield(snapshotMatches)

                case .failure(let pluginID, let errorString):
                    pluginFailures[pluginID] = errorString

                case .skipped(let pluginID):
                    pluginsSkipped.insert(pluginID)

                case .cancelled:
                    isCancelled = true
                }

                if Task.isCancelled {
                    isCancelled = true
                } else if !isCancelled {
                    while activeCount < maxConcurrent, let plugin = pluginIterator.next() {
                        group.addTask {
                            let pID = await plugin.pluginID
                            if await plugin.mediaType != request.mediaType {
                                return .skipped(pID)
                            }
                            return await self.searchPlugin(plugin: plugin, primaryQuery: primaryQuery, fallbackQuery: fallbackQuery, input: input, isRejected: isRejected)
                        }
                        activeCount += 1
                    }
                }
            }
        }

        return SourceResolutionResult(
            matches: matches,
            pluginsSearched: pluginsSearched,
            pluginsSkipped: pluginsSkipped,
            pluginFailures: pluginFailures,
            isCancelled: Task.isCancelled || isCancelled
        )
    }

    private func searchPlugin(
        plugin: any PluginSearching,
        primaryQuery: String,
        fallbackQuery: String?,
        input: CanonicalTitleInput,
        isRejected: RejectedMappingProvider
    ) async -> PluginTaskResult {
        if Task.isCancelled { return .cancelled }

        var allCandidates: [ResolvedPluginMedia] = []
        var errorString: String?
        let pID = await plugin.pluginID

        var primaryResults: [ResolvedPluginMedia] = []
        var primaryFailed = false
        do {
            primaryResults = try await plugin.search(query: primaryQuery)
            allCandidates.append(contentsOf: primaryResults)
        } catch is CancellationError {
            return .cancelled
        } catch {
            errorString = String(describing: error)
            primaryFailed = true
        }

        if primaryFailed || Self.needsFallback(results: primaryResults, input: input) {
            if let fallback = fallbackQuery, fallback != primaryQuery {
                if !Task.isCancelled {
                    do {
                        let fallbackResults = try await plugin.search(query: fallback)
                        allCandidates.append(contentsOf: fallbackResults)
                        if !fallbackResults.isEmpty || !primaryFailed {
                            errorString = nil
                        }
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        if allCandidates.isEmpty {
                            errorString = String(describing: error)
                        }
                    }
                }
            }
        }

        if let error = errorString, allCandidates.isEmpty {
            return .failure(pID, error)
        }

        var uniqueCandidates: [String: ResolvedPluginMedia] = [:]
        for c in allCandidates {
            let key = Self.pluginMediaKey(for: c)
            if uniqueCandidates[key] == nil {
                uniqueCandidates[key] = c
            }
        }

        var candidateInputs: [PluginCandidateInput] = []
        for (key, media) in uniqueCandidates {
            let title = Self.pluginMediaTitle(for: media)
            let type = Self.pluginMediaType(for: media)
            if type == input.mediaType {
                candidateInputs.append(PluginCandidateInput(pluginMediaKey: key, title: title, mediaType: type))
            }
        }

        var rejectedKeys = Set<String>()
        for cand in candidateInputs {
            if await isRejected(pID, cand.pluginMediaKey) {
                rejectedKeys.insert(cand.pluginMediaKey)
            }
        }

        let scoredCandidates = SourceMatcher.evaluate(canonical: input, candidates: candidateInputs, rejectedPluginMediaKeys: rejectedKeys)

        let pVersion = await plugin.pluginVersion

        var matchedSources: [MatchedSource] = []
        for scored in scoredCandidates {
            if scored.decision == .discard { continue }

            var finalDecision = scored.decision
            if finalDecision == .autoConfirm && scored.method == .fuzzy {
                finalDecision = .requiresConfirmation
            }

            if let media = uniqueCandidates[scored.candidate.pluginMediaKey] {
                matchedSources.append(MatchedSource(
                    pluginID: pID,
                    pluginVersion: pVersion,
                    media: media,
                    matchMethod: scored.method,
                    score: scored.score,
                    decision: finalDecision
                ))
            }
        }

        matchedSources.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return Self.pluginMediaKey(for: $0.media) < Self.pluginMediaKey(for: $1.media)
        }

        return .success(matchedSources, pID)
    }

    private static func needsFallback(results: [ResolvedPluginMedia], input: CanonicalTitleInput) -> Bool {
        if results.isEmpty { return true }

        var candidateInputs: [PluginCandidateInput] = []
        for media in results {
            let key = Self.pluginMediaKey(for: media)
            let title = Self.pluginMediaTitle(for: media)
            let type = Self.pluginMediaType(for: media)
            if type == input.mediaType {
                candidateInputs.append(PluginCandidateInput(pluginMediaKey: key, title: title, mediaType: type))
            }
        }

        let scored = SourceMatcher.evaluate(canonical: input, candidates: candidateInputs, rejectedPluginMediaKeys: [])

        for s in scored {
            if s.method == .exactPreferred || s.method == .exactAlternative {
                return false
            }
        }

        return true
    }

    private static func buildQueries(for request: SourceSearchRequest) -> [String] {
        var candidates: [String] = []
        candidates.append(request.preferredTitle)
        if let eng = request.titleEnglish { candidates.append(eng) }
        if let romaji = request.titleRomaji { candidates.append(romaji) }
        if let native = request.titleNative { candidates.append(native) }
        candidates.append(contentsOf: request.synonyms)

        var uniqueNorm = Set<String>()
        var queries: [String] = []
        for c in candidates {
            let norm = TitleNormalizer.normalize(c)
            if !norm.isEmpty && !uniqueNorm.contains(norm) {
                uniqueNorm.insert(norm)
                queries.append(c)
            }
        }
        return queries
    }

    private static func pluginMediaKey(for media: ResolvedPluginMedia) -> String {
        media.key()
    }

    private static func pluginMediaTitle(for media: ResolvedPluginMedia) -> String {
        media.title()
    }

    private static func pluginMediaType(for media: ResolvedPluginMedia) -> PluginMediaType {
        media.mediaType
    }

    private enum PluginTaskResult {
        case success([MatchedSource], String)
        case failure(String, String)
        case cancelled
        case skipped(String)
    }
}
