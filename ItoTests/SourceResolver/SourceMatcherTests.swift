import Testing
@testable import Ito

struct SourceMatcherTests {

    func makeCanonical(preferred: String = "One Piece", english: String? = nil, romaji: String? = nil, native: String? = nil, synonyms: [String] = [], mediaType: PluginMediaType = .manga) -> CanonicalTitleInput {
        return CanonicalTitleInput(preferredTitle: preferred, titleEnglish: english, titleRomaji: romaji, titleNative: native, synonyms: synonyms, mediaType: mediaType)
    }

    func makeCandidate(key: String = "1", title: String = "One Piece", mediaType: PluginMediaType = .manga) -> PluginCandidateInput {
        return PluginCandidateInput(pluginMediaKey: key, title: title, mediaType: mediaType)
    }

    @Test func uniquePreferredExactMatchAutoConfirms() async {
        let canonical = makeCanonical()
        let candidate = makeCandidate()
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])
        #expect(result.count == 1)
        #expect(result[0].decision == .autoConfirm)
    }

    @Test func uniqueAlternativeExactMatchAutoConfirms() async {
        let canonical = makeCanonical(preferred: "Boku no Hero", english: "My Hero Academia")
        let candidate = makeCandidate(title: "My Hero Academia")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])
        #expect(result.count == 1)
        #expect(result[0].decision == .autoConfirm)
        #expect(result[0].method == .exactAlternative)
    }

    @Test func twoIdenticalExactCandidatesRequireConfirmation() async {
        let canonical = makeCanonical()
        let cand1 = makeCandidate(key: "1", title: "One Piece")
        let cand2 = makeCandidate(key: "2", title: "One Piece")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [cand1, cand2], rejectedPluginMediaKeys: [])

        #expect(result.count == 2)
        #expect(result[0].decision == .requiresConfirmation)
        #expect(result[1].decision == .requiresConfirmation)
    }

    @Test func exactCandidateWithInsufficientMarginRequiresConfirmation() async {
        let canonical = makeCanonical(preferred: "One Piece")
        let cand1 = makeCandidate(key: "1", title: "One Piece")
        let cand2 = makeCandidate(key: "2", title: "One Piec")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [cand1, cand2], rejectedPluginMediaKeys: [])

        #expect(result[0].decision == .requiresConfirmation)
    }

    @Test func rejectedExactCandidateDoesNotAutoConfirm() async {
        let canonical = makeCanonical()
        let candidate = makeCandidate()
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: ["1"])
        #expect(result.count == 1)
        #expect(result[0].decision == .requiresConfirmation)
    }

    @Test func fuzzyCandidateAboveThresholdRequiresConfirmation() async {
        let canonical = makeCanonical(preferred: "Jujutsu Kaisen")
        let candidate = makeCandidate(title: "Jujutsu Kaisenn")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])

        #expect(result[0].score >= 0.80)
        #expect(result[0].decision == .requiresConfirmation)
        #expect(result[0].method == .fuzzy)
    }

    @Test func fuzzyCandidateBelowThresholdIsDiscarded() async {
        let canonical = makeCanonical(preferred: "Naruto")
        let candidate = makeCandidate(title: "Bleach")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])

        #expect(result[0].decision == .discard)
    }

    @Test func mediaTypeMismatchIsDiscarded() async {
        let canonical = makeCanonical(preferred: "Naruto", mediaType: .anime)
        let candidate = makeCandidate(title: "Naruto", mediaType: .manga)
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])
        #expect(result[0].decision == .discard)
    }

    @Test func novelMatchingAndMismatch() async {
        let canonicalNovel = makeCanonical(preferred: "Overlord", mediaType: .novel)
        let candidateNovel = makeCandidate(title: "Overlord", mediaType: .novel)
        let candidateManga = makeCandidate(title: "Overlord", mediaType: .manga)

        let result = SourceMatcher.evaluate(
            canonical: canonicalNovel,
            candidates: [candidateNovel, candidateManga],
            rejectedPluginMediaKeys: []
        )
        #expect(result[0].candidate.mediaType == .novel)
        #expect(result[0].decision == .autoConfirm)
        #expect(result[1].candidate.mediaType == .manga)
        #expect(result[1].decision == .discard)
    }

    @Test func emptyNormalizedTitlesNeverMatch() async {
        let canonical = makeCanonical(preferred: "---")
        let candidate = makeCandidate(title: "...")
        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [candidate], rejectedPluginMediaKeys: [])
        #expect(result[0].decision == .discard)
    }

    @Test func stableDeterministicOrdering() async {
        let canonical = makeCanonical(preferred: "Naruto")
        let cand1 = makeCandidate(key: "A", title: "Naruto Shippuden")
        let cand2 = makeCandidate(key: "B", title: "Naruto Shippuden")

        let result = SourceMatcher.evaluate(canonical: canonical, candidates: [cand2, cand1], rejectedPluginMediaKeys: [])

        #expect(result[0].candidate.pluginMediaKey == "A")
        #expect(result[1].candidate.pluginMediaKey == "B")
    }
}
