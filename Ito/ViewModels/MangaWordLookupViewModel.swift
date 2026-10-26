import Combine
import CoreGraphics
import Foundation
import ImageIO

/// Word lookup on one manga page at a time: a long press reads the page, its words are
/// outlined, and tapping one opens the dictionary.
@MainActor
final class MangaWordLookupViewModel: ObservableObject {
    enum Phase: Equatable {
        case reading
        case words([RecognizedWord])
        case noWords
        case failed
    }

    struct Session: Equatable {
        let pageID: String
        let phase: Phase
    }

    /// A dictionary entry being shown.
    struct Lookup: Identifiable, Equatable {
        let id = UUID()
        let term: String
    }

    @Published private(set) var session: Session?
    @Published private(set) var lookup: Lookup?

    private let recognizer: any PageTextRecognizing
    private let dictionary: any DictionaryDefinitionChecking
    private var readTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(recognizer: any PageTextRecognizing, dictionary: any DictionaryDefinitionChecking) {
        self.recognizer = recognizer
        self.dictionary = dictionary
    }

    /// What lookup shows on `pageID`; nil when that page is not being looked up.
    func phase(on pageID: String) -> Phase? {
        session?.pageID == pageID ? session?.phase : nil
    }

    /// Reads `image` and outlines its words on `pageID`, replacing any lookup in progress.
    func begin(pageID: String, image: CGImage, orientation: CGImagePropertyOrientation) {
        end()
        let generation = generation
        session = Session(pageID: pageID, phase: .reading)
        let recognizer = recognizer
        let task = Task { [weak self] in
            let phase: Phase
            do {
                let words = try await recognizer.words(in: image, orientation: orientation)
                phase = words.isEmpty ? .noWords : .words(words)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed
            }
            guard let self, self.generation == generation else { return }
            self.readTask = nil
            self.session = Session(pageID: pageID, phase: phase)
        }
        readTask = task
        #if DEBUG
        testingReadTasks.append(task)
        #endif
    }

    /// Opens the dictionary for `word`, one of the words outlined on the page.
    func lookUp(_ word: RecognizedWord) {
        guard case .words(let words)? = session?.phase, words.contains(word),
              let term = DictionaryTerm.resolve(word.text, hasDefinition: dictionary.hasDefinition(for:))
        else { return }
        lookup = Lookup(term: term)
    }

    /// The dictionary was closed; the page stays outlined so another word can be looked up.
    func finishLookup() {
        lookup = nil
    }

    /// Leaves lookup: stops reading and removes the outlines.
    func end() {
        generation &+= 1
        readTask?.cancel()
        readTask = nil
        session = nil
        lookup = nil
    }

    #if DEBUG
    private var testingReadTasks: [Task<Void, Never>] = []

    /// Waits for every read started so far, including ones a later read replaced.
    func waitForReadsForTesting() async {
        for task in testingReadTasks {
            await task.value
        }
    }
    #endif
}
