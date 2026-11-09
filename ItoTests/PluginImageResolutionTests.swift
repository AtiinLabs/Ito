import Foundation
import Testing
import ito_runner
@testable import Ito

struct PluginImageLocatorTests {
    @Test func splitsThePluginIDFromTheRealURL() throws {
        let url = try #require(URL(string: "ito://fixture.plugin/https://images.example/cover"))

        let locator = try PluginImageLocator.parse(url)

        #expect(locator == PluginImageLocator(pluginID: "fixture.plugin", realURLString: "https://images.example/cover"))
    }

    @Test func restoresTheSlashesThatPathNormalizationCollapsed() throws {
        let https = try #require(URL(string: "ito://fixture.plugin/https:/images.example/cover"))
        let http = try #require(URL(string: "ito://fixture.plugin/http:/images.example/cover"))

        let httpsLocator = try PluginImageLocator.parse(https)
        let httpLocator = try PluginImageLocator.parse(http)
        #expect(httpsLocator.realURLString == "https://images.example/cover")
        #expect(httpLocator.realURLString == "http://images.example/cover")
    }

    @Test func keepsTheQueryOnTheRealURL() throws {
        let url = try #require(URL(string: "ito://fixture.plugin/https://images.example/cover?size=2"))

        let locator = try PluginImageLocator.parse(url)

        #expect(locator.realURLString == "https://images.example/cover?size=2")
    }

    @Test func keepsAPluginRelativePathAsIs() throws {
        let url = try #require(URL(string: "ito://fixture.plugin/api/v1/cover"))

        let locator = try PluginImageLocator.parse(url)

        #expect(locator == PluginImageLocator(pluginID: "fixture.plugin", realURLString: "api/v1/cover"))
    }

    @Test func rejectsAURLWithoutAPluginHost() throws {
        let url = try #require(URL(string: "ito:/fixture.plugin/cover"))

        #expect(throws: URLError.self) {
            try PluginImageLocator.parse(url)
        }
    }
}

struct PluginImageResolutionTests {
    private let locator = PluginImageLocator(pluginID: "fixture.plugin", realURLString: "https://images.example/cover")

    @Test func aResolvedRequestFetchesWithItsHeadersAndOrigins() async throws {
        let target = try #require(URL(string: "https://images.example/cover"))
        let runner = ResolutionImageRunner(
            request: PluginImageRequest(url: target.absoluteString, headers: ["X-API-Key": "fixture-private-key"]),
            origins: ["https://images.example"]
        )

        let result = try await PluginImageResolution.resolve(locator, runner: runner)

        #expect(result == .fetch(target, headers: ["X-API-Key": "fixture-private-key"], allowedOrigins: ["https://images.example"]))
        let handled = await runner.handleImageCalls
        #expect(handled == 0)
    }

    @Test func missingOriginsResolveToNoAllowedOrigins() async throws {
        let target = try #require(URL(string: "https://images.example/cover"))
        let runner = ResolutionImageRunner(request: PluginImageRequest(url: target.absoluteString))

        let result = try await PluginImageResolution.resolve(locator, runner: runner)

        #expect(result == .fetch(target, headers: nil, allowedOrigins: []))
    }

    @Test func aResolvedRequestWithAnInvalidURLThrowsBadURL() async throws {
        let runner = ResolutionImageRunner(request: PluginImageRequest(url: ""), origins: [])

        await #expect(throws: URLError.self) {
            try await PluginImageResolution.resolve(locator, runner: runner)
        }
    }

    @Test func pluginBytesAreReturnedWhenNoRequestIsResolved() async throws {
        let runner = ResolutionImageRunner(bytes: Data([1, 2, 3]))

        let result = try await PluginImageResolution.resolve(locator, runner: runner)

        #expect(result == .bytes(Data([1, 2, 3])))
    }

    @Test func anUnhandledHTTPSImageIsFetchedDirectly() async throws {
        let direct = try #require(URL(string: "https://images.example/cover"))
        let runner = ResolutionImageRunner()

        let result = try await PluginImageResolution.resolve(locator, runner: runner)

        #expect(result == .direct(direct))
    }

    @Test func anUnhandledNonWebImageIsRejectedWithoutFetching() async throws {
        let ftpLocator = PluginImageLocator(pluginID: "fixture.plugin", realURLString: "ftp://images.example/cover")
        let runner = ResolutionImageRunner()

        await #expect(throws: URLError.self) {
            try await PluginImageResolution.resolve(ftpLocator, runner: runner)
        }
    }

    @Test func aRefusedResolutionThrowsAndNeverFallsBackToBytes() async throws {
        let refusal = PluginCallError(kind: .reported, message: "Refused image")
        let runner = ResolutionImageRunner(requestRefusal: refusal)

        do {
            _ = try await PluginImageResolution.resolve(locator, runner: runner)
            Issue.record("A refused resolution must not produce an image")
        } catch {
            #expect(error as? PluginCallError == refusal)
        }
        let handled = await runner.handleImageCalls
        #expect(handled == 0)
    }

    @Test func aPluginThatRefusesTheBytesThrowsAndNothingIsFetched() async throws {
        let refusal = PluginCallError(kind: .reported, message: "Refused image")
        let runner = ResolutionImageRunner(bytesRefusal: refusal)

        do {
            _ = try await PluginImageResolution.resolve(locator, runner: runner)
            Issue.record("A refused image must not fall back to a direct fetch")
        } catch {
            #expect(error as? PluginCallError == refusal)
        }
    }

    @Test func cancellationWhileTheByteHandlerRunsStopsTheResolution() async throws {
        let runner = SuspendedImageRunner()
        let resolving = Task {
            try await PluginImageResolution.resolve(locator, runner: runner)
        }

        await runner.waitUntilHandlerEnters()
        resolving.cancel()
        await runner.finishHandler(returning: Data([1, 2, 3]))

        switch await resolving.result {
        case .success(let result):
            Issue.record("A cancelled resolution must not return \(result)")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}

private actor ResolutionImageRunner: PluginImageRunner {
    private let request: PluginImageRequest?
    private let origins: [String]?
    private let bytes: Data?
    private let requestRefusal: PluginCallError?
    private let bytesRefusal: PluginCallError?
    private(set) var handleImageCalls = 0

    init(
        request: PluginImageRequest? = nil,
        origins: [String]? = nil,
        bytes: Data? = nil,
        requestRefusal: PluginCallError? = nil,
        bytesRefusal: PluginCallError? = nil
    ) {
        self.request = request
        self.origins = origins
        self.bytes = bytes
        self.requestRefusal = requestRefusal
        self.bytesRefusal = bytesRefusal
    }

    func getImageRequest(_ locator: String) async throws -> PluginImageRequest? {
        if let requestRefusal { throw requestRefusal }
        return request
    }

    func getImageOrigins() async throws -> [String]? { origins }

    func handleImage(_ locator: String) async throws -> Data? {
        handleImageCalls += 1
        if let bytesRefusal { throw bytesRefusal }
        return bytes
    }
}

/// A byte handler that stays suspended until the test releases it, so cancellation can be
/// delivered while the plugin call is in flight.
private actor SuspendedImageRunner: PluginImageRunner {
    private var hasEntered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Data?, Never>?

    func getImageRequest(_ locator: String) async throws -> PluginImageRequest? { nil }

    func getImageOrigins() async throws -> [String]? { nil }

    func handleImage(_ locator: String) async throws -> Data? {
        hasEntered = true
        enterWaiter?.resume()
        enterWaiter = nil
        return await withCheckedContinuation { release = $0 }
    }

    func waitUntilHandlerEnters() async {
        if hasEntered { return }
        await withCheckedContinuation { enterWaiter = $0 }
    }

    func finishHandler(returning data: Data?) {
        release?.resume(returning: data)
        release = nil
    }
}
