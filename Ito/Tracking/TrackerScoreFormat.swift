import Foundation

/// Native AniList scoring units. Zero always clears an existing rating.
enum TrackerScoreFormat: String, Codable, Sendable, CaseIterable {
    case point100 = "POINT_100"
    case point10Decimal = "POINT_10_DECIMAL"
    case point10 = "POINT_10"
    case point5 = "POINT_5"
    case point3 = "POINT_3"

    var maxScore: Double {
        switch self {
        case .point100: 100
        case .point10Decimal, .point10: 10
        case .point5: 5
        case .point3: 3
        }
    }

    var step: Double { self == .point10Decimal ? 0.1 : 1 }

    func isValid(_ score: Double) -> Bool {
        guard score.isFinite, score >= 0, score <= maxScore else { return false }
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
        }
    }
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
    var scoreEditingIdentity: UUID { get }
    func getScoreFormat() async throws -> TrackerScoreFormat
    func getMediaListEntry(mediaId: String, scoreSession: TrackerScoreSession) async throws -> TrackerMediaEntry?
    /// A nil score preserves the rating; zero clears it.
    func updateEntry(
        mediaId: String, progress: Int?, status: String?, score: Double?, scoreSession: TrackerScoreSession?
    ) async throws
}
