import Foundation
import WebKit
import ito_runner

/// WebKit cannot intercept every HTTP subresource. Stores nevertheless never cross source/account epochs.
@MainActor
final class SourceWebsiteContexts {
    struct Scope: Hashable {
        let sourceID: String
        let authorizationScope: UUID
        init(_ context: NetworkOperationContext) {
            sourceID = context.sourceID
            authorizationScope = context.authorizationScope
        }
    }
    private var stores: [Scope: WKWebsiteDataStore] = [:]
    private var retirements: [UUID: () -> Void] = [:]
    private var clearingCount = 0
    var isClearing: Bool { clearingCount > 0 }

    /// The barrier spans the entire settings clear, including cookie/token and default-store awaits.
    func beginClearing() {
        clearingCount += 1
        let callbacks = Array(retirements.values)
        retirements.removeAll()
        callbacks.forEach { $0() }
    }

    func endClearing() {
        precondition(clearingCount > 0)
        clearingCount -= 1
    }

    func store(for context: NetworkOperationContext) throws -> WKWebsiteDataStore {
        guard !isClearing else { throw CancellationError() }
        let scope = Scope(context)
        if let store = stores[scope] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[scope] = store
        return store
    }

    func observeRetirement(_ retire: @escaping () -> Void) -> UUID? {
        guard !isClearing else { retire(); return nil }
        let id = UUID()
        retirements[id] = retire
        return id
    }
    func removeObserver(_ id: UUID) { retirements[id] = nil }

    func clear() async {
        beginClearing()
        defer { endClearing() }
        let retired = Array(stores.values)
        stores.removeAll()
        for store in retired {
            await withCheckedContinuation { continuation in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    continuation.resume()
                }
            }
        }
    }
}
