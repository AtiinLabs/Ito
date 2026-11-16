import Foundation
import GRDB
@testable import Ito

/// Holds every publication of a `ValueObservation` until the test runs it, including the initial value,
/// so a test chooses when the observer sees a snapshot.
nonisolated final class HeldObservationScheduler: ValueObservationMainActorScheduler, @unchecked Sendable {
    nonisolated struct Publication: @unchecked Sendable {
        let action: @MainActor () -> Void

        @MainActor
        func run() {
            action()
        }
    }

    private let lock = NSLock()
    private var publications: [Publication] = []
    private var continuations: [CheckedContinuation<Publication, Never>] = []

    func immediateInitialValue() -> Bool { false }

    func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        let publication = Publication(action: action)
        lock.lock()
        if continuations.isEmpty {
            publications.append(publication)
            lock.unlock()
        } else {
            let continuation = continuations.removeFirst()
            lock.unlock()
            continuation.resume(returning: publication)
        }
    }

    /// The oldest publication not yet taken, waiting for it if none has been scheduled.
    func nextPublication() async -> Publication {
        await withCheckedContinuation { continuation in
            lock.lock()
            if publications.isEmpty {
                continuations.append(continuation)
                lock.unlock()
            } else {
                let publication = publications.removeFirst()
                lock.unlock()
                continuation.resume(returning: publication)
            }
        }
    }
}
