import Combine
import Foundation
import Testing
@testable import Ito

/// "Offline" means the system says there is no network. Anything less certain is not offline.
@MainActor
struct ConnectivityServingTests {
    @Test func onlyAnUnsatisfiedPathIsOffline() {
        let cases: [(NetworkPathSnapshot.Status, Bool)] = [
            (.unsatisfied, true),
            (.satisfied, false),
            (.unknown, false),
            (.requiresConnection, false)
        ]
        for (status, expected) in cases {
            let connectivity = NetworkPathConnectivity(
                observer: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: status))
            )
            #expect(connectivity.isOffline == expected, "\(status)")
        }
    }

    @Test func aMeteredOrConstrainedPathIsStillOnline() {
        let connectivity = NetworkPathConnectivity(
            observer: ManualNetworkPathObserver(
                initial: NetworkPathSnapshot(status: .satisfied, isExpensive: true, isConstrained: true)
            )
        )

        #expect(!connectivity.isOffline)
    }

    @Test func theCurrentValueFollowsTheObserver() {
        let observer = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        let connectivity = NetworkPathConnectivity(observer: observer)
        #expect(!connectivity.isOffline)

        observer.set(NetworkPathSnapshot(status: .unsatisfied))
        #expect(connectivity.isOffline)

        observer.set(NetworkPathSnapshot(status: .requiresConnection))
        #expect(!connectivity.isOffline)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func thePublisherReplaysTheCurrentValueThenEachChangeWithoutRepeats() async {
        let observer = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .unsatisfied))
        let connectivity = NetworkPathConnectivity(observer: observer)
        var seen: [Bool] = []

        for await value in connectivity.isOfflinePublisher.values {
            seen.append(value)
            if seen.count == 1 {
                // A path change that is not a change of "offline" is not published.
                observer.set(NetworkPathSnapshot(status: .unsatisfied, isExpensive: true))
                observer.set(NetworkPathSnapshot(status: .satisfied))
            } else if seen.count == 2 {
                observer.set(NetworkPathSnapshot(status: .unsatisfied))
            } else {
                break
            }
        }

        #expect(seen == [true, false, true])
    }

    @Test func theUnavailableSeamIsNeverOffline() {
        #expect(!UnavailableConnectivity().isOffline)
    }
}
