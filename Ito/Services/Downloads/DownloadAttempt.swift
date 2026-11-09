import Foundation
import ito_runner

/// A failure that ends an attempt with an outcome the store has not recorded yet.
nonisolated struct DownloadAttemptFailure: Error, Equatable, Sendable {
    let outcome: DownloadAttemptOutcome
}

/// How far an attempt has got. Held in memory only, never persisted.
nonisolated struct DownloadProgress: Equatable, Sendable {
    let jobID: String
    let completedPages: Int
    let totalPages: Int
    let bytes: Int64
}

/// Receives progress on the main actor, where the progress board lives.
typealias DownloadProgressSink = @MainActor @Sendable (DownloadProgress) -> Void

/// What a finished attempt hands the coordinator: the staged pages and the in-transaction check that
/// publishes them. Publishing is not part of the attempt, so cancelling the attempt never reaches it.
nonisolated struct DownloadAttemptCompletion: Sendable {
    let staging: OfflineStagingAttempt
    let commitGuard: OfflineCommitGuard
}

/// One attempt to download one chapter. It lists the pages on a dedicated runner and streams each page
/// into the attempt's staging directory in order. The coordinator then publishes, outside the attempt's
/// cancellation scope. Nothing here reads or writes the reader's image caches, the foreground runners,
/// or the network outside its own transport.
actor DownloadAttempt {
    static let maximumPages = 2_000
    static let maximumTextBytes = 8 * 1_024 * 1_024

    private let job: DownloadJobRecord
    private let staging: OfflineStagingAttempt
    private let store: OfflineChapterStore
    private let runtime: DownloadPluginRuntime
    private let fetcher: any DirectAssetFetching
    private let recorder: DownloadPolicyRecorder
    private let admission: any DownloadAdmissionGate
    private let progress: DownloadProgressSink
    private var imageRunner: (any PluginImageRunner)?

    init(
        job: DownloadJobRecord,
        staging: OfflineStagingAttempt,
        store: OfflineChapterStore,
        runtime: DownloadPluginRuntime,
        fetcher: any DirectAssetFetching,
        recorder: DownloadPolicyRecorder,
        admission: any DownloadAdmissionGate,
        progress: @escaping DownloadProgressSink
    ) {
        self.job = job
        self.staging = staging
        self.store = store
        self.runtime = runtime
        self.fetcher = fetcher
        self.recorder = recorder
        self.admission = admission
        self.progress = progress
    }

    /// Runs the attempt through its final checks and returns what the publish needs. The caller abandons
    /// the attempt with the outcome of a thrown `DownloadAttemptFailure`, and treats `CancellationError` as
    /// a cancellation. A recorded transport denial always wins over what the plugin reported, and a
    /// cancelled task always ends as a cancellation, whatever error the cancelled work surfaced.
    func run() async throws -> DownloadAttemptCompletion {
        do {
            return try await execute()
        } catch {
            if let denial = recorder.firstDenial {
                throw DownloadAttemptFailure(outcome: denial.outcome)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if error is CancellationError || error is DownloadAttemptFailure {
                throw error
            }
            throw DownloadAttemptFailure(outcome: Self.outcome(for: error))
        }
    }

    private func execute() async throws -> DownloadAttemptCompletion {
        let decoder = JSONDecoder()
        let entry = try decoder.decode(MediaEntry.self, from: job.entrySnapshot)
        let chapter = try decoder.decode(Chapter.self, from: job.chapterSnapshot)

        try await admit()
        let pages = runtime.pages
        let listed = try await pluginCall {
            try await pages.getChapterPages(entry: entry, chapter: chapter)
        }
        try throwIfDenied()

        let ordered = ReaderPageOrdering.ascending(listed)
        guard !ordered.isEmpty else {
            throw DownloadAttemptFailure(outcome: .failed(.emptyChapter))
        }
        guard ordered.count <= Self.maximumPages else {
            throw DownloadAttemptFailure(outcome: .failed(.tooManyPages))
        }

        var bytes: Int64 = 0
        await report(completed: 0, total: ordered.count, bytes: 0)
        for (completed, page) in ordered.enumerated() {
            try await admit()
            let (input, pageBytes) = try await materialize(page)
            do {
                try Task.checkCancellation()
                try await staging.append(input)
            } catch {
                Self.discardTemporaryFile(input)
                throw error
            }
            bytes += pageBytes
            await report(completed: completed + 1, total: ordered.count, bytes: bytes)
        }

        try throwIfDenied()
        try requirePluginCurrent()
        let isPluginCurrent = runtime.isPluginCurrent
        let isTrustCurrent = runtime.isTrustCurrent
        return DownloadAttemptCompletion(staging: staging) { _ in
            isPluginCurrent() && isTrustCurrent()
        }
    }

    /// Checks made before every page: a recorded denial, the plugin, the network path, and free space.
    private func admit() async throws {
        try Task.checkCancellation()
        try throwIfDenied()
        try requirePluginCurrent()
        if case .wait(let reason) = admission.admission() {
            throw DownloadAttemptFailure(outcome: .waiting(reason))
        }
        try await store.ensureCapacityForNextAsset()
    }

    private func throwIfDenied() throws {
        if let denial = recorder.firstDenial {
            throw DownloadAttemptFailure(outcome: denial.outcome)
        }
    }

    /// The publication check is global: any plugin install or refresh moves it. The attempt then requeues
    /// rather than waiting, because the next attempt builds a fresh runtime and re-runs every check. A
    /// plugin that is really gone fails that runtime load and lands in `waiting(sourceUnavailable)`.
    private func requirePluginCurrent() throws {
        guard runtime.isPluginCurrent() else {
            throw DownloadAttemptFailure(outcome: .queued)
        }
    }

    /// Turns one listed page into staged input. The returned byte count is what the page adds to the
    /// progress total. A temporary file in the input is owned by the caller until `append` moves it.
    private func materialize(_ page: Page) async throws -> (OfflinePageInput, Int64) {
        let description = page.hasDescription ? page.description : nil
        switch page.content {
        case .text(let text):
            let data = Data(text.utf8)
            guard data.count <= Self.maximumTextBytes else {
                throw DownloadAttemptFailure(outcome: .failed(.assetTooLarge))
            }
            let input = OfflinePageInput(content: .text(data), sourceIndex: page.index, description: description)
            return (input, Int64(data.count))
        case .url(let locator):
            guard let url = URL(string: locator) else {
                throw DownloadAttemptFailure(outcome: .failed(.unsupportedPageLocator))
            }
            switch try await fetchAsset(url, headers: page.headers) {
            case .data(let data):
                guard Int64(data.count) <= URLSessionAssetFetcher.maximumAssetBytes else {
                    throw DownloadAttemptFailure(outcome: .failed(.assetTooLarge))
                }
                let input = OfflinePageInput(content: .image(data), sourceIndex: page.index, description: description)
                return (input, Int64(data.count))
            case .file(let file):
                let input = OfflinePageInput(content: .imageFile(file), sourceIndex: page.index, description: description)
                let size = (try? URLSessionAssetFetcher.byteCount(ofFile: file)) ?? 0
                return (input, size)
            }
        }
    }

    private func fetchAsset(_ url: URL, headers: [String: String]?) async throws -> FetchedAsset {
        switch url.scheme?.lowercased() {
        case "ito":
            let locator: PluginImageLocator
            do {
                locator = try PluginImageLocator.parse(url)
            } catch {
                throw DownloadAttemptFailure(outcome: .failed(.unsupportedPageLocator))
            }
            // A page may only be resolved by the plugin that listed it.
            guard locator.pluginID == job.pluginId else {
                throw DownloadAttemptFailure(outcome: .failed(.unsupportedPageLocator))
            }
            let resolver = try await imageRunnerForAttempt()
            switch try await PluginImageResolution.resolve(locator, runner: resolver) {
            case .fetch(let target, let targetHeaders, let allowedOrigins):
                return try await transfer {
                    try await fetcher.fetchPluginImage(
                        url: target,
                        headers: targetHeaders,
                        allowedOrigins: allowedOrigins,
                        pluginID: job.pluginId
                    )
                }
            case .bytes(let data):
                return .data(data)
            case .direct(let realURL):
                return try await transfer { try await fetcher.fetchDirect(Self.request(url: realURL, headers: headers)) }
            }
        case "http", "https":
            return try await transfer { try await fetcher.fetchDirect(Self.request(url: url, headers: headers)) }
        default:
            throw DownloadAttemptFailure(outcome: .failed(.unsupportedPageLocator))
        }
    }

    /// Runs one transfer. A failure that is not the attempt's own re-reads the network path, so a path
    /// that stopped admitting bulk work waits instead of failing, and maps the image transport's errors.
    private func transfer(_ body: () async throws -> FetchedAsset) async throws -> FetchedAsset {
        do {
            return try await body()
        } catch {
            if error is CancellationError || error is DownloadAttemptFailure {
                throw error
            }
            if case .wait(let reason) = admission.admission() {
                throw DownloadAttemptFailure(outcome: .waiting(reason))
            }
            if let transportError = error as? PluginImageTransportError {
                throw DownloadAttemptFailure(outcome: Self.outcome(for: transportError))
            }
            throw error
        }
    }

    /// The image runner is created on first use and kept for this attempt only.
    private func imageRunnerForAttempt() async throws -> any PluginImageRunner {
        if let imageRunner {
            return imageRunner
        }
        let created = try await runtime.makeImageRunner()
        imageRunner = created
        return created
    }

    private func report(completed: Int, total: Int, bytes: Int64) async {
        await progress(DownloadProgress(
            jobID: job.id,
            completedPages: completed,
            totalPages: total,
            bytes: bytes
        ))
    }

    private static func request(url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func discardTemporaryFile(_ input: OfflinePageInput) {
        if case .imageFile(let file) = input.content {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Maps an error the attempt did not raise itself to the outcome it implies. Full storage and a
    /// locked device wait; a network error waits when the system names the path, and otherwise fails.
    nonisolated static func outcome(for error: Error) -> DownloadAttemptOutcome {
        if let failure = error as? DownloadAttemptFailure {
            return failure.outcome
        }
        if let storeError = error as? OfflineStoreError {
            switch storeError {
            case .blocked(let reason):
                return .waiting(reason)
            case .protectedDataUnavailable:
                return .waiting(.protectedDataUnavailable)
            case .reconciliationPending, .jobUnavailable, .notVerified, .damaged, .versionUnavailable:
                return .failed(.fileSystem)
            }
        }
        if let fileError = error as? OfflineFileSystemError {
            switch fileError {
            case .noSpace:
                return .waiting(.insufficientStorage)
            case .permissionDenied:
                return .waiting(.protectedDataUnavailable)
            case .notFound, .other:
                return .failed(.fileSystem)
            }
        }
        if let transportError = error as? PluginImageTransportError {
            switch transportError {
            case .invalidURL, .unpermittedScheme:
                return .failed(.unsupportedPageLocator)
            case .userInfoNotAllowed, .unpermittedOrigin, .invalidHeaderName, .invalidHeaderValue, .prohibitedHeader:
                // The plugin asked for a request the host refuses to make.
                return .failed(.sourceError)
            case .badServerResponse:
                return .failed(.httpStatus)
            case .crossOriginRedirectBlocked, .httpsDowngradeBlocked, .nonHTTPResponse, .downloadFailed:
                return .failed(.network)
            }
        }
        if let assetError = error as? ChapterAssetError {
            switch assetError {
            case .httpStatus:
                return .failed(.httpStatus)
            case .tooLarge:
                return .failed(.assetTooLarge)
            }
        }
        if error is OfflineStagingError {
            return .failed(.unsupportedImageFormat)
        }
        if error is OfflinePublishError || error is OfflineManifestError || error is DecodingError {
            return .failed(.integrityMismatch)
        }
        if let urlError = error as? URLError {
            switch urlError.networkUnavailableReason {
            case .expensive?:
                return .waiting(.meteredNetwork)
            case .constrained?:
                return .waiting(.lowDataMode)
            default:
                break
            }
            if urlError.code == .badURL || urlError.code == .unsupportedURL {
                return .failed(.unsupportedPageLocator)
            }
            return .failed(.network)
        }
        return .failed(.sourceError)
    }
}
