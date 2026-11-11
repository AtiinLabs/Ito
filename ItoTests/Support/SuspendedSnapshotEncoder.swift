import Foundation
@testable import Ito

actor SuspendedSnapshotEncoder: MediaDetailSnapshotEncoding {
    private typealias StartWaiter = (id: UUID, count: Int, continuation: CheckedContinuation<Void, any Error>)

    private let onStarted: @MainActor @Sendable (Int) -> Void
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedCount = 0
    private var startWaiters: [StartWaiter] = []
    private var cancellationStates: [Int: Bool] = [:]

    init(onStarted: @escaping @MainActor @Sendable (Int) -> Void = { _ in }) {
        self.onStarted = onStarted
    }

    func encode<Value: Encodable & Sendable>(_ value: Value) async throws -> Data {
        let request = startedCount + 1
        await withCheckedContinuation { continuation in
            pending[request] = continuation
            startedCount = request
            let ready = startWaiters.filter { $0.count <= startedCount }
            startWaiters.removeAll { $0.count <= startedCount }
            ready.forEach { $0.continuation.resume() }
            Task { @MainActor [onStarted] in onStarted(request) }
        }
        cancellationStates[request] = Task.isCancelled
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func waitUntilStarted(_ count: Int) async throws {
        guard startedCount < count else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard startedCount < count else {
                    continuation.resume()
                    return
                }
                startWaiters.append((id, count, continuation))
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(id: id) }
        }
    }

    private func cancelStartWaiter(id: UUID) {
        guard let index = startWaiters.firstIndex(where: { $0.id == id }) else { return }
        startWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release(request: Int) {
        pending.removeValue(forKey: request)?.resume()
    }

    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }

    func observedCancellationState(for request: Int) -> Bool? {
        cancellationStates[request]
    }
}
