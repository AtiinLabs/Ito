import Foundation
import ito_runner

public enum ResolvedPluginMedia: Codable, Sendable {
    case manga(Manga)
    case anime(Anime)
    case novel(Novel)

    private enum CodingKeys: String, CodingKey {
        case type
        case manga
        case anime
        case novel
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "manga":
            let value = try container.decode(Manga.self, forKey: .manga)
            self = .manga(value)
        case "anime":
            let value = try container.decode(Anime.self, forKey: .anime)
            self = .anime(value)
        case "novel":
            let value = try container.decode(Novel.self, forKey: .novel)
            self = .novel(value)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid media type: \(type)")
        }
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manga(let value):
            try container.encode("manga", forKey: .type)
            try container.encode(value, forKey: .manga)
        case .anime(let value):
            try container.encode("anime", forKey: .type)
            try container.encode(value, forKey: .anime)
        case .novel(let value):
            try container.encode("novel", forKey: .type)
            try container.encode(value, forKey: .novel)
        }
    }

    public nonisolated func key() -> String {
        switch self {
        case .manga(let manga):
            return manga.key
        case .anime(let anime):
            return anime.key
        case .novel(let novel):
            return novel.key
        }
    }

    public nonisolated func title() -> String {
        switch self {
        case .manga(let manga):
            return manga.title
        case .anime(let anime):
            return anime.title
        case .novel(let novel):
            return novel.title
        }
    }

    public nonisolated func cover() -> String? {
        switch self {
        case .manga(let manga):
            return manga.cover
        case .anime(let anime):
            return anime.cover
        case .novel(let novel):
            return novel.cover
        }
    }

    public nonisolated var mediaType: PluginMediaType {
        switch self {
        case .manga:
            return .manga
        case .anime:
            return .anime
        case .novel:
            return .novel
        }
    }
}

public struct SourceMediaSnapshot: Codable, Sendable {
    public nonisolated let version: Int
    public nonisolated let payload: ResolvedPluginMedia

    private enum CodingKeys: String, CodingKey {
        case version
        case payload
    }

    public nonisolated init(version: Int, payload: ResolvedPluginMedia) {
        self.version = version
        self.payload = payload
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.payload = try container.decode(ResolvedPluginMedia.self, forKey: .payload)
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(payload, forKey: .payload)
    }
}
