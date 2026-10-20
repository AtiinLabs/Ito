import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class VideoPlayerServiceTests: XCTestCase {
    func testPlayerAssetOptionsPreservePluginHeadersExactly() throws {
        let headers = [
            "Authorization": "Bearer exact-token",
            "Referer": "https://exact.example/referrer"
        ]
        let selectedVideo = video(
            "https://exact.example/video.m3u8",
            headers: headers
        )

        let options = AVPlayerVideoPlaybackCoordinator.assetOptions(for: selectedVideo)

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String], headers)
        XCTAssertTrue(
            AVPlayerVideoPlaybackCoordinator.assetOptions(for: video("stream")).isEmpty
        )
    }

    func testPlaybackCoordinatorContractPrepareReplaceObservePauseAndShutdown() async {
        let coordinator = VideoPlaybackCoordinatorFake()
        var updates: [(Double, Double)] = []
        let first = await coordinator.prepare(video: video("first"))
        XCTAssertNotNil(first)
        XCTAssertTrue(
            coordinator.activate(try XCTUnwrap(first), startTime: nil) { time, duration in
                updates.append((time, duration))
            }
        )
        coordinator.emit(currentTime: 4, duration: 10)

        let second = await coordinator.prepare(video: video("second"))
        XCTAssertTrue(
            coordinator.activate(try XCTUnwrap(second), startTime: nil) { time, duration in
                updates.append((time, duration))
            }
        )
        coordinator.emit(currentTime: 8, duration: 10)
        coordinator.pause()
        coordinator.shutdown()
        coordinator.shutdown()
        coordinator.emit(currentTime: 9, duration: 10)

        XCTAssertEqual(coordinator.requests.map { $0.video.url }, ["first", "second"])
        XCTAssertEqual(coordinator.activatedPreparationIDs, ["first", "second"])
        XCTAssertEqual(coordinator.observerInstallCount, 1)
        XCTAssertEqual(coordinator.replacementCount, 1)
        XCTAssertEqual(coordinator.playCount, 2)
        XCTAssertEqual(coordinator.pauseCount, 3)
        XCTAssertEqual(coordinator.observerRemovalCount, 1)
        XCTAssertEqual(updates.map { $0.0 }, [4, 8])
        XCTAssertEqual(updates.map { $0.1 }, [10, 10])
    }

    func testSubtitleAdapterLoadsExactURLAsUTF8WithoutRealNetwork() async throws {
        let host = "subtitle-\(UUID().uuidString.lowercased()).example.invalid"
        let url = try XCTUnwrap(URL(string: "https://\(host)/exact.vtt?token=private"))
        VideoSubtitleURLProtocol.register(
            data: Data("WEBVTT\n\ncue".utf8),
            forHost: host
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoSubtitleURLProtocol.self]
        let loader = URLSessionVideoSubtitleLoader(
            session: URLSession(configuration: configuration)
        )

        let text = try await loader.text(from: url.absoluteString)

        XCTAssertEqual(text, "WEBVTT\n\ncue")
        XCTAssertEqual(VideoSubtitleURLProtocol.lastURL(forHost: host), url)
    }

    func testSubtitleAdapterRejectsNonUTF8DataNonfatallyAtBoundary() async throws {
        let host = "subtitle-\(UUID().uuidString.lowercased()).example.invalid"
        let url = try XCTUnwrap(URL(string: "https://\(host)/invalid.vtt"))
        VideoSubtitleURLProtocol.register(data: Data([0xFF, 0xFE]), forHost: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoSubtitleURLProtocol.self]
        let loader = URLSessionVideoSubtitleLoader(
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await loader.text(from: url.absoluteString)
            XCTFail("Expected non-UTF8 failure")
        } catch {
            XCTAssertTrue(error is VideoSubtitleLoaderError)
        }
    }
}

private class VideoSubtitleURLProtocol: URLProtocol {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var dataByHost: [String: Data] = [:]
    nonisolated(unsafe) private static var urlByHost: [String: URL] = [:]

    nonisolated static func register(data: Data, forHost host: String) {
        lock.withLock {
            dataByHost[host] = data
            urlByHost[host] = nil
        }
    }

    nonisolated static func lastURL(forHost host: String) -> URL? {
        lock.withLock { urlByHost[host] }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { dataByHost[host] != nil }
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let data = Self.lock.withLock({ Self.dataByHost[host] }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lock.withLock { Self.urlByHost[host] = url }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}
