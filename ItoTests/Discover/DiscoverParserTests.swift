import Testing
import anilist
@testable import Ito

@MainActor
struct DiscoverParserTests {
    @Test func mapsCompleteMedia() {
        let media = DiscoverMedia(aniList: Media(
            id: 1,
            title: MediaTitle(romaji: "Romaji Title", english: "English Title", native: "Native Title"),
            type: .manga,
            format: .oneShot,
            status: .releasing,
            description: "Line one<br>Line &amp; two",
            season: .fall,
            coverImage: MediaCoverImage(extraLarge: "https://img/xl.jpg", large: "https://img/l.jpg"),
            synonyms: ["Syn 1", "Syn 2"]
        ))

        #expect(media.titleEnglish == "English Title")
        #expect(media.titleRomaji == "Romaji Title")
        #expect(media.titleNative == "Native Title")
        #expect(media.title == "English Title")
        #expect(media.synonyms == ["Syn 1", "Syn 2"])
        #expect(media.coverImage == "https://img/xl.jpg")
        #expect(media.type == "MANGA")
        #expect(media.format == "ONE_SHOT")
        #expect(media.status == "RELEASING")
        #expect(media.season == "FALL")
        #expect(media.description == "Line one<br>Line &amp; two")
        #expect(media.cleanDescription == "Line oneLine & two")
        #expect(media.recommendations == nil)
    }

    @Test func fallsBackThroughTitlesAndCovers() {
        let romajiOnly = DiscoverMedia(aniList: Media(
            id: 2,
            title: MediaTitle(romaji: "Romaji", native: "Native"),
            coverImage: MediaCoverImage(large: "https://img/l.jpg")
        ))
        #expect(romajiOnly.titleEnglish == nil)
        #expect(romajiOnly.title == "Romaji")
        #expect(romajiOnly.coverImage == "https://img/l.jpg")
        #expect(romajiOnly.synonyms.isEmpty)
        #expect(romajiOnly.type == "ANIME")

        let nativeOnly = DiscoverMedia(aniList: Media(id: 3, title: MediaTitle(native: "Native")))
        #expect(nativeOnly.title == "Native")

        let untitled = DiscoverMedia(aniList: Media(id: 4))
        #expect(untitled.title == "Unknown")
    }

    @Test func mapsRecommendationsAndSkipsMissingMedia() throws {
        let media = DiscoverMedia(aniList: Media(
            id: 1,
            title: MediaTitle(english: "Main English"),
            recommendations: MediaRecommendationConnection(nodes: [
                MediaRecommendation(id: 10, mediaRecommendation: Media(
                    id: 2,
                    title: MediaTitle(romaji: "Rec Romaji", english: "Rec English", native: "Rec Native"),
                    synonyms: ["Rec Syn"]
                )),
                MediaRecommendation(id: 11, mediaRecommendation: nil)
            ])
        ))

        let recommendations = try #require(media.recommendations)
        #expect(recommendations.count == 1)

        let rec = recommendations[0]
        #expect(rec.id == 2)
        #expect(rec.titleEnglish == "Rec English")
        #expect(rec.titleRomaji == "Rec Romaji")
        #expect(rec.titleNative == "Rec Native")
        #expect(rec.title == "Rec English")
        #expect(rec.synonyms == ["Rec Syn"])
    }
}
