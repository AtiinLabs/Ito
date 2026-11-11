import UIKit

/// Asks the system for time to finish work that is already running when the app leaves the foreground.
///
/// `onExpiration` runs on the main actor when the system reclaims the time, or at once when it refuses the grant.
/// Either way the grant has ended by the time `beginGrant` returns, or ends right after `onExpiration`, so the owner
/// can rely on the same cancellation for both.
@MainActor
protocol BackgroundExecutionGranting {
    func beginGrant(named name: String, onExpiration: @escaping @MainActor () -> Void) -> BackgroundGrant
}

/// One granted assertion. Ending it is idempotent, so the owner and an expiration may both end it.
@MainActor
final class BackgroundGrant {
    private let finish: @MainActor () -> Void
    private(set) var isEnded = false

    init(finish: @escaping @MainActor () -> Void) {
        self.finish = finish
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        finish()
    }
}

/// The production grant: one `UIApplication` background task. UIKit requires the task to end before its expiration
/// handler returns, so expiration cancels the work and then ends the task at once. When UIKit refuses the task there
/// is no time to finish, so the work is interrupted at once, exactly as an expiration would interrupt it.
@MainActor
struct UIKitBackgroundExecutionGranting: BackgroundExecutionGranting {
    func beginGrant(named name: String, onExpiration: @escaping @MainActor () -> Void) -> BackgroundGrant {
        let assertion = UIKitBackgroundAssertion()
        let grant = BackgroundGrant {
            assertion.end()
        }
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                onExpiration()
                grant.end()
            }
        }
        if assertion.identifier == .invalid {
            onExpiration()
            grant.end()
        } else if grant.isEnded {
            // The handler ran before its identifier was stored, so nothing ended the task then.
            assertion.end()
        }
        return grant
    }
}

@MainActor
private final class UIKitBackgroundAssertion {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
