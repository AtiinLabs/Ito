import Foundation
import Network

/// The dispatcher's time source and its one durable-deadline wait. Production uses the system
/// clock; tests substitute a manual clock so retry deadlines run without real waiting.
nonisolated protocol PluginCompletionScheduling: Sendable {
    func now() -> Date
    /// Suspends until `date` has been reached. Throws `CancellationError` if the waiting task is
    /// cancelled first.
    func sleep(until date: Date) async throws
}

nonisolated struct SystemPluginCompletionScheduler: PluginCompletionScheduling {
    /// Longest single suspension. Longer waits are chained so the nanosecond conversion cannot
    /// overflow when a persisted deadline is far away (for example after a clock change).
    private static let longestSuspension: TimeInterval = 3_600

    func now() -> Date { Date() }

    func sleep(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, Self.longestSuspension) * 1_000_000_000))
        }
    }
}

/// Reports whether the device has any network path, so offline periods do not spend the bounded
/// retry budget: while the system says there is no path, nothing is attempted, and the change
/// back wakes the dispatcher.
@MainActor
protocol PluginCompletionConnectivityMonitoring: AnyObject {
    /// False only when the system reports no usable path. Unknown counts as reachable.
    var isReachable: Bool { get }
    /// Begins observing. `onChange` runs on the main actor whenever `isReachable` flips.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class NetworkPathCompletionMonitor: PluginCompletionConnectivityMonitoring {
    private var monitor: NWPathMonitor?
    private var status: NWPath.Status?
    private var generation: UInt64 = 0

    var isReachable: Bool { status != .unsatisfied }

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        let token = generation
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                let wasReachable = self.isReachable
                self.status = status
                if self.isReachable != wasReachable { onChange() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "moe.itoapp.plugin-completion.network-path", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor = nil
        status = nil
    }
}
