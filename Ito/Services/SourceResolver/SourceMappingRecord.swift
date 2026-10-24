import Foundation
import GRDB

extension PluginMediaType: Codable, DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        switch self {
        case .manga: return "manga".databaseValue
        case .anime: return "anime".databaseValue
        case .novel: return "novel".databaseValue
        }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> PluginMediaType? {
        if let string = String.fromDatabaseValue(dbValue) {
            switch string {
            case "manga": return .manga
            case "anime": return .anime
            case "novel": return .novel
            default: return nil
            }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "manga": self = .manga
        case "anime": self = .anime
        case "novel": self = .novel
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid media type: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .manga: try container.encode("manga")
        case .anime: try container.encode("anime")
        case .novel: try container.encode("novel")
        }
    }
}

extension MatchMethod: Codable, DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        switch self {
        case .exactPreferred: return "exactPreferred".databaseValue
        case .exactAlternative: return "exactAlternative".databaseValue
        case .fuzzy: return "fuzzy".databaseValue
        case .none: return "none".databaseValue
        }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MatchMethod? {
        if let string = String.fromDatabaseValue(dbValue) {
            switch string {
            case "exactPreferred": return .exactPreferred
            case "exactAlternative": return .exactAlternative
            case "fuzzy": return .fuzzy
            case "none": return MatchMethod.none
            default: return nil
            }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "exactPreferred": self = .exactPreferred
        case "exactAlternative": self = .exactAlternative
        case "fuzzy": self = .fuzzy
        case "none": self = .none
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid match method: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .exactPreferred: try container.encode("exactPreferred")
        case .exactAlternative: try container.encode("exactAlternative")
        case .fuzzy: try container.encode("fuzzy")
        case .none: try container.encode("none")
        }
    }
}

extension MatchDecision: Codable, DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        switch self {
        case .autoConfirm: return "autoConfirm".databaseValue
        case .requiresConfirmation: return "requiresConfirmation".databaseValue
        case .discard: return "discard".databaseValue
        }
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MatchDecision? {
        if let string = String.fromDatabaseValue(dbValue) {
            switch string {
            case "autoConfirm": return .autoConfirm
            case "requiresConfirmation": return .requiresConfirmation
            case "discard": return .discard
            default: return nil
            }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "autoConfirm": self = .autoConfirm
        case "requiresConfirmation": self = .requiresConfirmation
        case "discard": self = .discard
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid match decision: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .autoConfirm: try container.encode("autoConfirm")
        case .requiresConfirmation: try container.encode("requiresConfirmation")
        case .discard: try container.encode("discard")
        }
    }
}

public struct SourceMappingRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sourceMapping"

    // PK
    public let canonicalProvider: String
    public let canonicalMediaId: String
    public let mediaType: PluginMediaType
    public let pluginId: String
    public let pluginMediaKey: String

    // Req
    public let decision: MatchDecision
    public let matchMethod: MatchMethod
    public let confidence: Double
    public let titleSnapshot: String
    public let createdAt: Date
    public let updatedAt: Date

    // Nullable
    public let coverURLSnapshot: String?
    public let encodedPayload: Data?
    public let payloadVersion: Int?
    public let pluginVersion: String?
    public let lastVerifiedAt: Date?

    public init(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String,
        decision: MatchDecision,
        matchMethod: MatchMethod,
        confidence: Double,
        titleSnapshot: String,
        createdAt: Date,
        updatedAt: Date,
        coverURLSnapshot: String? = nil,
        encodedPayload: Data? = nil,
        payloadVersion: Int? = nil,
        pluginVersion: String? = nil,
        lastVerifiedAt: Date? = nil
    ) {
        self.canonicalProvider = canonicalProvider
        self.canonicalMediaId = canonicalMediaId
        self.mediaType = mediaType
        self.pluginId = pluginId
        self.pluginMediaKey = pluginMediaKey
        self.decision = decision
        self.matchMethod = matchMethod
        self.confidence = confidence
        self.titleSnapshot = titleSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverURLSnapshot = coverURLSnapshot
        self.encodedPayload = encodedPayload
        self.payloadVersion = payloadVersion
        self.pluginVersion = pluginVersion
        self.lastVerifiedAt = lastVerifiedAt
    }
}
