import Combine
import Foundation
import Network

/// A device-wide network path reduced to the properties that bulk downloads gate on.
nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        /// No path has been reported yet.
        case unknown
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    var status: Status
    /// Cellular or a personal hotspot, as reported by the system.
    var isExpensive: Bool
    /// Low Data Mode is active on the path.
    var isConstrained: Bool

    static let unknown = NetworkPathSnapshot(status: .unknown, isExpensive: false, isConstrained: false)

    init(status: Status, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(path: NWPath) {
        let status: Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unknown
        }
        self.init(status: status, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}

/// Source of the device's current network path. `current` is always readable; `updates` replays
/// the latest snapshot to new subscribers, so a subscriber cannot miss a change between reading
/// `current` and subscribing.
nonisolated protocol NetworkPathObserving: AnyObject, Sendable {
    var current: NetworkPathSnapshot { get }
    var updates: AnyPublisher<NetworkPathSnapshot, Never> { get }
}

/// Production observer backed by one continuous `NWPathMonitor`, started on construction and
/// cancelled on deinit. Inject a single instance rather than creating one per consumer.
nonisolated final class NWPathNetworkObserver: NetworkPathObserving, @unchecked Sendable {
    // `subject` is only sent to from the monitor's serial queue. Its `value` is read from any
    // thread; Combine synchronizes that access internally. `CurrentValueSubject` is not Sendable,
    // so the handler captures the observer weakly rather than the subject.
    private let subject: CurrentValueSubject<NetworkPathSnapshot, Never>
    private let monitor: NWPathMonitor

    init() {
        subject = CurrentValueSubject<NetworkPathSnapshot, Never>(.unknown)
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.subject.send(NetworkPathSnapshot(path: path))
        }
        monitor.start(queue: DispatchQueue(label: "moe.itoapp.offline-chapters.network-path", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    var current: NetworkPathSnapshot {
        subject.value
    }

    var updates: AnyPublisher<NetworkPathSnapshot, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }
}
