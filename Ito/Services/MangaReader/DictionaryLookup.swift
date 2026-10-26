import Foundation
import NaturalLanguage
import UIKit

@MainActor
protocol DictionaryDefinitionChecking: AnyObject {
    func hasDefinition(for term: String) -> Bool
}

/// The dictionaries installed on the device (Settings > General > Dictionary).
@MainActor
final class SystemDictionary: DictionaryDefinitionChecking {
    func hasDefinition(for term: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }
}

/// Turns a word as printed on a page into the term to look up. Comic lettering is mostly upper
/// case and carries punctuation, and inflected forms are often only defined under their base form.
nonisolated enum DictionaryTerm {
    /// Terms to try, most specific first; empty when `printed` has no letters.
    static func candidates(for printed: String) -> [String] {
        let trimmed = printed.trimmingCharacters(in: CharacterSet.letters.inverted)
        let word = removingPossessive(trimmed)
        guard !word.isEmpty else { return [] }

        let lowercased = word.lowercased(with: Locale(identifier: "en_US"))
        var candidates = [lowercased]
        if let lemma = lemma(of: lowercased) {
            candidates.append(lemma)
        }
        candidates.append(word)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The first candidate the dictionary defines, else the first candidate (the dictionary then
    /// says it has no definition and offers to manage dictionaries); nil when there is no word.
    static func resolve(_ printed: String, hasDefinition: (String) -> Bool) -> String? {
        let candidates = candidates(for: printed)
        return candidates.first(where: hasDefinition) ?? candidates.first
    }

    private static func removingPossessive(_ word: String) -> String {
        for suffix in ["'s", "’s", "'S", "’S"] where word.hasSuffix(suffix) && word.count > suffix.count {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func lemma(of word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        guard let lemma = tag?.rawValue.lowercased(with: Locale(identifier: "en_US")),
              !lemma.isEmpty, lemma != word else { return nil }
        return lemma
    }
}
