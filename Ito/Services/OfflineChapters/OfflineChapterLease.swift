import Foundation

/// One page of a leased version, resolved for reading. The caller verifies `fileURL` against
/// `page.sha256` before use.
nonisolated struct OfflineLeasedPage: Sendable {
    let versionId: String
    let fileURL: URL
    let page: OfflineManifestPage
}

/// In-memory lease table shared by the store and the offline image loader. Leases are never
/// persisted: after a crash no reader holds one.
nonisolated final class OfflineLeaseDirectory: @unchecked Sendable {
    private struct Entry {
        let versionId: String
        let versionDirectory: URL
        let pagesByFileName: [String: OfflineManifestPage]
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var leaseCounts: [String: Int] = [:]
    private var reclamations: [UUID: Task<Void, Never>] = [:]

    func register(
        token: UUID,
        versionId: String,
        versionDirectory: URL,
        manifest: OfflineChapterManifest
    ) {
        let pages = Dictionary(manifest.pages.map { ($0.file, $0) }) { first, _ in first }
        lock.lock()
        defer { lock.unlock() }
        entries[token] = Entry(versionId: versionId, versionDirectory: versionDirectory, pagesByFileName: pages)
        leaseCounts[versionId, default: 0] += 1
    }

    /// Removes the token. Returns the version id when this was its last lease.
    func release(token: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: token) else { return nil }
        let remaining = (leaseCounts[entry.versionId] ?? 1) - 1
        if remaining > 0 {
            leaseCounts[entry.versionId] = remaining
            return nil
        }
        leaseCounts[entry.versionId] = nil
        return entry.versionId
    }

    /// Resolves a page file for a live token. Unknown or released tokens and names that are not
    /// in the leased manifest resolve to nil.
    func resolvePage(token: UUID, fileName: String) -> OfflineLeasedPage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token], let page = entry.pagesByFileName[fileName] else { return nil }
        return OfflineLeasedPage(
            versionId: entry.versionId,
            fileURL: entry.versionDirectory.appendingPathComponent(page.file),
            page: page
        )
    }

    func isLeased(versionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (leaseCounts[versionId] ?? 0) > 0
    }

    func leasedVersionIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(leaseCounts.filter { $0.value > 0 }.map(\.key))
    }

    /// Runs the reclamation a lease release needs. A finished reclamation removes itself, so the
    /// table only ever holds work that is still running.
    func scheduleReclamation(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        // Created under the lock: the task's own removal waits until it has been recorded.
        reclamations[id] = Task { [weak self] in
            await work()
            self?.finishReclamation(id)
        }
    }

    /// Waits for every reclamation scheduled by lease releases so far. This is the observable end of
    /// a release: a test awaits it instead of sleeping.
    func awaitReclamations() async {
        let pending = runningReclamations()
        for task in pending {
            await task.value
        }
    }

    private func runningReclamations() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(reclamations.values)
    }

    private func finishReclamation(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reclamations[id] = nil
    }
}

/// A reader's hold on one stored version. The version's bytes outlive a Delete while a lease
/// exists. Releasing the last lease of an unreferenced version reclaims its bytes.
nonisolated final class OfflineChapterLease: Sendable {
    let token: UUID
    let versionId: String
    let edition: OfflineChapterEdition
    let manifest: OfflineChapterManifest

    private let directory: OfflineLeaseDirectory
    private let store: OfflineChapterStore

    init(
        token: UUID,
        versionId: String,
        edition: OfflineChapterEdition,
        manifest: OfflineChapterManifest,
        directory: OfflineLeaseDirectory,
        store: OfflineChapterStore
    ) {
        self.token = token
        self.versionId = versionId
        self.edition = edition
        self.manifest = manifest
        self.directory = directory
        self.store = store
    }

    /// The page stored under `fileName`, or nil when the lease was released or the name is not in
    /// the manifest.
    func page(fileName: String) -> OfflineLeasedPage? {
        directory.resolvePage(token: token, fileName: fileName)
    }

    deinit {
        guard let released = directory.release(token: token) else { return }
        let store = store
        directory.scheduleReclamation { await store.reclaimIfUnreferenced(versionId: released) }
    }
}
