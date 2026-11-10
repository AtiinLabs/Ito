import Combine
import Foundation

/// The manager owns observation only while either its root or a series screen is visible.
@MainActor
final class DownloadsViewModel: ObservableObject {
    @Published private(set) var snapshot = DownloadsSnapshot()
    @Published private(set) var availableBytes: Int64?
    @Published private(set) var isWorking = false
    @Published var message: String?
    @Published var selectedSeries: Set<MediaIdentity> = []
    @Published var selectedJobs: Set<OfflineChapterEdition> = []
    @Published var selectedChapters: Set<OfflineChapterEdition> = []
    @Published private(set) var libraryItems: [MediaIdentity: LibraryItem] = [:]
    @Published private(set) var thumbnails: [MediaIdentity: LibraryDurableCover] = [:]
    @Published private(set) var thumbnailRevision = 0

    private let service: any DownloadsOverviewServing
    private let library: any LibraryRootServing
    private let thumbnailService: any DownloadsThumbnailServing
    private let sourceName: (String) -> String
    private var observation: AnyCancellable?
    private var libraryObservation: AnyCancellable?
    private var generation = UUID()
    private var visibleScreens = 0
    /// A row's demand for one cover. The marker remembers a miss for exactly this item and cover address,
    /// and names the row that currently shows it. A later row for the same demand takes the owner over.
    private struct ThumbnailRequest: Equatable {
        let session: UUID
        let itemID: String
        let coverHash: String
        var owner: UUID

        func isSameDemand(as other: Self) -> Bool {
            session == other.session && itemID == other.itemID && coverHash == other.coverHash
        }
    }
    private var thumbnailRequests: [MediaIdentity: ThumbnailRequest] = [:]
    private var thumbnailObservation: AnyCancellable?
    private var capacityRequest = UUID()
    private var capacityInventory: [OfflineChapterEdition: Int64]?

    init(
        service: any DownloadsOverviewServing,
        library: any LibraryRootServing,
        thumbnails: any DownloadsThumbnailServing = UnavailableDownloadsThumbnails(),
        sourceName: @escaping (String) -> String = { $0 }
    ) {
        self.service = service
        self.library = library
        thumbnailService = thumbnails
        self.sourceName = sourceName
    }

    var allJobs: [DownloadListRow] { snapshot.inProgress.flatMap(\.rows) }
    var retryableJobs: [DownloadListRow] {
        allJobs.filter { $0.canRetry && $0.state != .waiting(.restoredPendingReview) }
    }
    var pausedJobs: [DownloadListRow] { allJobs.filter { $0.state == .waiting(.restoredPendingReview) } }
    var selectedJobRows: [DownloadListRow] { allJobs.filter { selectedJobs.contains($0.id) } }
    var selectedRetryableJobs: [DownloadListRow] {
        selectedJobRows.filter { $0.canRetry && $0.state != .waiting(.restoredPendingReview) }
    }
    var selectedPausedJobs: [DownloadListRow] {
        selectedJobRows.filter { $0.state == .waiting(.restoredPendingReview) }
    }
    var selectedDownloadRows: [DownloadListRow] {
        snapshot.downloaded.filter { selectedSeries.contains($0.id) }.flatMap(\.rows)
    }

    func series(_ identity: MediaIdentity) -> DownloadsSeries? {
        snapshot.downloaded.first { $0.id == identity }
    }

    func sourceLabel(for identity: MediaIdentity) -> String { sourceName(identity.pluginId) }

    /// Counts one visible screen. A screen calls it synchronously from `onAppear`, so its disappearance always
    /// pairs with its own count, even when its `.task` has not run yet or was cancelled.
    func attach() {
        visibleScreens += 1
        guard visibleScreens == 1 else { return }
        generation = UUID()
        // Rows whose task SwiftUI does not rerun after a push or pop must still ask for their covers again.
        thumbnailRevision &+= 1
        let current = generation
        capacityInventory = nil
        libraryObservation = library.rootSnapshotPublisher.sink { @MainActor [weak self] snapshot in
            guard let self, generation == current else { return }
            let previous = libraryItems.mapValues(Self.coverKey)
            libraryItems = Dictionary(snapshot.items.map { ($0.mediaIdentity, $0) }, uniquingKeysWith: { first, _ in first })
            for identity in Set(thumbnailRequests.keys).union(thumbnails.keys) where !isCurrent(thumbnailRequests[identity], for: identity) {
                invalidateThumbnail(for: identity)
            }
            if libraryItems.mapValues(Self.coverKey) != previous { thumbnailRevision &+= 1 }
        }
        thumbnailObservation = thumbnailService.changes.sink { @MainActor [weak self] itemID in
            guard let self, generation == current else { return }
            for identity in Set(thumbnailRequests.keys).union(thumbnails.keys) where libraryItems[identity]?.id == itemID {
                invalidateThumbnail(for: identity)
            }
            thumbnailRevision &+= 1
        }
        observation = service.observe { [weak self] result in
            guard let self, generation == current else { return }
            switch result {
            case .success(let value):
                // Live page progress republishes an identical inventory; only a changed one is re-derived.
                // Arrays that share storage compare in constant time.
                let inventoryChanged = value.downloaded != snapshot.downloaded
                snapshot = value
                if !selectedJobs.isEmpty { selectedJobs.formIntersection(Set(allJobs.map(\.id))) }
                var capacityChanged = false
                if inventoryChanged || capacityInventory == nil {
                    selectedSeries.formIntersection(Set(value.downloaded.map(\.id)))
                    selectedChapters.formIntersection(Set(value.downloaded.flatMap(\.rows).map(\.id)))
                    let inventory = Dictionary(value.downloaded.flatMap(\.rows).map { ($0.id, $0.byteCount) },
                                               uniquingKeysWith: { first, _ in first })
                    capacityChanged = capacityInventory.map { $0 != inventory } ?? false
                    capacityInventory = inventory
                    let retained = Set(value.downloaded.map(\.id))
                    for identity in Set(thumbnailRequests.keys).union(thumbnails.keys) where !retained.contains(identity) {
                        invalidateThumbnail(for: identity)
                    }
                }
                if capacityChanged { Task { await self.refreshCapacity(session: current) } }
            case .failure:
                message = String(localized: "Downloads couldn't be loaded. Open Downloads again to retry.",
                                 comment: "Downloads manager: inventory observation failed")
            }
        }
    }

    /// The first free-space read of a screen's task. It does nothing once the screen has stopped.
    func refreshAvailableSpace() async {
        await refreshCapacity(session: generation)
    }

    private func refreshCapacity(session: UUID) async {
        guard generation == session, visibleScreens > 0 else { return }
        let request = UUID()
        capacityRequest = request
        do {
            let bytes = try await service.availableCapacity()
            guard generation == session, capacityRequest == request else { return }
            availableBytes = bytes
        } catch {
            guard generation == session, capacityRequest == request else { return }
            availableBytes = nil
        }
    }

    func stop() {
        visibleScreens = max(0, visibleScreens - 1)
        guard visibleScreens == 0 else { return }
        generation = UUID()
        thumbnailRequests.removeAll()
        thumbnails.removeAll()
        capacityRequest = UUID()
        thumbnailObservation?.cancel()
        thumbnailObservation = nil
        observation?.cancel()
        observation = nil
        libraryObservation?.cancel()
        libraryObservation = nil
    }

    /// Called by a visible series row's structured task. A nil result is retained as a request
    /// marker until the row disappears, its cover changes, or a capture event invalidates it.
    func loadThumbnail(for identity: MediaIdentity, owner: UUID) async {
        guard visibleScreens > 0, !Task.isCancelled else { return }
        let session = generation
        guard snapshot.downloaded.contains(where: { $0.id == identity }),
              let item = libraryItems[identity], let address = item.coverUrl else { return }
        let request = ThumbnailRequest(session: session, itemID: item.id,
                                       coverHash: LibraryCoverThumbnailStore.coverHash(address), owner: owner)
        if var existing = thumbnailRequests[identity], isCurrent(existing, for: identity) {
            // A later row instance now shows this cover. Its release, not the earlier row's, ends the demand.
            existing.owner = owner
            thumbnailRequests[identity] = existing
            return
        }
        thumbnailRequests[identity] = request
        // The marker, not this task, owns the load: a row task restarted by SwiftUI finds the marker and
        // leaves the load to finish, while disappearance or invalidation removes the marker.
        let cover = await thumbnailService.thumbnail(for: item)
        guard generation == session, let live = thumbnailRequests[identity], live.isSameDemand(as: request),
              isCurrent(live, for: identity) else { return }
        guard let cover, cover.coverURLSHA256 == request.coverHash else { return }
        thumbnails[identity] = cover
    }

    func releaseThumbnail(for identity: MediaIdentity, owner: UUID) {
        guard let request = thumbnailRequests[identity], request.session == generation, request.owner == owner else { return }
        invalidateThumbnail(for: identity)
    }

    private static func coverKey(_ item: LibraryItem) -> String {
        "\(item.id)\u{0}\(item.coverUrl.map(LibraryCoverThumbnailStore.coverHash) ?? "")"
    }

    /// Whether `request` still describes the Library item and cover address shown for `identity`.
    private func isCurrent(_ request: ThumbnailRequest?, for identity: MediaIdentity) -> Bool {
        guard let request, request.session == generation, let item = libraryItems[identity],
              item.id == request.itemID, let address = item.coverUrl else { return false }
        return LibraryCoverThumbnailStore.coverHash(address) == request.coverHash
    }

    private func invalidateThumbnail(for identity: MediaIdentity) {
        thumbnailRequests[identity] = nil
        thumbnails[identity] = nil
    }

    func cancel(_ rows: [DownloadListRow]) async {
        await runJobAction(rows, retry: false)
    }

    func retry(_ rows: [DownloadListRow]) async {
        await runJobAction(rows.filter { $0.canRetry && $0.state != .waiting(.restoredPendingReview) }, retry: true)
    }

    func resumePaused(_ rows: [DownloadListRow]) async {
        await runJobAction(rows.filter { $0.state == .waiting(.restoredPendingReview) }, retry: true)
    }

    private func runJobAction(_ rows: [DownloadListRow], retry: Bool) async {
        guard !isWorking else { return }
        let ids = rows.compactMap(\.jobID)
        guard !ids.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if retry { try await service.retry(jobIDs: ids) } else { try await service.cancel(jobIDs: ids) }
            selectedJobs.subtract(rows.map(\.id))
        } catch {
            message = retry
                ? String(localized: "Downloads couldn't be retried. Check the list before trying again.",
                         comment: "Downloads manager bulk Retry failure")
                : String(localized: "Downloads couldn't be cancelled. Check the list before trying again.",
                         comment: "Downloads manager bulk Cancel failure")
        }
    }

    /// Each series commits independently. Keep successes and explicitly name uncertain failures.
    func deleteSeries(_ identities: Set<MediaIdentity>) async {
        guard !isWorking else { return }
        let session = generation
        isWorking = true
        defer { isWorking = false }
        let groups = snapshot.downloaded.filter { identities.contains($0.id) }
        var failures: [String] = []
        var succeeded = 0
        for group in groups {
            do {
                _ = try await service.deleteMedia(group.id, suppress: true)
                selectedSeries.remove(group.id)
                succeeded += 1
            } catch {
                failures.append(group.title)
            }
        }
        if !failures.isEmpty {
            let names = ListFormatter.localizedString(byJoining: failures)
            message = String(localized: "Deleted downloads for \(succeeded) series. Deletion couldn't be completed for: \(names). Check the list; some downloads may already have been removed.",
                             comment: "Downloads manager partial delete result. Names identify the failed series; successful deletions are not rolled back.")
        }
        await refreshCapacity(session: session)
    }

    func deleteChapters(_ editions: Set<OfflineChapterEdition>) async {
        guard !isWorking, !editions.isEmpty else { return }
        let session = generation
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.delete(Array(editions), suppress: true)
            selectedChapters.subtract(editions)
        } catch {
            let names = snapshot.downloaded.flatMap(\.rows).filter { editions.contains($0.id) }
                .map { ReaderChapterTitle.text(title: $0.title, number: $0.number) }
            let list = ListFormatter.localizedString(byJoining: names)
            message = String(localized: "Deletion couldn't be completed for: \(list). Check the list; some downloads may already have been removed.",
                             comment: "Downloads manager deletion failed or its cleanup failed after removing inventory. Never claims rollback.")
        }
        await refreshCapacity(session: session)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Deleting a series also removes its queue entries, so the confirmation says both.
    static func deleteSeriesMessage(seriesCount: Int) -> String {
        String(localized: "Saved chapters of \(seriesCount) series are deleted, and their queued downloads are cancelled.",
               comment: "Confirm deleting selected downloaded series. The count is the number of selected series; deletion also cancels their queued downloads.")
    }

    static func deleteConfirmation(_ rows: [DownloadListRow]) -> String {
        let size = bytes(rows.reduce(0) { $0 + $1.byteCount })
        return String(localized: "Delete \(rows.count) downloaded chapters (\(size))?",
                      comment: "Confirm deletion of selected offline editions and their stored bytes")
    }
}
