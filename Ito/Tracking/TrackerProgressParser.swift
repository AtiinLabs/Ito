import Foundation

nonisolated enum TrackerProgressParser {
    /// The episode or chapter number in a title such as `Chapter 10.5` or `Ep.12v2`: the first
    /// run of digits in the first word that has any. Digits after a `.` or other separator are
    /// never appended, so `10.5` is 10, not 105.
    static func number(inTitle title: String) -> Int? {
        let words = title.components(separatedBy: .whitespacesAndNewlines)
        guard let word = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }),
              let start = word.firstIndex(where: \.isASCIIDigit)
        else {
            return nil
        }
        return Int(word[start...].prefix(while: \.isASCIIDigit))
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
