import Combine
import Foundation
import Nuke

/// One image load admitted under one request authority. It is the single owner of that load's completion:
/// the completion runs at most once, and neither callback runs after the load was cancelled. A live policy
/// change that no longer admits the request ends this load with the typed refusal and cancels its transfer;
/// it never reaches another subscriber's load, because every load owns its own authority.
nonisolated final class AdmittedImageLoad: Nuke.Cancellable, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var completion: (@Sendable (Error?) -> Void)?
    private var subscription: Combine.AnyCancellable?
    private var underlying: (any Nuke.Cancellable)?
    private var task: Task<Void, Never>?
    private var isCancelled = false
#if DEBUG
    private var taskForTesting: Task<Void, Never>?

    func waitForTaskForTesting() async {
        let held = lock.withLock { taskForTesting }
        await held?.value
    }
#endif

    init(authority: NetworkRequestAuthority, completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = completion
        // A context captured under an older revision never silently acquires the current permissions.
        let subscription = authority.changes.sink { [weak self] _ in
            do {
                try authority.checkImageAdmission()
            } catch {
                self?.refuse(error)
            }
        }
        lock.withLock { self.subscription = subscription }
    }

    var isPending: Bool {
        lock.withLock { completion != nil && !isCancelled }
    }

    /// Hands a received body on while the load is still pending.
    func deliver(_ data: Data, _ response: URLResponse, to receive: @Sendable (Data, URLResponse) -> Void) {
        lock.withLock {
            guard completion != nil, !isCancelled else { return }
            receive(data, response)
        }
    }

    func attach(_ cancellable: any Nuke.Cancellable) {
        let cancelNow = lock.withLock { () -> Bool in
            if isCancelled || completion == nil { return true }
            underlying = cancellable
            return false
        }
        if cancelNow { cancellable.cancel() }
    }

    func attach(task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
#if DEBUG
            taskForTesting = task
#endif
            if isCancelled || completion == nil { return true }
            self.task = task
            return false
        }
        if cancelNow { task.cancel() }
    }

    /// Ends the load with `error` (nil is success). The first call wins.
    func complete(_ error: Error?) {
        let finish: (@Sendable (Error?) -> Void)? = lock.withLock {
            guard !isCancelled, let completion else { return nil }
            self.completion = nil
            subscription?.cancel()
            subscription = nil
            underlying = nil
            task = nil
            return completion
        }
        finish?(error)
    }

    private func refuse(_ error: Error) {
        let (transfer, running): ((any Nuke.Cancellable)?, Task<Void, Never>?) = lock.withLock {
            (underlying, task)
        }
        complete(error)
        transfer?.cancel()
        running?.cancel()
    }

    func cancel() {
        let (transfer, running): ((any Nuke.Cancellable)?, Task<Void, Never>?) = lock.withLock {
            isCancelled = true
            completion = nil
            subscription?.cancel()
            subscription = nil
            let held = (underlying, task)
            underlying = nil
            task = nil
            return held
        }
        transfer?.cancel()
        running?.cancel()
    }
}
