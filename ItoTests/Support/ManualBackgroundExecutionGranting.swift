import Foundation
@testable import Ito

/// Hands out background grants that a test ends or expires on demand, as the system does. Expiration runs the
/// owner's handler and then ends the grant, which is the order UIKit requires. With `refusesGrants`, every grant is
/// refused the way UIKit refuses one: the handler runs at once and the grant ends.
@MainActor
final class ManualBackgroundExecutionGranting: BackgroundExecutionGranting {
    private(set) var grantsBegun = 0
    private(set) var grantsEnded = 0
    private let refusesGrants: Bool
    private var expirationHandler: (@MainActor () -> Void)?
    private var currentGrant: BackgroundGrant?
    private var endWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(refusesGrants: Bool = false) {
        self.refusesGrants = refusesGrants
    }

    func beginGrant(named _: String, onExpiration: @escaping @MainActor () -> Void) -> BackgroundGrant {
        grantsBegun += 1
        let grant = BackgroundGrant { [self] in
            grantsEnded += 1
            let waiters = endWaiters
            endWaiters = [:]
            for waiter in waiters.values {
                waiter.resume()
            }
        }
        if refusesGrants {
            onExpiration()
            grant.end()
            return grant
        }
        expirationHandler = onExpiration
        currentGrant = grant
        return grant
    }

    /// The system reclaims the time: the owner's handler runs, then the grant ends.
    func expire() {
        expirationHandler?()
        currentGrant?.end()
    }

    /// Returns once a grant has ended. Resumed by the end itself, never by a timer. A cancelled waiter returns,
    /// so a test that ends by its time limit does not hang here.
    func awaitEnded() async {
        if grantsEnded > 0 {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                endWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.dropEndWaiter(id) }
        }
    }

    private func dropEndWaiter(_ id: UUID) {
        endWaiters.removeValue(forKey: id)?.resume()
    }
}
