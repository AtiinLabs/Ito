import Foundation
import ito_runner

/// Joins a series' listed chapters with the chapters it has saved offline.
///
/// The source's list can drop an upload that was downloaded earlier (a removed or filtered edition). Such a
/// copy stays readable, so it is shown beside the listed chapters. Chapters are matched by exact key only,
/// never by number or scanlator, and a copy the list does not mention is never read as deleted.
nonisolated enum SavedChapterMerge {
    /// The saved chapters whose key `listedKeys` does not contain, as the source returned them when they
    /// were downloaded. A copy whose snapshot cannot be read, or names another key, is left out.
    static func savedOnly(listedKeys: Set<String>, inventory: [DownloadedChapterRecord]) -> [Chapter] {
        let decoder = JSONDecoder()
        return inventory.compactMap { row -> Chapter? in
            guard !listedKeys.contains(row.chapterKey),
                  let chapter = try? decoder.decode(Chapter.self, from: row.chapterSnapshot),
                  chapter.key == row.chapterKey else { return nil }
            return chapter
        }
    }

    /// The listed chapters, then the saved chapters the list does not have. A list with nothing to add is
    /// returned as it is, including nil.
    static func merged(_ listed: [Chapter]?, inventory: [DownloadedChapterRecord]) -> [Chapter]? {
        let extra = savedOnly(listedKeys: Set((listed ?? []).map(\.key)), inventory: inventory)
        guard !extra.isEmpty else { return listed }
        return (listed ?? []) + extra
    }
}
