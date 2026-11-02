import Foundation

/// Scoring units for explicit tracker editors. Zero clears an existing rating.
enum TrackerScoreFormat: String, Codable, Sendable, CaseIterable {
    case point100 = "POINT_100"
    case point10Decimal = "POINT_10_DECIMAL"
    case point10 = "POINT_10"
    case point5 = "POINT_5"
    case point3 = "POINT_3"
    case numeric100 = "NUMERIC_100"

    var maxScore: Double {
        switch self {
        case .point100, .numeric100: 100
        case .point10Decimal, .point10: 10
        case .point5: 5
        case .point3: 3
        }
    }

    var step: Double { self == .point10Decimal ? 0.1 : 1 }

    func isValid(_ score: Double) -> Bool {
        guard score.isFinite, score >= 0, score <= maxScore else { return false }
        if self == .numeric100 { return true }
        let steps = score / step
        return abs(steps - steps.rounded()) < 0.0000001
    }

    func label(for score: Double) -> String {
        guard score != 0 else { return String(localized: "Not set") }
        guard isValid(score) else { return score.formatted() }
        switch self {
        case .point5:
            return String(repeating: "★", count: Int(score))
        case .point3:
            switch Int(score) {
            case 1: return String(localized: "🙁 Bad")
            case 2: return String(localized: "😐 Average")
            default: return String(localized: "🙂 Good")
            }
        case .point10Decimal:
            return score.formatted(.number.precision(.fractionLength(1)))
        case .point100, .point10:
            return score.formatted(.number.precision(.fractionLength(0)))
        case .numeric100:
            return Self.numericStyle.format(score)
        }
    }

    static let numericStyle = FloatingPointFormatStyle<Double>.number
        .grouping(.never).precision(.significantDigits(1...17)).locale(.autoupdatingCurrent)

    /// Parses the whole input, including native decimal digits, without accepting a numeric
    /// prefix of invalid text or treating another locale's separator as the end of the number.
    static func parseNumericScore(_ text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
        let separator = locale.decimalSeparator?.first ?? "."
        var normalized = String()
        normalized.reserveCapacity(text.utf8.count)
        var hasSeparator = false
        for character in text {
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                normalized.unicodeScalars.append(UnicodeScalar(48 + digit)!)
            } else if character == separator, !hasSeparator {
                normalized.append(".")
                hasSeparator = true
            } else {
                return nil
            }
        }
        guard let value = Double(normalized), Self.numeric100.isValid(value) else { return nil }
        return value
    }
}

/// Ephemeral account authority shared by credential transitions and durable link commits.
/// Acquire only after writer admission, and never hold across an asynchronous operation.
nonisolated final class TrackerScoreIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var identity = UUID()

    var current: UUID { lock.withLock { identity } }

    func rotate() {
        lock.withLock { identity = UUID() }
    }

    func withCurrentIdentity<T>(_ expected: UUID, operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard identity == expected else { throw TrackerScoreEditingError.accountChanged }
            return try operation()
        }
    }

    #if DEBUG
    /// Nonblocking probe for transaction-observer tests; does not read account state.
    func isLockedForTesting() -> Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
    }
    #endif
}

struct TrackerScoreSession: Equatable, Sendable {
    let format: TrackerScoreFormat
    let identity: UUID
}

nonisolated enum TrackerScoreEditingError: TrackerUserFacingError, Equatable, Sendable {
    case unsupportedFormat
    case invalidScore
    case scoreFormatChanged
    case accountChanged
    case unsupportedProvider

    var userMessage: String {
        switch self {
        case .accountChanged:
            String(localized: "Your tracker account changed. Reopen this entry before saving.")
        case .scoreFormatChanged:
            String(localized: "Your scoring format changed. Reopen this entry before saving.")
        case .unsupportedFormat:
            String(localized: "Your scoring format could not be loaded. Reopen this entry before saving.")
        case .invalidScore:
            String(localized: "Choose a valid score for your scoring format.")
        case .unsupportedProvider:
            String(localized: "This tracker does not support manual scoring.")
        }
    }
}

@MainActor
protocol TrackerScoreEditing: TrackerProvider {
    var scoreIdentity: TrackerScoreIdentity { get }
    var scoreEditingIdentity: UUID { get }
    func getScoreFormat() async throws -> TrackerScoreFormat
    func getMediaListEntry(mediaId: String, scoreSession: TrackerScoreSession) async throws -> TrackerMediaEntry?
    /// A nil score preserves the rating; zero clears it.
    func updateEntry(
        mediaId: String, progress: Int?, status: String?, score: Double?, scoreSession: TrackerScoreSession?
    ) async throws
}
