import XCTest
import Nuke
@testable import Ito
import ito_runner

final class AtsuPluginLiveImageIntegrationTests: XCTestCase {

    /// Opt-in live test suite.
    /// To run: `ITO_RUN_ATSU_LIVE_IMAGE_TESTS=1 xcodebuild test ...`
    private var isOptedIn: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ITO_RUN_ATSU_LIVE_IMAGE_TESTS"] == "1"
            || env["TEST_RUNNER_ITO_RUN_ATSU_LIVE_IMAGE_TESTS"] == "1"
            || env["RUN_ATSU_LIVE_IMAGE_TESTS"] == "1"
    }

    private let freshPluginPath = "/tmp/ito-image-investigation/community-sources-fresh/plugins/atsumaru/atsumaru.ito"

    func testLiveAtsumaruPlugin_SeriesAndPageImageDiagnostics() async throws {
        guard isOptedIn else {
            // NOT EXECUTED unless explicitly opted in
            print("[INFO] AtsuPluginLiveImageIntegrationTests: NOT EXECUTED (ITO_RUN_ATSU_LIVE_IMAGE_TESTS != 1)")
            return
        }

        // 1. Verify plugin file exists from fresh community build
        let pluginURL = URL(fileURLWithPath: freshPluginPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshPluginPath),
            "Fresh atsumaru.ito must exist at \(freshPluginPath). Build it first with ito-pkg pack."
        )

        // 2. Load runner using ItoRunner configured with AppNetModule and loadBundle
        let runner = ItoRunner()
        await runner.setNetModule(AppNetModule(
            pluginID: "com.kunihir0.ito.atsumaru",
            cookieJar: PluginCookieJar(keychain: InMemoryPluginSecretKeychain()),
            trust: PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        ))
        await runner.setStdModule(DefaultStdModule())
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setWebviewModule(AppWebviewModule())
        _ = try await runner.loadBundle(from: pluginURL)
        // 3. Request manga update (details + chapters) for user's sample "YMv6"
        let manga = Manga(key: "YMv6", title: "", status: .Unknown, contentRating: .Safe)
        let updatedManga = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)

        XCTAssertFalse(updatedManga.title.isEmpty, "Manga title must not be empty")
        let chapters = try XCTUnwrap(updatedManga.chapters, "Manga must have chapters")
        XCTAssertGreaterThan(chapters.count, 0, "Manga must have parsed chapters")

        // 4. Test Poster Image
        if let coverURLString = updatedManga.cover, let coverURL = URL(string: coverURLString) {
            print("[DIAG] Testing poster URL scheme=\(coverURL.scheme ?? "nil") host=\(coverURL.host ?? "nil") pathExtension=\(coverURL.pathExtension)")

            // (A) Plain URLSession with redirect following
            let (data, response) = try await URLSession.shared.data(from: coverURL)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? -1
            let mimeType = httpResp?.mimeType ?? "unknown"
            print("[DIAG] Poster URLSession statusCode=\(statusCode) mime=\(mimeType) bytes=\(data.count)")
            XCTAssertEqual(statusCode, 200, "Poster should return HTTP 200 after redirect")

            // (B) Production Nuke pipeline
            do {
                let nukeResponse = try await ImagePipeline.shared.image(for: ImageRequest(url: coverURL))
                print("[DIAG] Poster Nuke SUCCESS size=\(nukeResponse.size)")
                XCTAssertGreaterThan(nukeResponse.size.width, 0)
            } catch {
                print("[DIAG] Poster Nuke FAILURE: \(error)")
                XCTFail("Poster image failed in Nuke: \(error)")
            }
        } else {
            XCTFail("No cover URL returned for manga")
        }

        // 5. Select first chapter and get page list
        let firstChapter = chapters[0]
        let pages = try await runner.getPageList(manga: updatedManga, chapter: firstChapter)
        XCTAssertGreaterThan(pages.count, 0, "Chapter must have pages")

        // 6. Test first 3 pages
        let testPages = Array(pages.prefix(3))
        for (idx, page) in testPages.enumerated() {
            guard case .url(let pageURLString) = page.content, let pageURL = URL(string: pageURLString) else {
                XCTFail("Page \(idx) does not have a valid URL")
                continue
            }

            print("[DIAG] Page \(idx) URL host=\(pageURL.host ?? "nil") path=\(pageURL.path) headers=\(String(describing: page.headers))")

            // (A) Test direct URLSession fetch
            let (pageData, pageResponse) = try await URLSession.shared.data(from: pageURL)
            let pageHttpResp = pageResponse as? HTTPURLResponse
            let pageStatus = pageHttpResp?.statusCode ?? -1
            let pageMIME = pageHttpResp?.mimeType ?? "none"
            let isHTML = pageData.starts(with: "<".utf8)
            print("[DIAG] Page \(idx) URLSession status=\(pageStatus) mime=\(pageMIME) bytes=\(pageData.count) isHTML=\(isHTML)")

            // (B) Test Nuke Pipeline with visible MangaImage request
            var request = URLRequest(url: pageURL)
            if let customHeaders = page.headers, !customHeaders.isEmpty {
                for (k, v) in customHeaders {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            } else {
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue(pageURLString, forHTTPHeaderField: "Referer")
            }

            do {
                let imgResponse = try await ImagePipeline.shared.image(for: ImageRequest(urlRequest: request))
                print("[DIAG] Page \(idx) Nuke SUCCESS: size=\(imgResponse.size)")
            } catch {
                print("[DIAG] Page \(idx) Nuke FAILURE: \(error)")
                // Document the actual Nuke failure cleanly
                XCTFail("Page \(idx) failed in Nuke pipeline: \(error) (HTTP status was \(pageStatus), host was \(pageURL.host ?? ""))")
            }
        }
    }
}
