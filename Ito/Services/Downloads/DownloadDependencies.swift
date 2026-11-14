import Combine
import Foundation
import GRDB
import UIKit

/// Where offline chapters live: `Application Support/OfflineChapters`, or inside the UI-test fixture root,
/// as the database does. The directory is excluded from backup when the store prepares it.
@MainActor
enum OfflineChaptersLocation {
    static let directoryName = "OfflineChapters"

    static func rootURL(fileManager: FileManager = .default) throws -> URL {
        #if DEBUG
        if UITestLaunchConfiguration.current.isEnabled {
            let fixtureRoot = try UITestLaunchConfiguration.fixtureRootURL(fileManager: fileManager)
            return fixtureRoot.appendingPathComponent(directoryName, isDirectory: true)
        }
        #endif
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(directoryName, isDirectory: true)
    }
}

/// The download services one runtime owns. The store is shared: the composition root builds it once per
/// process and passes it to every stack, together with the one network path observer. Nothing runs until
/// the coordinator is started in the foreground.
@MainActor
struct DownloadStack {
    let store: OfflineChapterStore
    let coordinator: DownloadQueueCoordinator
    let center: DownloadCenter

    /// - Parameter predecessor: what the worker of a replaced runtime is still finishing.
    init(
        store: OfflineChapterStore,
        dbPool: DatabasePool,
        pluginManager: PluginManager,
        pluginSettings: PluginSettingsStore,
        path: any NetworkPathObserving,
        predecessor: Task<Void, Never>?
    ) {
        let progress = DownloadProgressBoard()
        let completion = pluginSettings.completionStore
        let cookies = pluginSettings.cookies
        let trust = pluginSettings.trust
        let cloudflare = LiveAppNetCloudflareHandler()
        let coordinator = DownloadQueueCoordinator(
            store: store,
            runtimes: pluginManager,
            makeModules: { pluginID, gate, recorder in
                PluginRunnerHostModules.download(
                    pluginID: pluginID,
                    cookieJar: cookies,
                    trust: trust,
                    gate: gate,
                    recorder: recorder,
                    cloudflareUserAgent: { host in await cloudflare.cachedUserAgent(for: host) }
                )
            },
            path: path,
            protectedData: UIApplicationProtectedDataAvailability(),
            protectedDataBecameAvailable: NotificationCenter.default
                .publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
                .map { _ in () }
                .eraseToAnyPublisher(),
            fetcher: URLSessionAssetFetcher(trust: trust, userAgent: CloudflareManager.defaultUserAgent),
            contexts: pluginSettings.networkContexts,
            progress: progress,
            predecessor: predecessor
        )
        let center = DownloadCenter(
            dbPool: dbPool,
            store: store,
            coordinator: coordinator,
            progress: progress,
            contexts: pluginSettings.networkContexts,
            observedPath: { path.current },
            captureEpoch: { pluginID in try completion.captureScopeEpoch(pluginID: pluginID) }
        )
        center.startObserving(scheduling: DelayedMainActorValueObservationScheduler.mainActor)
        self.store = store
        self.coordinator = coordinator
        self.center = center
    }
}
