import Foundation
import ito_runner

/// Source-local catalog keys can be shared by different media kinds.
nonisolated struct MediaEntryIdentity: Hashable {
    let kind: MediaKind
    let key: String
}

nonisolated extension MediaEntry {
    var catalogIdentity: MediaEntryIdentity { MediaEntryIdentity(kind: kind, key: key) }

    var manga: Manga? {
        if case .manga(let manga) = self { return manga }
        return nil
    }

    var anime: Anime? {
        if case .anime(let anime) = self { return anime }
        return nil
    }

    var novel: Novel? {
        if case .novel(let novel) = self { return novel }
        return nil
    }

    var title: String {
        switch self {
        case .manga(let manga): return manga.title
        case .anime(let anime): return anime.title
        case .novel(let novel): return novel.title
        }
    }

    var cover: String? {
        switch self {
        case .manga(let manga): return manga.cover
        case .anime(let anime): return anime.cover
        case .novel(let novel): return novel.cover
        }
    }

    /// Its chapters: a manga's or a novel's. Anime has episodes instead.
    var chapters: [Chapter]? {
        switch self {
        case .manga(let manga): return manga.chapters
        case .novel(let novel): return novel.chapters
        case .anime: return nil
        }
    }

    /// The entry as the kind a caller asked the plugin for. The runner already refuses an update
    /// of another kind, so a mismatch is a plugin failure, never shown.
    func expecting<Value>(_ kind: KeyPath<MediaEntry, Value?>) throws -> Value {
        guard let value = self[keyPath: kind] else {
            throw ItoError.pluginFailed(function: "get_media_update", reason: nil)
        }
        return value
    }
}
