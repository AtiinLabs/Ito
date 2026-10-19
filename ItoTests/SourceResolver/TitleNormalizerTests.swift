import Testing
@testable import Ito

struct TitleNormalizerTests {
    @Test func caseDifferences() async {
        #expect(TitleNormalizer.normalize("ONE PIECE") == TitleNormalizer.normalize("one piece"))
        #expect(TitleNormalizer.normalize("One Piece") == "one piece")
    }

    @Test func diacritics() async {
        #expect(TitleNormalizer.normalize("Pokémon") == TitleNormalizer.normalize("Pokemon"))
        #expect(TitleNormalizer.normalize("café") == "cafe")
    }

    @Test func apostrophes() async {
        #expect(TitleNormalizer.normalize("Bob's") == "bob s")
    }

    @Test func hyphens() async {
        #expect(TitleNormalizer.normalize("Spider-Man") == "spider man")
    }

    @Test func colons() async {
        #expect(TitleNormalizer.normalize("Star Wars: A New Hope") == "star wars a new hope")
    }

    @Test func multipleSpaces() async {
        #expect(TitleNormalizer.normalize("One   Piece") == "one piece")
    }

    @Test func fullWidthCompatibility() async {
        #expect(TitleNormalizer.normalize("ＯＮＥ　ＰＩＥＣＥ") == "one piece")
    }

    @Test func japanesePunctuation() async {
        #expect(TitleNormalizer.normalize("【推しの子】") == "推しの子")
    }

    @Test func emptyStrings() async {
        #expect(TitleNormalizer.normalize("").isEmpty)
    }

    @Test func punctuationOnly() async {
        #expect(TitleNormalizer.normalize("---").isEmpty)
        #expect(TitleNormalizer.normalize("!?").isEmpty)
    }

    @Test func tokenBoundaryPreservation() async {
        #expect(TitleNormalizer.normalize("Sword Art Online") == "sword art online")
    }
}
