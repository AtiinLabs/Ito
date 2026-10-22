import XCTest
import ito_runner
@testable import Ito

@MainActor
final class SearchRouteFactoryTests: XCTestCase {
    func testMangaDestinationConstructsMangaDetailFlow() async throws {
        let runner = ItoRunner()
        let context = SearchDetailLoadingSpy(runner: runner)
        let media = Manga(key: "manga-key", title: "Manga")
        let destination = SearchDestination.manga(
            pluginID: "plugin.manga",
            context: context,
            media: media
        )

        let route = SearchRouteFactory().route(for: destination)

        guard case .manga(let pluginID, let routeRunner, let routeMedia, let loader) = route else {
            return XCTFail("Expected manga detail route")
        }
        XCTAssertEqual(pluginID, "plugin.manga")
        XCTAssertTrue(routeRunner === runner)
        XCTAssertEqual(routeMedia.key, media.key)
        _ = try await loader(routeMedia)
        XCTAssertEqual(context.mangaLoadCount, 1)
        XCTAssertEqual(context.animeLoadCount, 0)
        XCTAssertEqual(context.novelLoadCount, 0)
    }

    func testAnimeDestinationConstructsAnimeDetailFlow() async throws {
        let runner = ItoRunner()
        let context = SearchDetailLoadingSpy(runner: runner)
        let media = Anime(key: "anime-key", title: "Anime")
        let destination = SearchDestination.anime(
            pluginID: "plugin.anime",
            context: context,
            media: media
        )

        let route = SearchRouteFactory().route(for: destination)

        guard case .anime(let pluginID, let routeRunner, let routeMedia, let loader) = route else {
            return XCTFail("Expected anime detail route")
        }
        XCTAssertEqual(pluginID, "plugin.anime")
        XCTAssertTrue(routeRunner === runner)
        XCTAssertEqual(routeMedia.key, media.key)
        _ = try await loader(routeMedia)
        XCTAssertEqual(context.mangaLoadCount, 0)
        XCTAssertEqual(context.animeLoadCount, 1)
        XCTAssertEqual(context.novelLoadCount, 0)
    }

    func testNovelDestinationConstructsNovelDetailFlow() async throws {
        let runner = ItoRunner()
        let context = SearchDetailLoadingSpy(runner: runner)
        let media = Novel(key: "novel-key", title: "Novel")
        let destination = SearchDestination.novel(
            pluginID: "plugin.novel",
            context: context,
            media: media
        )

        let route = SearchRouteFactory().route(for: destination)

        guard case .novel(let pluginID, let routeRunner, let routeMedia, let loader) = route else {
            return XCTFail("Expected novel detail route")
        }
        XCTAssertEqual(pluginID, "plugin.novel")
        XCTAssertTrue(routeRunner === runner)
        XCTAssertEqual(routeMedia.key, media.key)
        _ = try await loader(routeMedia)
        XCTAssertEqual(context.mangaLoadCount, 0)
        XCTAssertEqual(context.animeLoadCount, 0)
        XCTAssertEqual(context.novelLoadCount, 1)
    }

    func testDestinationPreservesPluginIDRunnerAndContextIdentity() {
        let runner = ItoRunner()
        let context = SearchDetailLoadingSpy(runner: runner)
        let destination = SearchDestination.manga(
            pluginID: "plugin.identity",
            context: context,
            media: Manga(key: "key", title: "Title")
        )

        XCTAssertEqual(destination.pluginID, "plugin.identity")
        XCTAssertTrue(destination.context.runner === runner)
        XCTAssertTrue(destination.context === context)
    }

    func testSourceRouteFactoryPreservesTypedPayloadRunnerAndCanonicalID() {
        let runner = ItoRunner()
        let context = ItoRunnerSourceContext(runner: runner)
        let media = ResolvedPluginMedia.manga(
            Manga(key: "source-key", title: "Source")
        )

        let route = SourceRouteFactory().route(
            media: media,
            pluginID: "plugin.source",
            context: context,
            anilistID: 123
        )

        XCTAssertEqual(route.pluginID, "plugin.source")
        XCTAssertEqual(route.media.key(), "source-key")
        XCTAssertTrue(route.runner === runner)
        XCTAssertEqual(route.anilistID, 123)
    }

    func testSourceRouteConstructionContainsNoTypeErasureOrManagerLookup() throws {
        let source = try sourceFile(
            "Ito/ViewModels/Discover/SourceResolverViewModel.swift"
        )

        XCTAssertFalse(source.contains("AnyView"))
        XCTAssertFalse(source.contains("PluginManager"))
        XCTAssertFalse(source.contains("getRunner"))
    }

    func testRecommendationNavigationUsesTheDiscoverDetailFactory() throws {
        let source = try sourceFile("Ito/Views/Discover/DiscoverDetailView.swift")

        XCTAssertTrue(source.contains("viewFactory.makeDiscoverDetailView(media: recMedia)"))
        XCTAssertFalse(source.contains("destination: DiscoverDetailView("))
    }

    func testSearchModelsAndViewModelContainNoSwiftUIDestinationValues() throws {
        let modelSource = try sourceFile("Ito/Models/SearchModels.swift")
        let viewModelSource = try sourceFile("Ito/ViewModels/SearchViewModel.swift")

        for source in [modelSource, viewModelSource] {
            XCTAssertFalse(source.contains("AnyView"))
            XCTAssertFalse(source.contains("MediaDetailView"))
            XCTAssertFalse(source.contains("import SwiftUI"))
        }
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

@MainActor
private final class SearchDetailLoadingSpy: SearchDetailLoading {
    let runner: ItoRunner
    private(set) var mangaLoadCount = 0
    private(set) var animeLoadCount = 0
    private(set) var novelLoadCount = 0

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func loadManga(_ manga: Manga) async throws -> Manga {
        mangaLoadCount += 1
        return manga
    }

    func loadAnime(_ anime: Anime) async throws -> Anime {
        animeLoadCount += 1
        return anime
    }

    func loadNovel(_ novel: Novel) async throws -> Novel {
        novelLoadCount += 1
        return novel
    }
}
