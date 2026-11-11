import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

// MARK: - Ephemeral network module

struct PluginCompletionNetModuleTests {
    @Test func requestsCarryOnlyWhatThePluginSentAndNoAmbientCookies() async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(
            host,
            .respond(status: 204, headers: ["Set-Cookie": "sid=from-server; Path=/"], body: Data())
        )
        let url = try #require(URL(string: "https://\(host)/api/v1/books/B1/read-progress"))
        let ambient = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "ambient", .value: "AMBIENT_COOKIE", .secure: "TRUE"
        ]))
        HTTPCookieStorage.shared.setCookie(ambient)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())
        let response = try await module.fetch(request: NetRequest(
            url: url.absoluteString,
            method: "PATCH",
            headers: ["Content-Type": "application/json", "X-API-Key": "secret", "Cookie": "plugin=explicit"],
            body: Array(#"{"completed":true}"#.utf8)
        ), context: makeTestNetworkContext())

        #expect(response.status == 204)
        #expect(response.body.isEmpty)
        let seen = try #require(CompletionTransportProtocol.requests(to: host).first)
        #expect(seen.method == "PATCH")
        #expect(seen.headers["x-api-key"] == "secret")
        #expect(seen.headers["content-type"] == "application/json")
        // What the plugin put in its own Cookie header is its own; the jar contributes nothing.
        #expect(seen.headers["cookie"] == "plugin=explicit")
        #expect(seen.body == Data(#"{"completed":true}"#.utf8))
        // A cookie the server sets is not kept anywhere.
        let jar = HTTPCookieStorage.shared.cookies(for: url) ?? []
        #expect(!jar.contains { $0.name == "sid" })
    }

    @Test func noCookieIsSentWhenThePluginSetsNoneEvenIfTheAmbientJarHoldsOne() async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(host, .respond(status: 200, headers: [:], body: Data()))
        let url = try #require(URL(string: "https://\(host)/ping"))
        let ambient = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "ambient", .value: "AMBIENT_COOKIE"
        ]))
        HTTPCookieStorage.shared.setCookie(ambient)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())
        _ = try await module.fetch(request: NetRequest(url: url.absoluteString, method: "GET", headers: [:], body: nil), context: makeTestNetworkContext())

        let seen = try #require(CompletionTransportProtocol.requests(to: host).first)
        #expect(seen.headers["cookie"] == nil)
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func everyRedirectIsRefusedAndItsTargetIsNeverRequested(status: Int) async throws {
        let origin = CompletionTransportProtocol.makeHost()
        let target = CompletionTransportProtocol.makeHost()
        let targetURL = try #require(URL(string: "https://\(target)/elsewhere"))
        CompletionTransportProtocol.register(origin, .redirect(status: status, to: targetURL))
        CompletionTransportProtocol.register(target, .respond(status: 200, headers: [:], body: Data("target".utf8)))

        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())
        let response = try await module.fetch(request: NetRequest(
            url: "https://\(origin)/start",
            method: "PATCH",
            headers: ["Authorization": "Bearer SENTINEL_CREDENTIAL"],
            body: Array("{}".utf8)
        ), context: makeTestNetworkContext())

        // The plugin sees the redirect itself, not what it points at.
        #expect(response.status == Int32(status))
        #expect(response.body.isEmpty)
        #expect(response.headers.contains { $0.key.lowercased() == "location" })
        #expect(CompletionTransportProtocol.requests(to: target).isEmpty)
        #expect(CompletionTransportProtocol.requests(to: origin).count == 1)
    }

    @Test
    func cancellingTheCallingTaskCancelsTheTransfer() async throws {
        let host = CompletionTransportProtocol.makeHost()
        let signals = CompletionTransportProtocol.registerHang(host)
        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())
        let request = NetRequest(url: "https://\(host)/slow", method: "PATCH", headers: [:], body: nil)

        let call = Task { try await module.fetch(request: request, context: makeTestNetworkContext()) }
        await signals.started.wait()
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        await signals.stopped.wait()
    }

    @Test(arguments: ["replaced", "revoked"])
    func aTrustChangeEndsTheTransferInFlightAndRefusesLaterRequests(change: String) async throws {
        let slow = CompletionTransportProtocol.makeHost()
        let signals = CompletionTransportProtocol.registerHang(slow)
        let later = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(later, .respond(status: 204, headers: [:], body: Data()))
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let module = PluginCompletionNetModule(
            configuration: CompletionTransportProtocol.configuration(),
            trust: ("plugin.fixture", trust)
        )

        let call = Task {
            try await module.fetch(request: NetRequest(url: "https://\(slow)/slow", method: "PATCH", headers: [:], body: nil), context: makeTestNetworkContext())
        }
        await signals.started.wait()
        if change == "replaced" {
            try trust.trust(fingerprint: "AA11", host: "server.local", pluginID: "plugin.fixture")
        } else {
            try trust.removeAll(pluginID: "plugin.fixture")
        }

        // Nothing but the trust change ends this transfer.
        await #expect(throws: PluginCompletionExecutionFailure.configurationChanged) { try await call.value }
        await signals.stopped.wait()
        await #expect(throws: PluginCompletionExecutionFailure.configurationChanged) {
            try await module.fetch(request: NetRequest(url: "https://\(later)/ping", method: "PATCH", headers: [:], body: nil), context: makeTestNetworkContext())
        }
        #expect(CompletionTransportProtocol.requests(to: later).isEmpty)
    }

    @Test
    func anotherSourcesTrustChangeLeavesTheTransferAlone() async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(host, .respond(status: 204, headers: [:], body: Data()))
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let module = PluginCompletionNetModule(
            configuration: CompletionTransportProtocol.configuration(),
            trust: ("plugin.fixture", trust)
        )
        try trust.trust(fingerprint: "AA11", host: "server.local", pluginID: "plugin.other")

        let response = try await module.fetch(request: NetRequest(url: "https://\(host)/ping", method: "PATCH", headers: [:], body: nil), context: makeTestNetworkContext())
        #expect(response.status == 204)
    }

    @Test(arguments: [
        "file:///etc/hosts", "ftp://example.com/file", "data:text/plain,hello", "javascript:alert(1)", "not a url", ""
    ])
    func onlyHttpAndHttpsAreEverFetched(url: String) async throws {
        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())

        let error = await captured { try await module.fetch(request: NetRequest(url: url, method: "GET", headers: [:], body: nil), context: makeTestNetworkContext()) }

        #expect((error as? URLError)?.code == .unsupportedURL)
    }

    @Test(arguments: [
        ("PATCH", ["X Bad Name": "value"]),
        ("PATCH", ["X-Injected": "value\r\nX-Smuggled: yes"]),
        ("PATCH", ["": "value"]),
        ("PA TCH", [:]),
        ("", [:])
    ] as [(String, [String: String])])
    func malformedMethodsAndHeadersAreRefusedBeforeAnythingIsSent(method: String, headers: [String: String]) async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(host, .respond(status: 200, headers: [:], body: Data()))
        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())

        let error = await captured {
            try await module.fetch(request: NetRequest(url: "https://\(host)/x", method: method, headers: headers, body: nil), context: makeTestNetworkContext())
        }

        #expect((error as? URLError)?.code == .badURL)
        #expect(CompletionTransportProtocol.requests(to: host).isEmpty)
    }

    @Test func aBodyBeyondTheLimitIsNotReadWhetherOrNotTheServerAnnouncedIt() async throws {
        let announced = CompletionTransportProtocol.makeHost()
        let unannounced = CompletionTransportProtocol.makeHost()
        let atLimit = CompletionTransportProtocol.makeHost()
        let body = Data(repeating: 0x41, count: 64)
        CompletionTransportProtocol.register(
            announced, .respond(status: 200, headers: ["Content-Length": "64"], body: body)
        )
        CompletionTransportProtocol.register(unannounced, .respond(status: 200, headers: [:], body: body))
        CompletionTransportProtocol.register(
            atLimit, .respond(status: 200, headers: [:], body: Data(repeating: 0x42, count: 16))
        )
        let module = PluginCompletionNetModule(
            configuration: CompletionTransportProtocol.configuration(),
            maximumResponseBytes: 16
        )

        for host in [announced, unannounced] {
            let error = await captured {
                try await module.fetch(request: NetRequest(url: "https://\(host)/", method: "GET", headers: [:], body: nil), context: makeTestNetworkContext())
            }
            #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
        }
        let allowed = try await module.fetch(request: NetRequest(url: "https://\(atLimit)/", method: "GET", headers: [:], body: nil), context: makeTestNetworkContext())
        #expect(allowed.body == Array(repeating: 0x42, count: 16))
    }

    @Test func aTransportFailureIsReportedForTheRunnerToPassOnNotMistakenForCancellation() async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(host, .fail(URLError.Code.notConnectedToInternet))
        let module = PluginCompletionNetModule(configuration: CompletionTransportProtocol.configuration())

        let error = await captured {
            try await module.fetch(request: NetRequest(url: "https://\(host)/", method: "GET", headers: [:], body: nil), context: makeTestNetworkContext())
        }

        #expect((error as? URLError)?.code == .notConnectedToInternet)
    }
}

// MARK: - Sandboxed defaults

struct PluginCompletionSandboxTests {
    private static let storedSettings = ["server_url": "https://komga.example", "api_key": "SECRET"]

    @Test func aPluginReadsTheCapturedSettingsAndTheSchemaDefaultsForKeysTheUserNeverSet() {
        let defaults = PluginCompletionDefaults(settings: Self.storedSettings)
        defaults.useSchemaDefaults(["page_size": "20", "server_url": "https://default.invalid"])

        #expect(defaults.get(key: "server_url") == "https://komga.example")
        #expect(defaults.get(key: "api_key") == "SECRET")
        #expect(defaults.get(key: "page_size") == "20")
        #expect(defaults.get(key: "unset") == nil)
    }

    @Test func aPluginsWritesStayInItsAttemptAndNeverReachAnother() {
        let first = PluginCompletionDefaults(settings: Self.storedSettings)
        let second = PluginCompletionDefaults(settings: Self.storedSettings)

        first.set(key: "session", value: "from-plugin")
        first.set(key: "server_url", value: "https://elsewhere.example")

        #expect(first.get(key: "session") == "from-plugin")
        #expect(first.get(key: "server_url") == "https://elsewhere.example")
        #expect(second.get(key: "session") == nil)
        #expect(second.get(key: "server_url") == "https://komga.example")
    }

    @Test func removingAKeyFallsBackToItsSchemaDefaultLikeTheReader() {
        let defaults = PluginCompletionDefaults(settings: Self.storedSettings)
        defaults.useSchemaDefaults(["server_url": "https://default.invalid"])

        defaults.remove(key: "api_key")
        defaults.remove(key: "server_url")

        #expect(defaults.get(key: "api_key") == nil)
        #expect(defaults.get(key: "server_url") == "https://default.invalid")
    }

    @Test func aWebViewIsRefusedWithATypedErrorAndNothingOfTheRequestIsEchoed() async {
        let module = PluginCompletionWebviewModule()

        let load = await captured {
            try await module.loadUrl(request: WebviewRequest(url: "https://SENTINEL.example/login", script: "SENTINEL_SCRIPT"), context: makeTestNetworkContext())
        }
        let script = await captured { try await module.executeJs(script: "SENTINEL_SCRIPT", context: makeTestNetworkContext()) }

        for error in [load, script] {
            #expect(error as? ItoError == PluginCompletionWebviewModule.unavailable)
            #expect(!"\(String(describing: error))".contains("SENTINEL"))
        }
    }
}

// MARK: - Failure classification

struct PluginCompletionOutcomeMappingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let error: any Error
        let expected: String

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        .init(name: "network", error: failure(.network), expected: "retryable(network)"),
        .init(name: "server", error: failure(.server), expected: "retryable(server)"),
        .init(name: "unauthorized", error: failure(.unauthorized), expected: "paused(credentials,credentials)"),
        .init(name: "notFound", error: failure(.notFound), expected: "paused(missingRemote,missingRemote)"),
        .init(name: "needsSetup", error: failure(.needsSetup), expected: "paused(configurationChanged,configurationChanged)"),
        .init(name: "other", error: failure(.other), expected: "paused(sourceError,sourceError)"),
        .init(name: "unsupported", error: failure(.unsupported), expected: "unsupported"),
        .init(name: "trap", error: ItoError.wasmTrap("x"), expected: "paused(sourceError,sourceError)"),
        .init(
            name: "memory",
            error: ItoError.memoryOutOfBounds(offset: 1, length: 2, memorySize: 3),
            expected: "paused(sourceError,sourceError)"
        ),
        .init(
            name: "newerHost",
            error: ItoError.requiresNewerHost(missingImports: ["a.b"]),
            expected: "paused(incompatible,incompatible)"
        ),
        .init(
            name: "policyOffline",
            error: ItoError.networkPolicy(.deferred(.offline)),
            expected: "retryable(network)"
        ),
        .init(
            name: "policyUnknownPath",
            error: ItoError.networkPolicy(.deferred(.unknownPath)),
            expected: "retryable(network)"
        ),
        .init(
            name: "policyExpensivePath",
            error: ItoError.networkPolicy(.deferred(.expensivePath)),
            expected: "retryable(network)"
        ),
        .init(
            name: "policyConstrainedPath",
            error: ItoError.networkPolicy(.deferred(.constrainedPath)),
            expected: "retryable(network)"
        ),
        .init(
            name: "policyChanged",
            error: ItoError.networkPolicy(.deferred(.policyChanged)),
            expected: "retryable(network)"
        ),
        .init(
            name: "policyAuthorization",
            error: ItoError.networkPolicy(.sourceAuthorizationFailure),
            expected: "paused(configurationChanged,configurationChanged)"
        ),
        .init(
            name: "policyForegroundPermission",
            error: ItoError.networkPolicy(.foregroundPermissionRequired),
            expected: "paused(sourceError,sourceError)"
        ),
        .init(
            name: "policyHardBlocked",
            error: ItoError.networkPolicy(.hardUserBlocked),
            expected: "paused(sourceError,sourceError)"
        ),
        .init(
            name: "reloadDuringExport",
            error: ItoError.reloadDuringActiveExport,
            expected: "paused(sourceError,sourceError)"
        ),
        .init(
            name: "pluginReloaded",
            error: ItoError.pluginReloaded,
            expected: "paused(sourceError,sourceError)"
        ),
        .init(
            name: "abi",
            error: ItoError.unsupportedABI(version: 9, supported: 1...1),
            expected: "paused(incompatible,incompatible)"
        ),
        .init(name: "decoding", error: ItoError.postcardDecodingError("x"), expected: "paused(incompatible,incompatible)"),
        .init(
            name: "webview",
            error: ItoError.hostModuleError(domain: "webview", message: "x"),
            expected: "paused(incompatible,incompatible)"
        ),
        .init(
            name: "js",
            error: ItoError.hostModuleError(domain: "js", message: "x"),
            expected: "paused(incompatible,incompatible)"
        ),
        .init(
            name: "otherHost",
            error: ItoError.hostModuleError(domain: "html", message: "x"),
            expected: "paused(sourceError,sourceError)"
        ),
        .init(name: "cancelled", error: CancellationError(), expected: "cancelled"),
        .init(
            name: "notInstalled",
            error: PluginCompletionExecutionFailure.sourceUnavailable,
            expected: "paused(sourceUnavailable,sourceUnavailable)"
        ),
        .init(
            name: "settingsChanged",
            error: PluginCompletionExecutionFailure.configurationChanged,
            expected: "paused(configurationChanged,configurationChanged)"
        ),
        .init(
            name: "unverifiable",
            error: PluginCompletionExecutionFailure.unverifiableConfiguration,
            expected: "paused(unknownOrigin,unknownOrigin)"
        ),
        .init(
            name: "needsNewerApp",
            error: PluginIncompatibility.requiresNewerApp(minimumAppVersion: "9.9"),
            expected: "paused(incompatible,incompatible)"
        ),
        .init(
            name: "needsSourceUpdate",
            error: PluginIncompatibility.requiresSourceUpdate,
            expected: "paused(incompatible,incompatible)"
        ),
        .init(
            name: "unsupportedFile",
            error: PluginIncompatibility.unsupportedFile,
            expected: "paused(incompatible,incompatible)"
        ),
        .init(name: "unknown", error: URLError(.badURL), expected: "paused(sourceError,sourceError)")
    ]

    private static func failure(_ category: PluginErrorCategory) -> ItoError {
        .pluginFailed(function: "mark_chapter_read", reason: "SENTINEL", category: category)
    }

    @Test(arguments: PluginCompletionOutcomeMappingTests.cases)
    func eachFailureIsRecordedTheWayTheRetryPolicyAssumes(_ scenario: Case) {
        #expect(describe(PluginCompletionExecutor.outcome(forFailure: scenario.error)) == scenario.expected)
    }

    /// A source that needs a newer Ito pauses with the stored reason, which carries no direction. The copy shown for
    /// that pause must never tell the user the source has to be updated, because the source may be fine.
    @Test func aSourceNeedingANewerAppIsPausedWithCopyThatNeverSaysTheSourceMustBeUpdated() {
        let outcome = PluginCompletionExecutor.outcome(
            forFailure: PluginIncompatibility.requiresNewerApp(minimumAppVersion: "9.9")
        )

        #expect(describe(outcome) == "paused(incompatible,incompatible)")
        #expect(!PluginCompletionPauseReason.incompatible.recoveryDescription.localizedCaseInsensitiveContains("must be updated"))
    }
}

// MARK: - Executor, end to end through a real runner

struct PluginCompletionExecutorTests {
    @Test func aPluginThatAcknowledgesIsAcknowledged() async throws {
        let harness = try await ExecutorHarness(wasm: TestWasm.build(.init()))
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "acknowledged")
    }

    @Test func aSourceWithoutTheExportIsUnsupportedAndNeverCountedAsDelivered() async throws {
        let harness = try await ExecutorHarness(wasm: TestWasm.build(.init(chapter: nil)))
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "unsupported")
    }

    @Test func eachKindOfProgressCallsItsOwnExport() async throws {
        // Acknowledges only an episode, so a chapter reaching it would be unsupported-by-zero.
        let wasm = TestWasm.build(.init(chapter: [0x41, 0x00], episode: [0x41, 0x01]))
        let anime = try await ExecutorHarness(wasm: wasm, kind: .anime)
        let manga = try await ExecutorHarness(wasm: wasm, kind: .manga)
        let novel = try await ExecutorHarness(wasm: wasm, kind: .novel)
        defer { [anime, manga, novel].forEach { $0.cleanup() } }

        let animeOutcome = await anime.outcome()
        let mangaOutcome = await manga.outcome()
        let novelOutcome = await novel.outcome()
        #expect(animeOutcome == "acknowledged")
        #expect(mangaOutcome == "unsupported")
        #expect(novelOutcome == "unsupported")
    }

    @Test(arguments: [
        ("needsSetup", "paused(configurationChanged,configurationChanged)"),
        ("unauthorized", "paused(credentials,credentials)"),
        ("network", "retryable(network)"),
        ("server", "retryable(server)"),
        ("notFound", "paused(missingRemote,missingRemote)"),
        ("other", "paused(sourceError,sourceError)"),
        ("unsupported", "unsupported")
    ])
    func aTypedFailureTheSourceReportsIsRecordedByItsCategory(category: String, expected: String) async throws {
        let harness = try await ExecutorHarness(wasm: TestWasm.build(try TestWasm.failing(with: category)))
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == expected)
    }

    @Test func aPluginThatTrapsPausesAsASourceError() async throws {
        let harness = try await ExecutorHarness(wasm: TestWasm.build(.init(chapter: [0x00])))
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "paused(sourceError,sourceError)")
    }

    @Test func aSourceThatIsNotInstalledPausesAsUnavailableWithoutLoadingAnything() async throws {
        let loads = LoadCounter()
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(.init()),
            locate: { _ in throw URLError(.fileDoesNotExist) },
            onNetworkCreated: { loads.increment() }
        )
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "paused(sourceUnavailable,sourceUnavailable)")
        #expect(loads.value == 0)
    }

    @Test func aSourceNeedingANewerAppPausesAsIncompatible() async throws {
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(.init()),
            locate: { _ in throw PluginIncompatibility.requiresNewerApp(minimumAppVersion: "99") }
        )
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "paused(incompatible,incompatible)")
    }

    /// A source built for an older ABI pauses the intent without dropping it; once the source is updated, the same
    /// intent is delivered by the next attempt.
    @MainActor
    @Test func aSourceBuiltForAnOlderABIPausesAsIncompatibleAndDeliversOnceUpdated() async throws {
        let update = SourceUpdateGate()
        let updatedArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("completion-updated-\(UUID().uuidString).ito")
        defer { try? FileManager.default.removeItem(at: updatedArchive) }
        try makeTestPluginArchiveData(
            id: "plugin.fixture",
            version: "2.0",
            wasm: Data(TestWasm.build(.init()))
        ).write(to: updatedArchive)
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(.init()),
            locate: { _ in
                if update.isUpdated { return updatedArchive }
                throw PluginIncompatibility.requiresSourceUpdate
            }
        )
        defer { harness.cleanup() }

        #expect(await harness.outcome() == "paused(incompatible,incompatible)")
        update.isUpdated = true
        #expect(await harness.outcome() == "acknowledged")
    }

    @Test func settingsChangedBeforeTheAttemptRunsStopItBeforeAnythingIsLoaded() async throws {
        let loads = LoadCounter()
        let harness = try await ExecutorHarness(wasm: TestWasm.build(.init()), onNetworkCreated: { loads.increment() })
        defer { harness.cleanup() }
        let pluginID = harness.intent.pluginId
        try await harness.database.dbPool.write { db in
            try PluginCompletionScope.rotate(pluginID: pluginID, in: db)
        }

        let outcome = await harness.outcome()
        #expect(outcome == "paused(configurationChanged,configurationChanged)")
        #expect(loads.value == 0)
    }

    @Test func theRequestLeavesThroughTheEphemeralTransportCarryingOnlyWhatThePluginBuilt() async throws {
        let host = CompletionTransportProtocol.makeHost()
        CompletionTransportProtocol.register(host, .respond(status: 204, headers: [:], body: Data()))
        let request = NetRequest(
            url: "https://\(host)/api/v1/books/B1/read-progress",
            method: "PATCH",
            headers: ["Content-Type": "application/json", "X-API-Key": "secret"],
            body: Array(#"{"completed":true}"#.utf8)
        )
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(try TestWasm.sending(request)),
            networkConfiguration: CompletionTransportProtocol.configuration
        )
        defer { harness.cleanup() }
        let ambient = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "ambient", .value: "AMBIENT_COOKIE"
        ]))
        HTTPCookieStorage.shared.setCookie(ambient)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        let outcome = await harness.outcome()
        #expect(outcome == "acknowledged")

        let seen = try #require(CompletionTransportProtocol.requests(to: host).first)
        #expect(seen.method == "PATCH")
        #expect(seen.headers["x-api-key"] == "secret")
        #expect(seen.headers["cookie"] == nil)
        #expect(seen.body == Data(#"{"completed":true}"#.utf8))
    }

    @Test
    func cancellingTheAttemptCancelsTheRequestItIsWaitingOn() async throws {
        let host = CompletionTransportProtocol.makeHost()
        let signals = CompletionTransportProtocol.registerHang(host)
        let request = NetRequest(url: "https://\(host)/slow", method: "PATCH", headers: [:], body: nil)
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(try TestWasm.sending(request)),
            networkConfiguration: CompletionTransportProtocol.configuration
        )
        defer { harness.cleanup() }

        let executor = harness.executor
        let intent = harness.intent
        let attempt = Task { await executor.execute(intent: intent) }
        await signals.started.wait()
        attempt.cancel()

        let outcome = await attempt.value
        #expect(describe(outcome) == "cancelled")
        await signals.stopped.wait()
    }

    @Test
    func aTrustChangeDuringDeliveryPausesTheIntentInsteadOfCancellingOrRetryingIt() async throws {
        let host = CompletionTransportProtocol.makeHost()
        let signals = CompletionTransportProtocol.registerHang(host)
        let request = NetRequest(url: "https://\(host)/slow", method: "PATCH", headers: [:], body: nil)
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let harness = try await ExecutorHarness(
            wasm: TestWasm.build(try TestWasm.sending(request)),
            networkConfiguration: CompletionTransportProtocol.configuration,
            trust: trust
        )
        defer { harness.cleanup() }

        let executor = harness.executor
        let intent = harness.intent
        let attempt = Task { await executor.execute(intent: intent) }
        await signals.started.wait()
        try trust.removeAll(pluginID: "plugin.fixture")

        let outcome = describe(await attempt.value)
        #expect(outcome == "paused(configurationChanged,configurationChanged)")
        await signals.stopped.wait()
    }

    @Test func aSourceThatAsksForAWebViewPausesAsIncompatibleAndNoPageIsLoaded() async throws {
        let request = WebviewRequest(url: "https://SENTINEL.example/login", script: nil)
        let harness = try await ExecutorHarness(wasm: TestWasm.build(try TestWasm.openingWebView(request)))
        defer { harness.cleanup() }

        let outcome = await harness.outcome()
        #expect(outcome == "paused(incompatible,incompatible)")
    }
}

// MARK: - Helpers

private func describe(_ outcome: PluginCompletionOutcome) -> String {
    switch outcome {
    case .acknowledged: return "acknowledged"
    case .unsupported: return "unsupported"
    case .cancelled: return "cancelled"
    case .retryable(let category): return "retryable(\(category.rawValue))"
    case .paused(let reason, let category): return "paused(\(reason.rawValue),\(category?.rawValue ?? "none"))"
    }
}

/// The error `operation` throws, or nil when it does not throw.
private func captured<T: Sendable>(_ operation: () async throws -> T) async -> (any Error)? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// Whether the source has been updated since its first attempt. Read only on the main actor, where `locate` runs.
@MainActor
private final class SourceUpdateGate {
    var isUpdated = false
}

/// A real store, a real `.ito` archive and a real runner around one queued intent.
private struct ExecutorHarness {
    let database: TestDatabase
    let archiveURL: URL
    let executor: PluginCompletionExecutor
    let intent: PluginCompletionIntent

    init(
        wasm: [UInt8],
        kind: MediaKind = .manga,
        locate: (@MainActor @Sendable (String) throws -> URL)? = nil,
        networkConfiguration: (@Sendable () -> URLSessionConfiguration)? = nil,
        onNetworkCreated: (@Sendable () -> Void)? = nil,
        trust: PluginTrustStore? = nil
    ) async throws {
        let database = try TestDatabase()
        let store = PluginCompletionStore(
            dbPool: database.dbPool,
            secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()),
            tokens: PluginSecretStore(keychain: InMemoryPluginSecretKeychain())
        )
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("completion-\(UUID().uuidString).ito")
        try makeTestPluginArchiveData(id: "plugin.fixture", version: "1.0", wasm: Data(wasm)).write(to: archiveURL)

        let context = store.captureContext(
            media: MediaIdentity(pluginId: "plugin.fixture", canonicalMediaId: "library-1", mediaKind: kind),
            mediaKey: "media-key"
        )
        let queuedAt = Date()
        try await database.dbPool.write { db in
            try PluginCompletionStore.enqueue(context: context, unitKey: "unit-key", now: queuedAt, in: db)
        }
        let queued = try await store.dueIntents(now: queuedAt.addingTimeInterval(1))
        let intent = try #require(queued.first)

        self.database = database
        self.archiveURL = archiveURL
        self.intent = intent
        let locator: @MainActor @Sendable (String) throws -> URL
        if let locate {
            locator = locate
        } else {
            locator = { _ in archiveURL }
        }
        executor = PluginCompletionExecutor(
            store: store,
            contexts: PluginNetworkContexts(),
            locatePlugin: locator,
            makeNetModule: { pluginID in
                onNetworkCreated?()
                return PluginCompletionNetModule(
                    configuration: networkConfiguration?() ?? .ephemeral,
                    trust: trust.map { (pluginID, $0) }
                )
            }
        )
    }

    /// The outcome of delivering the queued intent, in the form `describe` prints.
    func outcome() async -> String {
        let result = await executor.execute(intent: intent)
        return describe(result)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: archiveURL)
        database.cleanup()
    }
}

/// An in-process stand-in for the network, keyed by host so concurrent tests cannot interfere.
private final class CompletionTransportProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(status: Int, to: URL)
        case fail(URLError.Code)
        case hang
    }

    struct Seen: Sendable {
        let method: String?
        /// Lower-cased header names.
        let headers: [String: String]
        let body: Data?
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let open = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                let pending = waiters
                waiters = []
                return pending
            }
            for waiter in pending { waiter.resume() }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behaviors: [String: Behavior] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]
    nonisolated(unsafe) private static var hangs: [String: (started: Gate, stopped: Gate)] = [:]

    static func makeHost() -> String {
        "completion-\(UUID().uuidString.lowercased()).example.invalid"
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionTransportProtocol.self]
        return configuration
    }

    static func register(_ host: String, _ behavior: Behavior) {
        lock.withLock { behaviors[host] = behavior }
    }

    static func registerHang(_ host: String) -> (started: Gate, stopped: Gate) {
        let gates = (started: Gate(), stopped: Gate())
        lock.withLock {
            behaviors[host] = .hang
            hangs[host] = gates
        }
        return gates
    }

    static func requests(to host: String) -> [Seen] {
        lock.withLock { seen[host] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { behaviors[host] != nil }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let behavior = Self.lock.withLock({ Self.behaviors[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value
        }
        let recorded = Seen(method: request.httpMethod, headers: headers, body: Self.body(of: request))
        Self.lock.withLock { Self.seen[host, default: []].append(recorded) }

        switch behavior {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        case .redirect(let status, let target):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )
            if let response {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            // Neither answer nor fail: only cancellation ends this transfer.
            Self.lock.withLock { Self.hangs[host] }?.started.open()
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.withLock { Self.hangs[host] }?.stopped.open()
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
