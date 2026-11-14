import XCTest
import Nuke
@testable import Ito
import ito_runner

@MainActor
final class PluginDataLoaderFallbackTests: XCTestCase {

    func testANonPluginRequestGoesToTheInnerLoaderAndItsCancellationReachesIt() {
        let inner = RecordingInnerLoader()
        let loader = PluginDataLoader(
            configuration: .ephemeral,
            contexts: PluginNetworkContexts(policy: NetworkPolicyCenter()),
            defaultLoader: inner,
            runnerProvider: { _ in
                XCTFail("A non-plugin request never loads a plugin")
                throw URLError(.unsupportedURL)
            }
        )
        var request = URLRequest(url: URL(string: "https://passthrough-test.example.com/plain-image.jpg")!)
        request.setValue("https://reader.example.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 12

        let handle = loader.loadData(with: request, didReceiveData: { _, _ in }, completion: { _ in })
        XCTAssertEqual(inner.requests, [request])
        XCTAssertEqual(inner.cancelCount, 0)

        handle.cancel()
        XCTAssertEqual(inner.cancelCount, 1)
    }

    func testCustomItoSchemeFallbackCancellationLatch() async throws {
        // Direct test of the CancellationLatch state machine
        let cancelledLatch = CancellationLatch()
        XCTAssertFalse(cancelledLatch.isCancelled)

        var cancelCalled = false
        let dummyCancellable = AnyCancellable {
            cancelCalled = true
        }

        // When latch is cancelled before underlying cancellable is set:
        cancelledLatch.cancel()
        XCTAssertTrue(cancelledLatch.isCancelled)

        // Setting underlying on an already-cancelled latch must immediately cancel it:
        cancelledLatch.setUnderlying(dummyCancellable)
        XCTAssertTrue(cancelCalled, "Underlying cancellable must be immediately cancelled when latch is cancelled")
    }

    func testCancellationLatchActiveCancellation() async throws {
        let latch = CancellationLatch()
        var cancelCalled = false
        let dummyCancellable = AnyCancellable {
            cancelCalled = true
        }

        latch.setUnderlying(dummyCancellable)
        XCTAssertFalse(cancelCalled)

        latch.cancel()
        XCTAssertTrue(cancelCalled)
        XCTAssertTrue(latch.isCancelled)
    }
}

private final class AnyCancellable: Cancellable, @unchecked Sendable {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    func cancel() {
        closure()
    }
}

/// The loader a non-`ito://` request falls through to. It records what reached it and whether the
/// handle it returned was cancelled.
private final class RecordingInnerLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [URLRequest] = []
    private var cancels = 0

    var requests: [URLRequest] { lock.withLock { received } }
    var cancelCount: Int { lock.withLock { cancels } }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        lock.withLock { received.append(request) }
        return AnyCancellable { [weak self] in
            self?.lock.withLock { self?.cancels += 1 }
        }
    }
}
