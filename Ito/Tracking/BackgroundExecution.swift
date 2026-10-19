import UIKit

/// Keeps work alive while the app moves to the background, so a token rotation a tracker has
/// already accepted is not abandoned before the new token reaches the Keychain.
nonisolated struct BackgroundExecution: Sendable {
    private let begin: @Sendable (String) async -> Int?
    private let end: @Sendable (Int) async -> Void

    /// Runs the work directly. For tests and previews.
    static let none = BackgroundExecution(begin: { _ in nil }, end: { _ in })

    /// Runs the work inside a UIKit background task.
    static let application = BackgroundExecution(
        begin: { name in
            await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: nil).rawValue
            }
        },
        end: { identifier in
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
            }
        }
    )

    func run<T: Sendable>(_ name: String, _ work: @Sendable () async throws -> T) async throws -> T {
        let identifier = await begin(name)
        do {
            let result = try await work()
            if let identifier { await end(identifier) }
            return result
        } catch {
            if let identifier { await end(identifier) }
            throw error
        }
    }
}
