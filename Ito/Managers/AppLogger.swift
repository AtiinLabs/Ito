import Foundation
import OSLog

public enum AppLogger {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ito.app"

    nonisolated public static let general = Logger(subsystem: subsystem, category: "general")
    nonisolated public static let network = Logger(subsystem: subsystem, category: "network")
    nonisolated public static let plugin = Logger(subsystem: subsystem, category: "plugin")
    nonisolated public static let database = Logger(subsystem: subsystem, category: "database")
    nonisolated public static let ui = Logger(subsystem: subsystem, category: "ui")
    nonisolated public static let auth = Logger(subsystem: subsystem, category: "auth")
    nonisolated public static let update = Logger(subsystem: subsystem, category: "update")
}
