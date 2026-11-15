import ito_runner

/// The configured network and prefetch values, as the policy reads them. A value snapshot of the
/// `AppSettingsStore` preferences, never a second source of truth: the store publishes it after it stored
/// the values, and nothing derived from it is persisted.
nonisolated struct NetworkPolicyConfiguration: Equatable, Sendable {
    var downloadMode: NetworkDownloadMode
    /// Automatic metadata checks are skipped on an expensive path.
    var wifiOnlyUpdates: Bool
    /// Pages preloaded ahead of the open one, 0 for none.
    var preloadImageCount: Int
    /// Adjacent page lists to prefetch: zero, next only, or next and previous.
    var adjacentChapterPrefetch: Int
    var novelPrefetchChapters: Bool

    /// The documented defaults, which a reset restores.
    static let defaults = NetworkPolicyConfiguration(
        downloadMode: AppPreferenceCatalog.networkDownloadMode.defaultValue,
        wifiOnlyUpdates: AppPreferenceCatalog.wifiOnlyUpdates.defaultValue,
        preloadImageCount: AppPreferenceCatalog.preloadImageCount.defaultValue.rawValue,
        adjacentChapterPrefetch: AppPreferenceCatalog.adjacentChapterPrefetchCount.defaultValue.rawValue,
        novelPrefetchChapters: AppPreferenceCatalog.novelPrefetchChapters.defaultValue
    )
}

/// What a request is for. The host decides it where the operation starts; a source never raises its own.
nonisolated enum NetworkIntent: Equatable, Sendable, CaseIterable {
    /// What the user is looking at or asked for just now: the open chapter, a manual refresh, a search.
    case interactive
    /// A batch the user confirmed.
    case manualBulkDownload
    /// Downloads queued by a rule rather than by a tap. They never mint a consent.
    case automaticBulkDownload
    /// Library update checks the user did not just ask for.
    case automaticMetadata
    /// Work done ahead of the reader: preloaded images, neighbor chapters.
    case speculativePrefetch
}

/// Why a request waits. Closed: the evaluator is the only producer. Each reason maps to the job's waiting
/// reason and to the host policy outcome a download module refuses with.
nonisolated enum NetworkDeferral: Equatable, Sendable, CaseIterable {
    case networkUnknown
    case noConnection
    /// An expensive path while the configuration keeps this work off it.
    case meteredNetwork
    /// An expensive path and the batch has not been confirmed for it yet.
    case meteredConsentRequired
    case lowDataMode
    /// Automatic checks are limited to Wi-Fi and the path is expensive.
    case wifiOnlyUpdates

    /// Every waiting reason a network condition can set. A cleared condition readmits exactly these.
    static let networkWaitingReasons = Set(allCases.map(\.waitingReason))

    var waitingReason: DownloadWaitingReason {
        switch self {
        case .networkUnknown:
            return .networkUnknown
        case .noConnection:
            return .noConnection
        case .meteredNetwork, .meteredConsentRequired, .wifiOnlyUpdates:
            return .meteredNetwork
        case .lowDataMode:
            return .lowDataMode
        }
    }

    var policyOutcome: HostNetworkPolicyOutcome {
        switch self {
        case .networkUnknown:
            return .deferred(.unknownPath)
        case .noConnection:
            return .deferred(.offline)
        case .meteredNetwork, .meteredConsentRequired, .wifiOnlyUpdates:
            return .deferred(.expensivePath)
        case .lowDataMode:
            return .deferred(.constrainedPath)
        }
    }

    /// Whether only the batch that lacks the consent waits. Every other deferral holds the whole queue, because
    /// it is the same for every batch.
    var isBatchSpecific: Bool {
        self == .meteredConsentRequired
    }
}

/// Whether a request may start or continue on the current path.
nonisolated enum NetworkDecision: Equatable, Sendable {
    case allow
    case wait(NetworkDeferral)

    var deferral: NetworkDeferral? {
        if case .wait(let deferral) = self { return deferral }
        return nil
    }
}

/// What the configuration and the current path allow right now, for the settings screen. An ephemeral
/// projection: it is recomputed from the stored values and the path, and never written back, so a path that
/// changes back restores the configured amounts without any preference write.
nonisolated struct NetworkEffectiveProjection: Equatable, Sendable {
    /// A batch the user confirmed, with no scoped consent.
    var bulkDownloads: NetworkDecision
    var automaticChecks: NetworkDecision
    /// Whether speculative work may run on this path at all.
    var speculative: NetworkDecision
    var imagePreloadCount: Int
    var adjacentChapterPrefetch: Int
    var novelPrefetch: Bool
    /// The configured adjacent amount is positive but the image preload is off, which keeps it at zero.
    var adjacentHeldByPreload: Bool
}

/// The one pure network decision. It decides from the configured values, the observed path, the intent and
/// whether the exact batch holds a valid consent. Precedence, strongest first:
///
/// 1. No usable path (`unsatisfied`, `requiresConnection`) defers every remote request. Verified local reading is
///    not a remote request and never reaches this rule.
/// 2. An unknown path is not offline: interactive work may attempt, everything else waits for a reading.
/// 3. Interactive work is otherwise admitted. Only a hard block or a security denial, which are decided elsewhere,
///    stops it.
/// 4. A constrained path (Low Data Mode) defers bulk, automatic and speculative work. No consent or mode overrides it.
/// 5. An expensive path follows the intent: the download mode governs bulk work, Wi-Fi-only governs automatic
///    metadata, speculative work never uses it. A valid batch consent satisfies only the mode, and only for bulk.
nonisolated enum NetworkPolicy {
    static func evaluate(
        _ intent: NetworkIntent,
        path: NetworkPathSnapshot,
        configuration: NetworkPolicyConfiguration,
        hasBatchConsent: Bool = false
    ) -> NetworkDecision {
        switch path.status {
        case .unsatisfied, .requiresConnection:
            return .wait(.noConnection)
        case .unknown:
            return intent == .interactive ? .allow : .wait(.networkUnknown)
        case .satisfied:
            break
        }
        guard intent != .interactive else { return .allow }
        // Low Data Mode is never overridden by a mode or a metered consent.
        if path.isConstrained { return .wait(.lowDataMode) }
        if path.isExpensive, let deferral = expensiveDeferral(intent, configuration: configuration, hasBatchConsent: hasBatchConsent) {
            return .wait(deferral)
        }
        return .allow
    }

    private static func expensiveDeferral(
        _ intent: NetworkIntent,
        configuration: NetworkPolicyConfiguration,
        hasBatchConsent: Bool
    ) -> NetworkDeferral? {
        switch intent {
        case .interactive:
            return nil
        case .manualBulkDownload:
            switch configuration.downloadMode {
            case .unmeteredOnly: return .meteredNetwork
            case .askMetered: return hasBatchConsent ? nil : .meteredConsentRequired
            case .allowMetered: return nil
            }
        case .automaticBulkDownload:
            switch configuration.downloadMode {
            case .unmeteredOnly: return .meteredNetwork
            case .askMetered: return hasBatchConsent ? nil : .meteredNetwork
            case .allowMetered: return nil
            }
        case .automaticMetadata:
            return configuration.wifiOnlyUpdates ? .wifiOnlyUpdates : nil
        case .speculativePrefetch:
            return .meteredNetwork
        }
    }

    static func projection(configuration: NetworkPolicyConfiguration, path: NetworkPathSnapshot) -> NetworkEffectiveProjection {
        let speculative = evaluate(.speculativePrefetch, path: path, configuration: configuration)
        let allowsSpeculative = speculative == .allow
        let preload = allowsSpeculative ? configuration.preloadImageCount : 0
        // The image preload is the master switch of speculative manga work: a manifest prefetch of a neighbor
        // chapter is speculative work too, so zero images means no neighbors either.
        let adjacent = allowsSpeculative && configuration.preloadImageCount > 0 ? configuration.adjacentChapterPrefetch : 0
        return NetworkEffectiveProjection(
            bulkDownloads: evaluate(.manualBulkDownload, path: path, configuration: configuration),
            automaticChecks: evaluate(.automaticMetadata, path: path, configuration: configuration),
            speculative: speculative,
            imagePreloadCount: preload,
            adjacentChapterPrefetch: adjacent,
            novelPrefetch: allowsSpeculative && configuration.novelPrefetchChapters,
            adjacentHeldByPreload: configuration.preloadImageCount == 0 && configuration.adjacentChapterPrefetch > 0
        )
    }
}
