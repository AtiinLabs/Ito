import Foundation
import ito_runner

private enum MediaDetailViewModelError: Error {
    case unsupportedMediaType
}

/// What the series screen hands to the Library and to Discord. Kept apart from the screen's own state.
extension MediaDetailViewModel {
    func save(_ sourceMedia: M) async throws -> String {
        if let manga = sourceMedia as? Manga {
            return try await dependencies.library.saveManga(manga, pluginID: pluginID)
        } else if let anime = sourceMedia as? Anime {
            return try await dependencies.library.saveAnime(anime, pluginID: pluginID)
        } else if let novel = sourceMedia as? Novel {
            return try await dependencies.library.saveNovel(novel, pluginID: pluginID)
        }
        throw MediaDetailViewModelError.unsupportedMediaType
    }

    func publishDiscordActivity() {
        let trackerState = dependencies.tracker.state(for: mediaIdentity, isAnime: media is Anime)
        let detailsURL = trackerState.anilistID.map {
            "https://anilist.co/\(media is Anime ? "anime" : "manga")/\($0)"
        }
        let pluginName = dependencies.pluginMetadata.displayName(for: pluginID)
            ?? String(localized: "Unknown Plugin")
        dependencies.discord.present(
            MediaDetailDiscordActivity(
                details: media.title,
                state: String(localized: "Viewing Details", comment: "Discord status"),
                activityType: 3,
                detailsURL: detailsURL,
                largeImageText: String(localized: "Browsing at \(pluginName)", comment: "Discord status: source name"),
                imageURL: media.cover,
                resetTimer: true
            )
        )
    }
}
