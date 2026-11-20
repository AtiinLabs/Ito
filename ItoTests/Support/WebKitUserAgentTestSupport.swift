import Foundation
import Nuke
import ito_runner
@testable import Ito

extension WebKitUserAgent {
    /// A user agent authority that never creates a web view: its probe answers `value` at once.
    static func testing(_ value: String? = "Ito-Test-Agent/1") -> WebKitUserAgent {
        WebKitUserAgent(probe: { value })
    }
}

// Production initializers take the host's one user agent authority and sign-in capability explicitly. Tests that
// don't exercise either construct their own here, so a production caller can never fall back to a second instance.

@MainActor
extension PluginManager {
    convenience init(
        pluginSettingsStore: PluginSettingsStore,
        pluginsDirectory: URL? = nil,
        runnerLoader: (@MainActor (
            _ pluginID: String,
            _ pluginURL: URL,
            _ settingsStore: PluginSettingsStore
        ) async throws -> ItoRunner)? = nil,
        downloadRunnerLoader: DownloadRunnerLoader? = nil,
        directoryGate: PluginDirectoryGate? = nil,
        packageReader: PluginPackageReader? = nil,
        supportedABI: ClosedRange<Int> = ItoRunner.supportedABIVersions,
        websiteContexts: SourceWebsiteContexts = SourceWebsiteContexts()
    ) {
        self.init(
            pluginSettingsStore: pluginSettingsStore,
            pluginsDirectory: pluginsDirectory,
            runnerLoader: runnerLoader,
            downloadRunnerLoader: downloadRunnerLoader,
            directoryGate: directoryGate,
            packageReader: packageReader,
            supportedABI: supportedABI,
            websiteContexts: websiteContexts,
            webKitUserAgent: .testing()
        )
    }
}

@MainActor
extension PluginDataLoader {
    convenience init(
        configuration: URLSessionConfiguration,
        trust: PluginTrustStore? = nil,
        contexts: PluginNetworkContexts,
        defaultLoader: (any DataLoading)? = nil,
        runnerProvider: @escaping @Sendable (String) async throws -> any PluginImageRunner,
        runnerEvictor: (@Sendable (String, any PluginImageRunner) async -> Void)? = nil
    ) {
        self.init(
            configuration: configuration,
            trust: trust,
            contexts: contexts,
            defaultLoader: defaultLoader,
            runnerProvider: runnerProvider,
            runnerEvictor: runnerEvictor,
            userAgent: .testing()
        )
    }
}

extension PluginImageTransport {
    convenience init(configuration: URLSessionConfiguration = .ephemeral, trust: PluginTrustStore? = nil) {
        self.init(configuration: configuration, trust: trust, userAgent: .testing())
    }
}

extension PolicyDataLoader {
    convenience init(configuration: URLSessionConfiguration) {
        self.init(configuration: configuration, userAgent: .testing())
    }
}

@MainActor
extension MediaDetailReaderViewFactory {
    init(
        mangaReaderDependencies: PreparedMangaReaderDependencies,
        novelReaderDependencies: PreparedNovelReaderDependencies = .unavailable(),
        videoPlayerDependencies: PreparedVideoPlayerDependencies = .unavailable(),
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        downloads: any MediaDetailDownloadServing = UnavailableMediaDetailDownloads(),
        connectivity: any ConnectivityServing = UnavailableConnectivity(),
        networkContexts: PluginNetworkContexts
    ) {
        self.init(
            mangaReaderDependencies: mangaReaderDependencies,
            novelReaderDependencies: novelReaderDependencies,
            videoPlayerDependencies: videoPlayerDependencies,
            offlineReading: offlineReading,
            downloads: downloads,
            connectivity: connectivity,
            networkContexts: networkContexts,
            signIn: .unavailable
        )
    }
}
