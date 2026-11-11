import Combine
import Foundation
@testable import Ito

/// Test double for `NetworkPathObserving`. Tests drive the path explicitly with `set(_:)`;
/// subscribers see the same replay-then-update behaviour as the production observer.
nonisolated final class ManualNetworkPathObserver: NetworkPathObserving, @unchecked Sendable {
    private let subject: CurrentValueSubject<NetworkPathSnapshot, Never>
    /// Guards `readCount` and `actionsAfterReads`: `current` is read from any thread.
    private let lock = NSLock()
    private var readCount = 0
    private var actionsAfterReads: [Int: () -> Void] = [:]

    init(initial: NetworkPathSnapshot = .unknown) {
        subject = CurrentValueSubject(initial)
    }

    var current: NetworkPathSnapshot {
        let value = subject.value
        let action: (() -> Void)? = lock.withLock {
            readCount += 1
            return actionsAfterReads.removeValue(forKey: readCount)
        }
        // Outside the lock: the action may publish a path, and a subscriber may read `current` again.
        action?()
        return value
    }

    var updates: AnyPublisher<NetworkPathSnapshot, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    func set(_ snapshot: NetworkPathSnapshot) {
        subject.send(snapshot)
    }

    /// Runs `action` once, right after the `reads`-th read of `current` from now returns its value. Lets a test
    /// change the path at a known point of the worker's pass, without any timing.
    func runAfterRead(readsFromNow reads: Int, _ action: @escaping () -> Void) {
        lock.withLock { actionsAfterReads[readCount + reads] = action }
    }
}
