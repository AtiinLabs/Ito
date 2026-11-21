import Foundation
import GRDB

public struct AppPreference: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "appPreference"

    public var id: String { key }
    public let key: String
    public let value: Data

    @available(*, deprecated, message: "Use the typed AppPreferenceKey initializer for catalog preferences.")
    nonisolated public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }

    nonisolated public init<Value>(key: AppPreferenceKey<Value>, value: Value) throws {
        guard key.isValid(value) else {
            throw AppPreferenceError.invalidValue(key: key.name)
        }
        self.key = key.name
        self.value = try JSONEncoder().encode(value)
    }

    /// The row of a catalog preference holding its canonical default.
    nonisolated public init(canonicalDefaultOf entry: AppPreferenceCatalogEntry) {
        self.key = entry.rawValue
        self.value = entry.canonicalDefaultJSON
    }

    nonisolated public func decodedValue<Value>(for key: AppPreferenceKey<Value>) throws -> Value {
        guard self.key == key.name else {
            throw AppPreferenceError.keyMismatch(expected: key.name, actual: self.key)
        }
        let decoded = try JSONDecoder().decode(Value.self, from: value)
        guard key.isValid(decoded) else {
            throw AppPreferenceError.invalidValue(key: key.name)
        }
        return decoded
    }

    public enum Columns {
        public static let key = Column("key")
        public static let value = Column("value")
    }
}

public enum AppPreferenceError: Error, Equatable {
    case invalidValue(key: String)
    case keyMismatch(expected: String, actual: String)
}
