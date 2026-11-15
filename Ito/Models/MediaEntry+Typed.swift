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

    /// This entry for one reading, with `chapter` as the descriptor its exact key names. Only that chapter is
    /// replaced. A key the list does not hold, or one a different key could be mistaken for by Unicode
    /// equivalence, leaves `chapter` alone in the list, so no neighbor or order is claimed for it.
    func pinning(_ chapter: Chapter) -> MediaEntry {
        func pinned(_ list: [Chapter]?) -> [Chapter] {
            guard let list else { return [chapter] }
            var replaced = false
            var result = list
            for index in list.indices {
                let key = list[index].key
                if key.utf8.elementsEqual(chapter.key.utf8) {
                    result[index] = chapter
                    replaced = true
                } else if key == chapter.key {
                    return [chapter]
                }
            }
            return replaced ? result : [chapter]
        }
        switch self {
        case .manga(var manga):
            manga.chapters = pinned(manga.chapters)
            return .manga(manga)
        case .novel(var novel):
            novel.chapters = pinned(novel.chapters)
            return .novel(novel)
        case .anime:
            return self
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
