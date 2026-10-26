import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import ito_runner
@testable import Ito

@MainActor
struct MangaWordLookupTests {
    private let page = MangaWordLookupTests.blankPage()
    private let hello = RecognizedWord(text: "HELLO", bounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
    private let running = RecognizedWord(text: "RUNNING!", bounds: CGRect(x: 0.4, y: 0.1, width: 0.3, height: 0.05))

    @Test func readingOutlinesTheWordsOfThatPageOnly() async {
        let recognizer = PageTextRecognizerFake()
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: DictionaryFake())

        lookup.begin(pageID: "a", image: page, orientation: .up)
        #expect(lookup.phase(on: "a") == .reading)
        #expect(lookup.phase(on: "b") == nil)

        await recognizer.request(1).complete(.success([hello, running]))
        await lookup.waitForReadsForTesting()

        #expect(lookup.phase(on: "a") == .words([hello, running]))
        #expect(lookup.phase(on: "b") == nil)
    }

    @Test func aPageWithoutTextOrThatCannotBeReadSaysSo() async {
        let recognizer = PageTextRecognizerFake()
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: DictionaryFake())

        lookup.begin(pageID: "a", image: page, orientation: .up)
        await recognizer.request(1).complete(.success([]))
        await lookup.waitForReadsForTesting()
        #expect(lookup.phase(on: "a") == .noWords)

        lookup.begin(pageID: "a", image: page, orientation: .up)
        await recognizer.request(2).complete(.failure(MangaReaderTestError.expected))
        await lookup.waitForReadsForTesting()
        #expect(lookup.phase(on: "a") == .failed)
    }

    @Test func aLaterLongPressReplacesAnEarlierReadAndItsLateResultIsIgnored() async {
        let recognizer = PageTextRecognizerFake(honorsCancellation: false)
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: DictionaryFake())

        lookup.begin(pageID: "a", image: page, orientation: .up)
        let first = await recognizer.request(1)
        lookup.begin(pageID: "b", image: page, orientation: .up)
        await recognizer.request(2).complete(.success([running]))
        first.complete(.success([hello]))
        await lookup.waitForReadsForTesting()

        #expect(lookup.phase(on: "a") == nil)
        #expect(lookup.phase(on: "b") == .words([running]))
    }

    @Test func endingStopsTheReadAndRemovesTheOutlines() async {
        let recognizer = PageTextRecognizerFake()
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: DictionaryFake())

        lookup.begin(pageID: "a", image: page, orientation: .up)
        let read = await recognizer.request(1)
        lookup.end()
        // The cancelled read has already finished; a result now changes nothing.
        read.complete(.success([hello]))
        await lookup.waitForReadsForTesting()

        #expect(lookup.session == nil)
    }

    @Test func tappingAWordOpensTheDictionaryAtTheFormItDefines() async {
        let recognizer = PageTextRecognizerFake()
        let dictionary = DictionaryFake()
        dictionary.definedTerms = ["Tokyo"]
        let tokyo = RecognizedWord(text: "Tokyo,", bounds: CGRect(x: 0.4, y: 0.1, width: 0.3, height: 0.05))
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: dictionary)
        lookup.begin(pageID: "a", image: page, orientation: .up)
        await recognizer.request(1).complete(.success([hello, tokyo]))
        await lookup.waitForReadsForTesting()

        lookup.lookUp(tokyo)
        #expect(lookup.lookup?.term == "Tokyo")

        // Closing the dictionary keeps the page outlined for the next word.
        lookup.finishLookup()
        #expect(lookup.lookup == nil)
        #expect(lookup.phase(on: "a") == .words([hello, tokyo]))

        // A word no dictionary defines still opens, at its plain form.
        lookup.lookUp(hello)
        #expect(lookup.lookup?.term == "hello")
    }

    @Test func onlyAnOutlinedWordCanBeLookedUp() async {
        let recognizer = PageTextRecognizerFake()
        let lookup = MangaWordLookupViewModel(recognizer: recognizer, dictionary: DictionaryFake())

        lookup.lookUp(hello)
        #expect(lookup.lookup == nil)

        lookup.begin(pageID: "a", image: page, orientation: .up)
        lookup.lookUp(hello)
        #expect(lookup.lookup == nil)

        await recognizer.request(1).complete(.success([running]))
        await lookup.waitForReadsForTesting()
        lookup.lookUp(hello)
        #expect(lookup.lookup == nil)
    }

    @Test(arguments: [
        ("“HELLO,”", ["hello", "HELLO"]),
        ("WIZARD’S", ["wizard", "WIZARD"]),
        ("Tokyo", ["tokyo", "Tokyo"]),
        ("...!", [])
    ])
    func printedWordsBecomeLookupTerms(printed: String, expected: [String]) {
        #expect(DictionaryTerm.candidates(for: printed) == expected)
    }

    @Test func theFirstDefinedTermWinsAndTheLowercaseFormIsTheFallback() {
        #expect(DictionaryTerm.resolve("Tokyo") { $0 == "Tokyo" } == "Tokyo")
        #expect(DictionaryTerm.resolve("Tokyo") { _ in true } == "tokyo")
        #expect(DictionaryTerm.resolve("Tokyo") { _ in false } == "tokyo")
        #expect(DictionaryTerm.resolve("?!") { _ in true } == nil)
    }

    @Test func visionReadsEnglishWordsWithBoxesInPageOrientation() async throws {
        let image = try #require(Self.page(text: "HELLO WORLD", inTopHalf: true))

        let words = try await VisionPageTextRecognizer().words(in: image, orientation: .up)

        let texts = words.map { $0.text.uppercased() }
        #expect(texts == ["HELLO", "WORLD"])
        guard words.count == 2 else { return }
        // Origin top left: text drawn in the top half has small y, and words run left to right.
        #expect(words[0].bounds.maxY < 0.5)
        #expect(words[1].bounds.maxY < 0.5)
        #expect(words[0].bounds.maxX <= words[1].bounds.minX)
    }

    @Test func turningLookupOffSavesItAndLeavesLookup() async {
        let chapter = Manga.Chapter(key: "chapter", chapter: 1)
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "manga", title: "Manga", chapters: [chapter]),
            initialChapter: chapter
        )
        let reader = subject.viewModel
        #expect(reader.isWordLookupEnabled)
        reader.wordLookup.begin(pageID: "a", image: page, orientation: .up)

        reader.setWordLookupEnabled(false)
        #expect(reader.wordLookup.session == nil)
        await reader.waitForTestingOperations()

        #expect(subject.settings.writtenWordLookupValues == [false])
        #expect(!reader.isWordLookupEnabled)
    }

    private static func blankPage() -> CGImage {
        guard let image = page(text: "", inTopHalf: true) else {
            preconditionFailure("A blank page always renders")
        }
        return image
    }

    /// A white 800×1200 page with `text` in black, drawn in its top or bottom half.
    private static func page(text: String, inTopHalf: Bool) -> CGImage? {
        let size = CGSize(width: 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let y = inTopHalf ? size.height * 0.2 : size.height * 0.7
            (text as NSString).draw(at: CGPoint(x: 80, y: y), withAttributes: attributes)
        }
        return image.cgImage
    }
}
