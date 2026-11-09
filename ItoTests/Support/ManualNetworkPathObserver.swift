import Combine
import Foundation
@testable import Ito

/// Test double for `NetworkPathObserving`. Tests drive the path explicitly with `set(_:)`;
/// subscribers see the same replay-then-update behaviour as the production observer.
nonisolated final class ManualNetworkPathObserver: NetworkPathObserving, @unchecked Sendable {
    private let subject: CurrentValueSubject<NetworkPathSnapshot, Never>

    init(initial: NetworkPathSnapshot = .unknown) {
        subject = CurrentValueSubject(initial)
    }

    var current: NetworkPathSnapshot {
        subject.value
    }

    var updates: AnyPublisher<NetworkPathSnapshot, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    func set(_ snapshot: NetworkPathSnapshot) {
        subject.send(snapshot)
    }
}
