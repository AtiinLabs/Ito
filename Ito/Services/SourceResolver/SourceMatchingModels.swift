import Foundation
import ito_runner

public enum PluginMediaType: Equatable, Sendable {
    case manga
    case anime
    case novel

    public nonisolated static func == (lhs: PluginMediaType, rhs: PluginMediaType) -> Bool {
        switch (lhs, rhs) {
        case (.manga, .manga), (.anime, .anime), (.novel, .novel): return true
        default: return false
        }
    }

    public var mediaKind: MediaKind {
        switch self {
        case .manga: return .manga
        case .anime: return .anime
        case .novel: return .novel
        }
    }

    public init?(mediaKind: MediaKind) {
        switch mediaKind {
        case .manga: self = .manga
        case .anime: self = .anime
        case .novel: self = .novel
        @unknown default: return nil
        }
    }
}

public enum MatchMethod: Equatable, Sendable {
    case exactPreferred
    case exactAlternative
    case fuzzy
    case none

    public nonisolated static func == (lhs: MatchMethod, rhs: MatchMethod) -> Bool {
        switch (lhs, rhs) {
        case (.exactPreferred, .exactPreferred): return true
        case (.exactAlternative, .exactAlternative): return true
        case (.fuzzy, .fuzzy): return true
        case (.none, .none): return true
        default: return false
        }
    }
}

public enum MatchDecision: Equatable, Sendable {
    case autoConfirm
    case requiresConfirmation
    case discard

    public nonisolated static func == (lhs: MatchDecision, rhs: MatchDecision) -> Bool {
        switch (lhs, rhs) {
        case (.autoConfirm, .autoConfirm): return true
        case (.requiresConfirmation, .requiresConfirmation): return true
        case (.discard, .discard): return true
        default: return false
        }
    }
}

public struct CanonicalTitleInput: Sendable {
    public nonisolated let preferredTitle: String
    public nonisolated let titleEnglish: String?
    public nonisolated let titleRomaji: String?
    public nonisolated let titleNative: String?
    public nonisolated let synonyms: [String]
    public nonisolated let mediaType: PluginMediaType

    public nonisolated init(preferredTitle: String, titleEnglish: String?, titleRomaji: String?, titleNative: String?, synonyms: [String], mediaType: PluginMediaType) {
        self.preferredTitle = preferredTitle
        self.titleEnglish = titleEnglish
        self.titleRomaji = titleRomaji
        self.titleNative = titleNative
        self.synonyms = synonyms
        self.mediaType = mediaType
    }
}

public struct PluginCandidateInput: Sendable {
    public nonisolated let pluginMediaKey: String
    public nonisolated let title: String
    public nonisolated let mediaType: PluginMediaType

    public nonisolated init(pluginMediaKey: String, title: String, mediaType: PluginMediaType) {
        self.pluginMediaKey = pluginMediaKey
        self.title = title
        self.mediaType = mediaType
    }
}

public struct ScoredCandidate: Sendable {
    public nonisolated let candidate: PluginCandidateInput
    public nonisolated let method: MatchMethod
    public nonisolated let score: Double
    public nonisolated let decision: MatchDecision

    public nonisolated init(candidate: PluginCandidateInput, method: MatchMethod, score: Double, decision: MatchDecision) {
        self.candidate = candidate
        self.method = method
        self.score = score
        self.decision = decision
    }
}
