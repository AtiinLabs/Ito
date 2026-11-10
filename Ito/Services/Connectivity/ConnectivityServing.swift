import Combine
import Foundation

extension NetworkPathSnapshot {
    /// Whether the device reports no usable path. An unknown path and one that needs a connection to be
    /// established are not offline: a screen says "offline" only when the system says there is no network.
    nonisolated var isOffline: Bool {
        status == .unsatisfied
    }
}

/// Whether the device is offline, for the screens that say so.
@MainActor
protocol ConnectivityServing: AnyObject {
    var isOffline: Bool { get }
    /// Replays the current value to a new subscriber, then each change, on the main queue.
    var isOfflinePublisher: AnyPublisher<Bool, Never> { get }
}

/// Reads the one network path observer the app shares.
@MainActor
final class NetworkPathConnectivity: ConnectivityServing {
    private let observer: any NetworkPathObserving

    init(observer: any NetworkPathObserving) {
        self.observer = observer
    }

    var isOffline: Bool {
        observer.current.isOffline
    }

    var isOfflinePublisher: AnyPublisher<Bool, Never> {
        observer.updates
            .map(\.isOffline)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

/// Where connectivity is not composed: never offline.
@MainActor
final class UnavailableConnectivity: ConnectivityServing {
    let isOffline = false

    var isOfflinePublisher: AnyPublisher<Bool, Never> {
        Just(false).eraseToAnyPublisher()
    }
}
