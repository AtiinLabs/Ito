import Foundation
import Nuke
import XCTest
import UIKit
@testable import Ito

@MainActor
final class PluginImagePipelineControllerTests: XCTestCase {
    func testLateOldResponsesCannotPopulateTheNewConfigurationCache() throws {
        let disk = MemoryImageDataCache()
        let recorder = PipelineRecorder()
        let controller = makeController(disk, recorder)
        let plugin = ImageRequest(url: try XCTUnwrap(URL(string: "ito://plugin/api/v1/cover")))
        let publicImage = ImageRequest(url: try XCTUnwrap(URL(string: "https://public.example/cover")))

        controller.install(epoch: String(repeating: "a", count: 32))
        let old = try XCTUnwrap(recorder.latest)
        old.cache.storeCachedData(Data([1]), for: plugin)
        old.cache.storeCachedData(Data([9]), for: publicImage)
        controller.install(epoch: String(repeating: "b", count: 32))
        let current = try XCTUnwrap(recorder.latest)

        // A request completing after the switch still writes through its original pipeline.
        old.cache.storeCachedData(Data([2]), for: plugin)
        XCTAssertNil(current.cache.cachedData(for: plugin))
        XCTAssertEqual(current.cache.cachedData(for: publicImage), Data([9]))
        current.cache.storeCachedData(Data([3]), for: plugin)
        XCTAssertEqual(old.cache.cachedData(for: plugin), Data([2]))
        XCTAssertEqual(current.cache.cachedData(for: plugin), Data([3]))
    }

    func testTheSameDurableEpochRetainsOfflineDataAcrossPipelineReconstruction() throws {
        let disk = MemoryImageDataCache()
        let first = PipelineRecorder()
        let firstController = makeController(disk, first)
        let locator = try XCTUnwrap(URL(string: "ito://plugin/api/v1/cover"))
        var original = ImageRequest(url: locator)
        original.processors = [.resize(width: 48)]
        firstController.install(epoch: String(repeating: "a", count: 32))
        try XCTUnwrap(first.latest).cache.storeCachedData(Data([4]), for: original)

        let second = PipelineRecorder()
        let secondController = makeController(disk, second)
        secondController.install(epoch: String(repeating: "a", count: 32))
        let pipeline = try XCTUnwrap(second.latest)
        XCTAssertEqual(pipeline.cache.cachedData(for: original), Data([4]))
        var differentSize = ImageRequest(url: locator)
        differentSize.processors = [.resize(width: 96)]
        XCTAssertNil(pipeline.cache.cachedData(for: differentSize))
    }

    func testMissingOrMalformedAuthorityNeverReadsOrWritesUnpartitionedPluginData() throws {
        let disk = MemoryImageDataCache()
        let recorder = PipelineRecorder()
        let controller = makeController(disk, recorder)
        let plugin = ImageRequest(url: try XCTUnwrap(URL(string: "ito://plugin/api/v1/cover")))
        let unpartitioned = ImagePipeline { $0.dataCache = disk }
        unpartitioned.cache.storeCachedData(Data([7]), for: plugin)

        for epoch in [nil, "", "not-an-epoch"] as [String?] {
            controller.install(epoch: epoch)
            let pipeline = try XCTUnwrap(recorder.latest)
            XCTAssertNil(pipeline.cache.cachedData(for: plugin))
            pipeline.cache.storeCachedData(Data([8]), for: plugin)
        }
        XCTAssertEqual(unpartitioned.cache.cachedData(for: plugin), Data([7]))
    }

    func testPendingOldImageCompletionCannotSatisfyANewEpochImageLoad() async throws {
        let oldStarted = expectation(description: "Old image requested")
        let currentStarted = expectation(description: "Current image requested")
        let oldDone = expectation(description: "Old image completed")
        let currentDone = expectation(description: "Current image completed")
        let loader = PendingEpochImageLoader(starts: [oldStarted, currentStarted])
        let recorder = PipelineRecorder()
        let controller = PluginImagePipelineController(
            dataCache: MemoryImageDataCache(), dataLoader: loader,
            diagnostics: NukeDiagnosticDelegate(), publish: { recorder.record($0) }
        )
        let request = ImageRequest(url: try XCTUnwrap(URL(string: "ito://plugin/api/v1/cover")))
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        controller.install(epoch: String(repeating: "a", count: 32))
        let old = try XCTUnwrap(recorder.latest)
        let oldTask = old.loadImage(with: request) { result in
            if case .failure = result { XCTFail("Old pipeline image failed") }
            oldDone.fulfill()
        }
        await fulfillment(of: [oldStarted], timeout: 5)
        controller.install(epoch: String(repeating: "b", count: 32))
        let current = try XCTUnwrap(recorder.latest)
        try loader.finishFirst(with: bytes)
        await fulfillment(of: [oldDone], timeout: 5)
        XCTAssertNotNil(old.cache.cachedImage(for: request))
        XCTAssertNil(current.cache.cachedImage(for: request))
        XCTAssertNil(current.cache.cachedData(for: request))

        let currentTask = current.loadImage(with: request) { result in
            if case .failure = result { XCTFail("Current pipeline image failed") }
            currentDone.fulfill()
        }
        await fulfillment(of: [currentStarted], timeout: 5)
        try loader.finishFirst(with: bytes)
        await fulfillment(of: [currentDone], timeout: 5)
        XCTAssertNotNil(current.cache.cachedImage(for: request))
        withExtendedLifetime((oldTask, currentTask)) {}
    }

    private func makeController(_ disk: MemoryImageDataCache, _ recorder: PipelineRecorder) -> PluginImagePipelineController {
        PluginImagePipelineController(
            dataCache: disk,
            dataLoader: DataLoader(configuration: .ephemeral),
            diagnostics: NukeDiagnosticDelegate(),
            publish: { recorder.record($0) }
        )
    }
}

nonisolated private final class PipelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: ImagePipeline?
    var latest: ImagePipeline? { lock.withLock { pipeline } }
    func record(_ pipeline: ImagePipeline) { lock.withLock { self.pipeline = pipeline } }
}

nonisolated private final class MemoryImageDataCache: DataCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func cachedData(for key: String) -> Data? { lock.withLock { data[key] } }
    func containsData(for key: String) -> Bool { lock.withLock { data[key] != nil } }
    func storeData(_ value: Data, for key: String) { lock.withLock { data[key] = value } }
    func removeData(for key: String) { lock.withLock { data[key] = nil } }
    func removeAll() { lock.withLock { data.removeAll() } }
}

nonisolated private final class PendingEpochImageLoader: DataLoading, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let url: URL
        let receive: @Sendable (Data, URLResponse) -> Void
        let complete: @Sendable (Error?) -> Void
    }
    private let lock = NSLock()
    private var starts: [XCTestExpectation]
    private var pending: [Pending] = []

    init(starts: [XCTestExpectation]) { self.starts = starts }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let id = UUID()
        let started = lock.withLock {
            pending.append(Pending(id: id, url: request.url!, receive: didReceiveData, complete: completion))
            return starts.removeFirst()
        }
        started.fulfill()
        return EpochImageSubscription { [weak self] in self?.cancel(id) }
    }

    func finishFirst(with data: Data) throws {
        let request = try XCTUnwrap(lock.withLock { pending.isEmpty ? nil : pending.removeFirst() })
        request.receive(data, URLResponse(url: request.url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
        request.complete(nil)
    }

    private func cancel(_ id: UUID) {
        let request = lock.withLock {
            pending.firstIndex(where: { $0.id == id }).map { pending.remove(at: $0) }
        }
        request?.complete(URLError(.cancelled))
    }
}

nonisolated private final class EpochImageSubscription: Cancellable {
    private let onCancel: @Sendable () -> Void
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}
