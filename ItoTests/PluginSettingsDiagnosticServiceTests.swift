import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

@Suite("PluginSettingsDiagnosticServiceTests")
struct PluginSettingsDiagnosticServiceTests {

    // MARK: - Snapshot Basic & Precedence Tests

    @Test func snapshotBasicPrecedenceIsolationAndErrors() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        let store = PluginSettingsStore(dbPool: database.dbPool, secrets: secrets)

        let pluginID = "com.test.source"
        let otherPluginID = "com.test.other"

        // 1. Setup plain settings and secrets
        #expect(store.set(pluginId: pluginID, key: "plainKey", value: "plainValue"))
        #expect(store.set(pluginId: pluginID, key: "secretKey", value: "plainShadow"))
        #expect(store.setSecret(pluginId: pluginID, key: "secretKey", value: "savedSecret"))
        #expect(store.setSecret(pluginId: pluginID, key: "unalteredSecret", value: "savedUnaltered"))

        // Cross-plugin settings
        #expect(store.set(pluginId: otherPluginID, key: "plainKey", value: "otherValue"))
        #expect(store.setSecret(pluginId: otherPluginID, key: "secretKey", value: "otherSecret"))

        // Take snapshot directly
        let snapshot = try store.snapshot(pluginId: pluginID)

        // Verifications for store.snapshot:
        // Plain key is present
        #expect(snapshot["plainKey"] == "plainValue")
        // Saved secret overrides plain value under same key
        #expect(snapshot["secretKey"] == "savedSecret")
        #expect(snapshot["unalteredSecret"] == "savedUnaltered")
        // Exact plugin isolation: other plugin's values never appear in this snapshot
        #expect(snapshot["plainKey"] != "otherValue")
        #expect(snapshot["secretKey"] != "otherSecret")

        // Test invalid UTF-8 fail-closed in store.snapshot
        try await database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE pluginSetting SET value = ? WHERE pluginId = ? AND key = ?",
                arguments: [Data([0xFF, 0xFE, 0xFD]), pluginID, "plainKey"]
            )
        }

        #expect(throws: PluginCompletionScopeError.invalidSettingEncoding) {
            try store.snapshot(pluginId: pluginID)
        }

        // Restore valid UTF-8
        #expect(store.set(pluginId: pluginID, key: "plainKey", value: "plainValue"))

        // Test Keychain read failure propagation
        keychain.failingStatus = errSecInteractionNotAllowed
        #expect(throws: PluginSecretStoreError(status: errSecInteractionNotAllowed)) {
            try store.snapshot(pluginId: pluginID)
        }
        keychain.failingStatus = nil

        // Verify no mutations happened to Keychain or database during snapshot
        let postSnapshot = try store.snapshot(pluginId: pluginID)
        #expect(postSnapshot["plainKey"] == "plainValue")
        #expect(postSnapshot["secretKey"] == "savedSecret")
    }

    @Test func crossPluginPrefixIsolation() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        let store = PluginSettingsStore(dbPool: database.dbPool, secrets: secrets)

        let pluginA = "com.test.alpha"
        let pluginAPrefix = "com.test.alpha.beta"

        #expect(store.set(pluginId: pluginA, key: "k1", value: "vA"))
        #expect(store.setSecret(pluginId: pluginA, key: "s1", value: "secA"))

        #expect(store.set(pluginId: pluginAPrefix, key: "k1", value: "vBeta"))
        #expect(store.setSecret(pluginId: pluginAPrefix, key: "s1", value: "secBeta"))

        let snapA = try store.snapshot(pluginId: pluginA)
        let snapBeta = try store.snapshot(pluginId: pluginAPrefix)

        #expect(snapA["k1"] == "vA")
        #expect(snapA["s1"] == "secA")
        #expect(snapA.count == 2)

        #expect(snapBeta["k1"] == "vBeta")
        #expect(snapBeta["s1"] == "secBeta")
        #expect(snapBeta.count == 2)
    }

    // MARK: - Capture Defaults & Invariant Tests

    @Test func captureDefaultsBoundaryWithDraftPrecedenceAndNoMutations() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let keychain = InMemoryPluginSecretKeychain()
        let secrets = PluginSecretStore(keychain: keychain)
        let store = PluginSettingsStore(dbPool: database.dbPool, secrets: secrets)

        let pluginID = "com.test.diagnostic"

        // Set persisted plain setting and persisted secret
        #expect(store.set(pluginId: pluginID, key: "server_url", value: "https://persisted.example.com"))
        #expect(store.setSecret(pluginId: pluginID, key: "saved_token", value: "persisted_token_value"))
        #expect(store.setSecret(pluginId: pluginID, key: "blank_fallback_token", value: "persisted_fallback_token"))

        // Record initial epoch state in DB
        let initialImageEpoch = try await database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        }
        let initialCompletionScope = try await database.dbPool.read { db in
            try PluginCompletionScope.current(pluginID: pluginID, in: db)
        }

        let schema = try await pr7bSettingsSchema(settings: [
            .text(id: "server_url", name: "Server", summary: nil, defaultValue: "https://default.example.com"),
            .toggle(id: "enable_sync", name: "Sync", summary: nil, defaultValue: true),
            .secret(id: "saved_token", name: "Token", summary: nil),
            .secret(id: "blank_fallback_token", name: "Fallback Token", summary: nil),
            .secret(id: "new_token", name: "New Token", summary: nil)
        ])

        let secretDrafts: [String: String] = [
            // 1. Non-blank declared secret overrides saved secret:
            "saved_token": "  draft_token_value  ",
            // 2. Blank declared secret falls back to saved secret:
            "blank_fallback_token": "   ",
            // 3. Non-blank declared secret without saved secret:
            "new_token": "new_secret_draft",
            // 4. Undeclared secret draft ignored:
            "undeclared_secret": "undeclared_value",
            // 5. Plain setting key in secretDrafts ignored (only schema-declared secrets overlay):
            "server_url": "https://draft.ignored.com"
        ]

        let service = await MainActor.run {
            PluginSettingsDiagnosticService(
                settingsStore: store,
                locatePlugin: { _ in throw URLError(.fileDoesNotExist) }
            )
        }

        let defaults = try await service.captureDefaults(
            pluginID: pluginID,
            schema: schema,
            secretDrafts: secretDrafts
        )

        // Verify in-memory defaults reads:
        // Non-blank declared secret draft overrides saved value (trimmed)
        #expect(defaults.get(key: "saved_token") == "draft_token_value")
        // Blank declared secret draft falls back to saved value
        #expect(defaults.get(key: "blank_fallback_token") == "persisted_fallback_token")
        // New declared secret draft is present
        #expect(defaults.get(key: "new_token") == "new_secret_draft")
        // Plain setting preserved; draft under plain key was ignored
        #expect(defaults.get(key: "server_url") == "https://persisted.example.com")
        // Undeclared secret draft ignored
        #expect(defaults.get(key: "undeclared_secret") == nil)
        // Schema default resolved for unset key
        #expect(defaults.get(key: "enable_sync") == "true")

        // Verify zero mutations occurred:
        // 1. Database plain settings unchanged
        #expect(store.get(pluginId: pluginID, key: "server_url") == "https://persisted.example.com")
        #expect(store.get(pluginId: pluginID, key: "saved_token") == nil)
        #expect(store.get(pluginId: pluginID, key: "new_token") == nil)

        // 2. Keychain secrets unchanged (drafts were NOT persisted)
        #expect(secrets.value(pluginID: pluginID, key: "saved_token") == "persisted_token_value")
        #expect(secrets.value(pluginID: pluginID, key: "blank_fallback_token") == "persisted_fallback_token")
        #expect(secrets.value(pluginID: pluginID, key: "new_token") == nil)

        // 3. Image cache epoch and completion epoch unchanged
        let postImageEpoch = try await database.dbPool.read { db in
            try PluginImageCacheEpoch.current(in: db)
        }
        let postCompletionScope = try await database.dbPool.read { db in
            try PluginCompletionScope.current(pluginID: pluginID, in: db)
        }
        #expect(postImageEpoch == initialImageEpoch)
        #expect(postCompletionScope == initialCompletionScope)
    }

    // MARK: - Host Module Rejection Tests

    @Test func diagnosticDenyingNetModuleRejectsAll() async throws {
        let net = PluginDiagnosticDenyingNetModule()
        let request = NetRequest(url: "https://example.com", method: "GET", headers: [:], body: nil)

        await #expect(throws: URLError.self) {
            try await net.fetch(request: request)
        }
    }

    @Test func diagnosticWebviewModuleRejectsAll() async throws {
        let webview = PluginDiagnosticWebviewModule()
        let request = WebviewRequest(url: "https://example.com", script: nil)

        await #expect(throws: ItoError.self) {
            try await webview.loadUrl(request: request)
        }
        await #expect(throws: ItoError.self) {
            try await webview.executeJs(script: "console.log('hi')")
        }
    }

    // MARK: - Cancellation Test

    @Test func cancellationIsCheckedDeterministically() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        let store = PluginSettingsStore(dbPool: database.dbPool)
        let service = await MainActor.run {
            PluginSettingsDiagnosticService(
                settingsStore: store,
                locatePlugin: { _ in
                    Issue.record("locatePlugin must not be called when task is already cancelled")
                    return URL(fileURLWithPath: "/nonexistent/test.ito")
                }
            )
        }

        let schema = try await pr7bSettingsSchema()

        // Deterministic cancellation: cancel current task before invoking service
        await #expect(throws: CancellationError.self) {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                Task {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                    do {
                        _ = try await service.inspect(pluginID: "test", schema: schema, secretDrafts: [:])
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
