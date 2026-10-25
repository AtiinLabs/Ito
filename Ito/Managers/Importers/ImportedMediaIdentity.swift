import Foundation
import ito_runner

enum ImportedMediaIdentity {
    nonisolated struct Key: Hashable, Sendable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
    }

    nonisolated static func canonicalMediaId(itemId: String, pluginId: String, mediaKind: MediaKind) -> String {
        let scoped = scopedPrefix(pluginId: pluginId, mediaKind: mediaKind)
        if itemId.hasPrefix(scoped) { return String(itemId.dropFirst(scoped.count)) }
        let prefix = "\(pluginId)_"
        guard itemId.hasPrefix(prefix) else { return itemId }
        return String(itemId.dropFirst(prefix.count))
    }

    nonisolated static func key(itemId: String, pluginId: String, mediaKind: MediaKind) -> Key {
        Key(
            pluginId: pluginId,
            canonicalMediaId: canonicalMediaId(itemId: itemId, pluginId: pluginId, mediaKind: mediaKind),
            mediaKind: mediaKind
        )
    }

    /// Keeps the source id's form: a kind-scoped id (which exists only to separate kinds sharing a key) stays
    /// scoped under the new plugin, and every other id takes the `newPluginId_` prefix.
    nonisolated static func destinationId(
        sourceItemId: String,
        oldPluginId: String,
        newPluginId: String,
        mediaKind: MediaKind
    ) -> String {
        let canonicalId = canonicalMediaId(itemId: sourceItemId, pluginId: oldPluginId, mediaKind: mediaKind)
        guard sourceItemId.hasPrefix(scopedPrefix(pluginId: oldPluginId, mediaKind: mediaKind)) else {
            return "\(newPluginId)_\(canonicalId)"
        }
        return scopedPrefix(pluginId: newPluginId, mediaKind: mediaKind) + canonicalId
    }

    private nonisolated static func scopedPrefix(pluginId: String, mediaKind: MediaKind) -> String {
        "\(pluginId)\u{1F}\(mediaKind.rawValue)\u{1F}"
    }

    nonisolated static func historyIdentifiers(
        _ history: ReadingHistoryRecord,
        match sourceItemId: String,
        pluginId: String,
        mediaKind: MediaKind
    ) -> Bool {
        guard history.pluginId == pluginId, history.mediaKind == mediaKind else { return false }
        let sourceCanonicalId = canonicalMediaId(itemId: sourceItemId, pluginId: pluginId, mediaKind: mediaKind)
        return [history.libraryItemId, history.mediaKey].compactMap { $0 }.contains { identifier in
            canonicalMediaId(itemId: identifier, pluginId: pluginId, mediaKind: mediaKind) == sourceCanonicalId
        }
    }

    nonisolated static func uniquelyAssociatedItem(
        for history: ReadingHistoryRecord,
        among items: [LibraryItem]
    ) -> LibraryItem? {
        let matches = items.filter {
            historyIdentifiers(history, match: $0.id, pluginId: $0.pluginId, mediaKind: $0.effectiveType)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
