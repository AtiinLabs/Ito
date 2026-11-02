import anilist

/// The pinned SDK's Viewer selection does not expose mediaListOptions.
struct AniListScoreFormatQuery: GraphQLRequest {
    struct Response: Decodable, Sendable {
        struct Viewer: Decodable, Sendable {
            let name: String?
            struct MediaListOptions: Decodable, Sendable {
                let scoreFormat: String?
            }
            let mediaListOptions: MediaListOptions?
        }
        let viewer: Viewer?

        enum CodingKeys: String, CodingKey {
            case viewer = "Viewer"
        }
    }

    var query: String {
        "query { Viewer { name mediaListOptions { scoreFormat } } }"
    }
}

/// Requests the rating in explicit native units, never relying on server defaults.
struct AniListNativeScoreEntryQuery: GraphQLRequest {
    typealias Response = AniListQueries.MediaListEntryQuery.Response

    struct Variables: Encodable, Sendable {
        let userName: String
        let mediaId: Int
        let format: TrackerScoreFormat
    }

    let variables: Variables?

    var query: String {
        """
        query ($userName: String, $mediaId: Int, $format: ScoreFormat) {
          MediaList(userName: $userName, mediaId: $mediaId) {
            id mediaId status progress score(format: $format)
            startedAt { year month day }
            completedAt { year month day }
          }
        }
        """
    }
}
