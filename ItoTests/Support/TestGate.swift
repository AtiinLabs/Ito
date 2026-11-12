import Combine
import Foundation

/// A counting gate for tests: `wait(for:)` returns once `open()` ran that many times, whichever came first.
/// It lets a test resume exactly when a callback fires, instead of polling for a state.
@MainActor
final class TestGate {
    private var openCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func open() {
        openCount += 1
        let ready = waiters.filter { openCount >= $0.count }
        waiters.removeAll { openCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(for count: Int = 1) async {
        guard openCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// Returns at the first value of `publisher` that satisfies `predicate`, including its current one.
@MainActor
func awaitValue<P: Publisher>(
    of publisher: P,
    where predicate: @escaping (P.Output) -> Bool
) async where P.Failure == Never {
    for await value in publisher.values where predicate(value) { return }
}
