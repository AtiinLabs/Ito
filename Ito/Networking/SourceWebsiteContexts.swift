import Foundation
import WebKit
import ito_runner

/// WebKit cannot intercept every HTTP subresource. Stores nevertheless never cross source/account epochs.
@MainActor
final class SourceWebsiteContexts {
    static let shared = SourceWebsiteContexts()
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

    func store(for context: NetworkOperationContext) -> WKWebsiteDataStore {
        let scope = Scope(context)
        if let store = stores[scope] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[scope] = store
        return store
    }

    func observeRetirement(_ retire: @escaping () -> Void) -> UUID {
        let id = UUID()
        retirements[id] = retire
        return id
    }
    func removeObserver(_ id: UUID) { retirements[id] = nil }

    func clear() async {
        let callbacks = Array(retirements.values)
        retirements.removeAll()
        callbacks.forEach { $0() }
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
