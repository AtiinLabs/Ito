import Combine
import Foundation
import ito_runner

/// What the batch download controls read from the series screen that owns them.
@MainActor
protocol MediaDetailDownloadBatchHost: AnyObject {
    var batchIdentity: MediaIdentity { get }
    /// The live list's chapters as the source returned them; empty for a kind that has no stored form.
    var batchChapters: [Chapter] { get }
    /// The series as a stored entry, or nil for a kind that has none.
    var batchEntry: MediaEntry? { get }
    var batchSeriesTitle: String { get }
    var batchIsSaved: Bool { get }
    /// Whether the screen shows the saved series without a source to ask.
    var batchIsSavedOnlyRoute: Bool { get }
    func presentBatchMessage(_ message: MediaDetailMessage)
}

/// The presets, scanlator choice, preview, saved-only rows and series summary of one series' download
/// controls. The screen's model owns it and forwards its changes; it reads the screen only through its host.
@MainActor
final class MediaDetailDownloadBatchModel: ObservableObject {
    @Published private(set) var sheet: DownloadSheet?
    /// SHA-256 hex digest of the chapter list as the source returned it. Empty where nothing is downloadable.
    @Published private(set) var catalogDigest = ""
    /// A batch is being queued; a second one waits for it instead of being dropped.
    @Published private(set) var isEnqueuing = false
    /// A scanlator choice is being applied; a second confirm of the same sheet is not acted on.
    @Published private(set) var isApplyingChoice = false
    /// Free space where downloads are stored, for the preview.
    @Published private(set) var availableBytes: Int64?
    /// Saved editions the current list does not have, as the source returned them when downloaded.
    @Published private(set) var savedOnlyChapters: [Chapter] = []
    @Published private(set) var summary = SeriesDownloadSummary()
    /// What this series' stored copies occupy; nil when it has none or the size could not be read.
    @Published private(set) var storedBytes: Int64?
    @Published private(set) var remembered = RememberedEditionChoice.unknown
    /// What the saved details say about the catalog they hold; nil when nothing was recorded.
    @Published private(set) var coverageBasis: LibrarySnapshotBasis?

    weak var host: (any MediaDetailDownloadBatchHost)? {
        didSet { catalogDigest = currentDigest() }
    }

    private let downloads: any MediaDetailDownloadServing
    private let progress: any MediaDetailProgressServing
    private let snapshots: MediaDetailSnapshotRefresher
    private let inventory: ((MediaIdentity) async -> [DownloadedChapterRecord])?
    private let loadsFromSource: Bool

    private var states: [String: ChapterDownloadState] = [:]
    /// The series `states` belong to; they arrive with the identity, not with the list that is current.
    private var statesIdentity: MediaIdentity?
    private var storedKeys = Set<String>()
    private var preferenceIdentity: MediaIdentity?
    private var requestedSavedOnly: SavedOnlyRequest?

    private var preferenceTask: Task<Void, Never>?
    private var coverageTask: Task<Void, Never>?
    private var savedOnlyTask: Task<Void, Never>?
    private var capacityTask: Task<Void, Never>?
    private var bytesTask: Task<Void, Never>?
    private var enqueueTask: Task<Void, Never>?

    /// The saved editions asked of the inventory, for one series and one set of unlisted keys.
    private struct SavedOnlyRequest: Equatable {
        let identity: MediaIdentity
        let missing: Set<String>
    }

    init(
        downloads: any MediaDetailDownloadServing,
        progress: any MediaDetailProgressServing,
        snapshots: MediaDetailSnapshotRefresher,
        inventory: ((MediaIdentity) async -> [DownloadedChapterRecord])?,
        loadsFromSource: Bool
    ) {
        self.downloads = downloads
        self.progress = progress
        self.snapshots = snapshots
        self.inventory = inventory
        self.loadsFromSource = loadsFromSource
    }

    deinit {
        preferenceTask?.cancel()
        coverageTask?.cancel()
        savedOnlyTask?.cancel()
        capacityTask?.cancel()
        bytesTask?.cancel()
    }

    // MARK: - Availability

    /// Whether downloads exist on this build for this series' kind.
    var isAvailable: Bool {
        downloads.isAvailable && host?.batchIdentity.mediaKind != .anime
    }

    /// Whether the series offers presets and the scanlator choice: a saved manga or novel that has a source to
    /// queue from, and a catalog with chapters.
    var showsControls: Bool {
        guard isAvailable, let host else { return false }
        return host.batchIsSaved && loadsFromSource && !host.batchIsSavedOnlyRoute && !host.batchChapters.isEmpty
    }

    /// The scanlators presets follow: the remembered choice, or the source's list.
    var rememberedSelection: EditionSelection {
        if case .chosen(let selection) = remembered { return selection }
        return .sourceList
    }

    func isSavedOnly(key: String) -> Bool {
        savedOnlyChapters.contains { $0.key == key }
    }

    /// "Entire series offline" or the saved count. The claim is about the catalog saved with the Library item,
    /// so its rows come from that payload and never from the list a later load returned.
    func coverage(now: Date = Date()) -> SeriesOfflineCoverage.Result? {
        guard isAvailable, host?.batchIsSaved == true else { return nil }
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: coverageBasis?.snapshot,
            currentPayloadSHA256: coverageBasis?.currentPayloadSHA256,
            selection: rememberedSelection,
            catalog: coverageBasis?.catalog ?? [],
            states: states,
            now: now
        )
        if case .saved(0) = result { return nil }
        return result
    }

    // MARK: - Following the screen

    /// A new chapter list ends the review of a plan made from the old one.
    func mediaDidChange() {
        let digest = currentDigest()
        guard digest != catalogDigest else { return }
        catalogDigest = digest
        revalidatePreview()
        refreshSavedOnly()
    }

    /// The states of a series' chapters, with the series they belong to.
    func statesDidChange(_ states: [String: ChapterDownloadState], for identity: MediaIdentity) {
        self.states = states
        statesIdentity = identity
        guard isAvailable else { return }
        let current = SeriesDownloadSummary(states: states)
        if current != summary { summary = current }
        let keys = Set(states.filter { $0.value == .downloaded || $0.value == .damaged }.keys)
        if keys != storedKeys {
            storedKeys = keys
            loadStoredBytes()
        }
        refreshSavedOnly()
    }

    /// Reads what the controls need from stores: the remembered choice, once per series, what the saved details
    /// say about the catalog, and what the stored copies occupy.
    func reload() {
        guard isAvailable else { return }
        loadPreference(force: false)
        loadCoverageBasis()
        loadStoredBytes()
        // A relink to a series with the same chapter list changes no digest, so its saved-only rows are asked
        // for here as well.
        refreshSavedOnly()
    }

    /// A new series identity starts over. A batch already being queued is left to finish.
    func reset() {
        preferenceTask?.cancel()
        coverageTask?.cancel()
        savedOnlyTask?.cancel()
        capacityTask?.cancel()
        bytesTask?.cancel()
        preferenceTask = nil
        coverageTask = nil
        savedOnlyTask = nil
        capacityTask = nil
        bytesTask = nil
        sheet = nil
        remembered = .unknown
        preferenceIdentity = nil
        coverageBasis = nil
        savedOnlyChapters = []
        requestedSavedOnly = nil
        states = [:]
        statesIdentity = nil
        storedKeys = []
        summary = SeriesDownloadSummary()
        storedBytes = nil
        availableBytes = nil
    }

    /// Reads what the saved details say about the catalog; the entire-series claim needs it.
    func loadCoverageBasis() {
        coverageTask?.cancel()
        coverageTask = nil
        guard isAvailable, let host, host.batchIsSaved else {
            coverageBasis = nil
            return
        }
        let identity = host.batchIdentity
        let snapshots = snapshots
        coverageTask = Task { [weak self] in
            let basis = await snapshots.basis(for: identity)
            guard let self, !Task.isCancelled, self.host?.batchIdentity == identity else { return }
            self.coverageTask = nil
            self.coverageBasis = basis
        }
    }

    private func loadPreference(force: Bool) {
        guard let identity = host?.batchIdentity else { return }
        if !force, preferenceIdentity == identity, remembered != .unreadable { return }
        preferenceIdentity = identity
        preferenceTask?.cancel()
        remembered = .unknown
        let downloads = downloads
        preferenceTask = Task { [weak self] in
            // Only a stored choice this build cannot read is "unreadable". Any other failure is a read that did
            // not happen: the state stays unknown, and the next preset reads again.
            let result: RememberedEditionChoice?
            do {
                if let stored = try await downloads.editionPreference(for: identity) {
                    result = .chosen(stored)
                } else {
                    result = RememberedEditionChoice.none
                }
            } catch SeriesEditionPreferenceError.unreadable {
                result = .unreadable
            } catch {
                result = nil
            }
            guard let self, !Task.isCancelled, self.host?.batchIdentity == identity else { return }
            self.preferenceTask = nil
            // A choice made while the read ran is newer than what it found.
            if self.remembered == .unknown, let result { self.remembered = result }
        }
    }

    /// Waits for the remembered choice. One that could not be read is read again first.
    private func ensurePreferenceRead() async {
        if remembered == .unreadable || (remembered == .unknown && preferenceTask == nil) {
            loadPreference(force: true)
        }
        await preferenceTask?.value
    }

    private func loadStoredBytes() {
        bytesTask?.cancel()
        bytesTask = nil
        guard isAvailable, let identity = host?.batchIdentity, !storedKeys.isEmpty else {
            storedBytes = nil
            return
        }
        let downloads = downloads
        bytesTask = Task { [weak self] in
            let bytes = await downloads.storedByteCount(for: identity)
            guard let self, !Task.isCancelled, self.host?.batchIdentity == identity else { return }
            self.bytesTask = nil
            self.storedBytes = bytes
        }
    }

    /// Looks up the saved editions this runner route's list does not have, once per series and set of unlisted
    /// keys. A copy that is listed again, or deleted, leaves the rows at once.
    private func refreshSavedOnly() {
        guard isAvailable, loadsFromSource, let inventory, let host,
              statesIdentity == host.batchIdentity else { return }
        let identity = host.batchIdentity
        let listedKeys = Set(host.batchChapters.map(\.key))
        let missing = Set(states.filter { $0.value == .downloaded }.keys).subtracting(listedKeys)
        let remaining = savedOnlyChapters.filter { missing.contains($0.key) }
        if remaining.count != savedOnlyChapters.count { savedOnlyChapters = remaining }
        let request = SavedOnlyRequest(identity: identity, missing: missing)
        guard request != requestedSavedOnly else { return }
        requestedSavedOnly = request
        savedOnlyTask?.cancel()
        savedOnlyTask = nil
        guard !missing.isEmpty else { return }
        savedOnlyTask = Task { [weak self] in
            let records = await inventory(identity)
            guard let self, !Task.isCancelled else { return }
            self.savedOnlyTask = nil
            guard let host = self.host, host.batchIdentity == identity else {
                // Asked for another series than the one shown now: ask again for the current one.
                self.requestedSavedOnly = nil
                return
            }
            self.savedOnlyChapters = SavedChapterMerge.savedOnly(
                listedKeys: Set(host.batchChapters.map(\.key)),
                inventory: records.filter { missing.contains($0.chapterKey) }
            )
        }
    }

    private func currentDigest() -> String {
        guard isAvailable, let chapters = host?.batchChapters, !chapters.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(chapters) else { return "" }
        return OfflineDigest.sha256Hex(data)
    }

    // MARK: - Presets

    /// Runs a menu preset. The remembered scanlator choice is read first; when the catalog spans several
    /// scanlators and none was remembered, the chooser comes first and the preset continues from it. A plan with
    /// nothing to confirm is queued at once; anything else is shown in the preview. The returned task lets a
    /// caller wait for the queueing.
    @discardableResult
    func startDownload(_ preset: DownloadPreset) -> Task<Void, Never> {
        guard showsControls, !isEnqueuing, let identity = host?.batchIdentity else { return Task {} }
        return Task { [weak self] in
            await self?.ensurePreferenceRead()
            guard let self, self.host?.batchIdentity == identity, self.showsControls, !self.isEnqueuing else { return }
            switch self.remembered {
            case .chosen(let selection):
                await self.resolveDownload(preset, selection: selection)?.value
            case .none:
                if self.scanlatorOptions().count >= 2 {
                    self.sheet = .chooser(self.makeChooser(preset: preset, problem: nil))
                } else {
                    await self.resolveDownload(preset, selection: .sourceList)?.value
                }
            case .unreadable, .unknown:
                // The stored choice is unknown, so no scanlator is assumed: nothing is queued until the user
                // acts. With several scanlators the chooser opens; with one, the source's list is the only
                // list there is, and the preview shows it.
                let problem: StoredChoiceProblem = self.remembered == .unreadable ? .unreadable : .readFailed
                if self.scanlatorOptions().count >= 2 {
                    self.sheet = .chooser(self.makeChooser(preset: preset, problem: problem))
                } else {
                    self.host?.presentBatchMessage(
                        problem == .unreadable ? .editionChoiceUnreadable : .editionChoiceReadFailed(reviewing: true)
                    )
                    await self.resolveDownload(preset, selection: .sourceList, alwaysPreview: true)?.value
                }
            }
        }
    }

    /// Opens the scanlator chooser without a preset behind it ("Scanlators…"). The remembered choice is read
    /// first, so the chooser never opens on a default the series has already replaced.
    @discardableResult
    func openEditionChooser() -> Task<Void, Never> {
        guard showsControls, let identity = host?.batchIdentity else { return Task {} }
        return Task { [weak self] in
            await self?.ensurePreferenceRead()
            guard let self, self.host?.batchIdentity == identity, self.showsControls else { return }
            if self.remembered == .unknown {
                // The stored choice could not be read, and a choice made here is always stored: replacing
                // what might be a fine choice without showing it is not offered.
                self.host?.presentBatchMessage(.editionChoiceReadFailed(reviewing: false))
                return
            }
            self.sheet = .chooser(self.makeChooser(preset: nil, problem: self.remembered == .unreadable ? .unreadable : nil))
        }
    }

    /// Applies the scanlators the user chose and continues with the preset that asked for the choice. With
    /// `remember` the choice is stored for the series first; without it, the choice applies to this batch only
    /// and nothing else changes. A choice made without a preset has no batch to apply to, so it is always
    /// remembered. A choice that cannot be stored still applies to this batch, and says so.
    @discardableResult
    func applyEditionChoice(_ selection: EditionSelection, remember: Bool, then preset: DownloadPreset?) -> Task<Void, Never> {
        guard showsControls, !isApplyingChoice, let identity = host?.batchIdentity else { return Task {} }
        // A strict set with no scanlator selects nothing; the chooser never offers it.
        if case .scanlators(let references) = selection, references.isEmpty { return Task {} }
        // Set before anything is awaited, so a second tap on the same sheet finds the first one under way.
        isApplyingChoice = true
        let store = remember || preset == nil
        let downloads = downloads
        return Task { [weak self] in
            defer { self?.isApplyingChoice = false }
            // The series may have left the Library since the sheet opened; a choice is only kept for a saved one.
            guard let self, self.host?.batchIdentity == identity, self.host?.batchIsSaved == true else { return }
            var storeFailed = false
            if store {
                do {
                    try await downloads.setEditionPreference(selection, for: identity)
                } catch {
                    storeFailed = true
                }
            }
            guard self.host?.batchIdentity == identity else { return }
            if store, !storeFailed { self.remembered = .chosen(selection) }
            if storeFailed {
                self.host?.presentBatchMessage(preset == nil ? .editionChoiceNotSaved : .editionChoiceNotRemembered)
            }
            if let preset {
                await self.resolveDownload(preset, selection: selection)?.value
            } else {
                self.sheet = nil
            }
        }
    }

    /// Queues what the open preview lists, plus the other uploads the user ticked. The list must still be the
    /// one the preview was made from; if it changed, the preview is made again and nothing is queued. While a
    /// batch is being queued the preview stays open, so a second confirm is never dropped silently.
    @discardableResult
    func confirmDownloadPreview(including alternativeKeys: Set<String> = []) -> Task<Void, Never> {
        guard case .preview(let preview)? = sheet, !isEnqueuing else { return Task {} }
        guard preview.catalogDigest == catalogDigest else {
            revalidatePreview()
            return Task {}
        }
        let wanted = Set(preview.toQueue.map(\.key)).union(preview.alternatives.map(\.key).filter(alternativeKeys.contains))
        let chapters = frozenChapters(keys: wanted)
        sheet = nil
        guard !chapters.isEmpty else {
            host?.presentBatchMessage(.nothingToDownload)
            return Task {}
        }
        return enqueueBatch(
            preset: preview.preset,
            selection: preview.selection,
            chapters: chapters,
            alreadyStored: preview.storedCount
        ) ?? Task {}
    }

    func dismissDownloadSheet() {
        sheet = nil
    }

    // MARK: - Planning

    private struct PlannedDownload {
        let chapters: [Chapter]
        let plan: DownloadPlan<Int>
    }

    private func planDownload(_ preset: DownloadPreset, selection: EditionSelection) -> PlannedDownload {
        let identity = host?.batchIdentity
        let chapters = host?.batchChapters ?? []
        let rows = chapters.map { chapter in
            DownloadPlanRow(
                facts: ChapterFacts(chapter),
                isRead: identity.map {
                    progress.isRead(media: $0, chapterID: chapter.key, chapterNumber: chapter.chapterNumber)
                } ?? false,
                stored: storedEditionState(chapter.key)
            )
        }
        let plan = DownloadPresetResolver.plan(
            rows: rows,
            preset: preset,
            selection: selection,
            anchorKey: identity.flatMap { progress.lastReadChapter(for: $0) }
        )
        return PlannedDownload(chapters: chapters, plan: plan)
    }

    /// What the store knows of one exact key. A failed job still occupies its key, so it holds its position
    /// and is not queued again: Retry is the way back.
    private func storedEditionState(_ key: String) -> StoredEditionState {
        switch states[key] {
        case nil: .none
        case .downloaded?: .verified
        case .damaged?: .damaged
        case .queued?, .downloading?, .waiting?, .failed?: .queued
        }
    }

    private func isFailed(_ key: String) -> Bool {
        if case .failed? = states[key] { return true }
        return false
    }

    /// - Parameter alwaysPreview: show the preview even for a plan with nothing to confirm.
    private func resolveDownload(
        _ preset: DownloadPreset,
        selection: EditionSelection,
        alwaysPreview: Bool = false
    ) -> Task<Void, Never>? {
        let planned = planDownload(preset, selection: selection)
        let holdsFailedJob = planned.plan.satisfied.contains { isFailed(planned.chapters[$0].key) }
        if alwaysPreview || planned.plan.requiresPreview || holdsFailedJob {
            sheet = .preview(makePreview(planned, preset: preset, selection: selection, listChanged: false))
            loadAvailableCapacity()
            return nil
        }
        sheet = nil
        let queueable = planned.plan.toQueue.map { planned.chapters[$0] }
        guard !queueable.isEmpty else {
            host?.presentBatchMessage(.nothingToDownload)
            return nil
        }
        return enqueueBatch(
            preset: preset,
            selection: selection,
            chapters: queueable,
            alreadyStored: planned.plan.satisfied.count
        )
    }

    private func makePreview(
        _ planned: PlannedDownload,
        preset: DownloadPreset,
        selection: EditionSelection,
        listChanged: Bool
    ) -> DownloadPreview {
        func rows(_ indices: [Int]) -> [DownloadPreviewRow] {
            indices.map { index in
                let chapter = planned.chapters[index]
                return DownloadPreviewRow(
                    key: chapter.key,
                    title: ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber),
                    scanlator: chapter.scanlator,
                    stored: storedEditionState(chapter.key),
                    isFailed: isFailed(chapter.key)
                )
            }
        }
        let plan = planned.plan
        return DownloadPreview(
            id: UUID(),
            preset: preset,
            selection: selection,
            catalogDigest: catalogDigest,
            toQueue: rows(plan.toQueue),
            satisfied: rows(plan.satisfied),
            damaged: rows(plan.damaged),
            locked: rows(plan.locked),
            alternatives: rows(plan.alternatives),
            skippedReadCount: plan.skippedReadCount,
            issues: plan.issues,
            listChanged: listChanged
        )
    }

    /// Replaces an open preview made from a chapter list that has since changed.
    private func revalidatePreview() {
        guard case .preview(let preview)? = sheet, preview.catalogDigest != catalogDigest else { return }
        let planned = planDownload(preview.preset, selection: preview.selection)
        sheet = .preview(makePreview(planned, preset: preview.preset, selection: preview.selection, listChanged: true))
    }

    private func loadAvailableCapacity() {
        capacityTask?.cancel()
        let downloads = downloads
        capacityTask = Task { [weak self] in
            let bytes = await downloads.availableCapacity()
            guard let self, !Task.isCancelled else { return }
            self.capacityTask = nil
            self.availableBytes = bytes
        }
    }

    // MARK: - Chooser

    private func makeChooser(preset: DownloadPreset?, problem: StoredChoiceProblem?) -> EditionChooserPresentation {
        EditionChooserPresentation(
            options: scanlatorOptions(),
            initialSelection: rememberedSelection,
            // A choice that could not be read is replaced by default; one that merely could not be loaded this
            // time may be fine, so it is not replaced unless the user turns Remember on.
            remember: problem != .readFailed,
            offersRemember: preset != nil,
            preset: preset,
            storedChoiceProblem: problem
        )
    }

    /// The scanlator names the catalog has, with their row counts. A row with no scanlator is one more name.
    private func scanlatorOptions() -> [ScanlatorOption] {
        var counts: [ScanlatorRef: Int] = [:]
        for chapter in host?.batchChapters ?? [] {
            counts[ScanlatorRef(name: chapter.scanlator), default: 0] += 1
        }
        return counts
            .map { ScanlatorOption(ref: $0.key, chapterCount: $0.value) }
            .sorted {
                if $0.chapterCount != $1.chapterCount { return $0.chapterCount > $1.chapterCount }
                return ($0.ref.name ?? "") < ($1.ref.name ?? "")
            }
    }

    // MARK: - Queueing

    /// The exact source chapters for `keys`, in reading order. The list is the one a plan was just made from.
    private func frozenChapters(keys: Set<String>) -> [Chapter] {
        var seen = Set<String>()
        let chosen = (host?.batchChapters ?? []).filter {
            keys.contains($0.key) && !$0.isPaywalled && seen.insert($0.key).inserted
        }
        let order = ChapterReadingOrder.order(chosen.map { ChapterFacts($0) }).order
        return order.map { chosen[$0] }
    }

    private func enqueueBatch(
        preset: DownloadPreset,
        selection: EditionSelection,
        chapters: [Chapter],
        alreadyStored: Int
    ) -> Task<Void, Never>? {
        guard !isEnqueuing, let host else { return nil }
        guard let entry = host.batchEntry, let storedSelection = try? selection.storageData() else {
            host.presentBatchMessage(.downloadRefused)
            return nil
        }
        let identity = host.batchIdentity
        let request = DownloadBatchRequest(
            pluginId: identity.pluginId,
            mediaKind: identity.mediaKind,
            canonicalMediaId: identity.canonicalMediaId,
            entry: entry,
            seriesTitle: host.batchSeriesTitle,
            preset: DownloadBatchPreset(preset),
            selection: storedSelection,
            catalogDigest: catalogDigest.isEmpty ? nil : catalogDigest,
            chapters: chapters
        )
        let downloads = downloads
        isEnqueuing = true
        let task = Task { [weak self] in
            let outcome = await downloads.enqueueBatch(request)
            self?.finishBatch(outcome, alreadyStored: alreadyStored)
        }
        enqueueTask = task
        return task
    }

    private func finishBatch(_ outcome: DownloadBatchOutcome, alreadyStored: Int) {
        enqueueTask = nil
        isEnqueuing = false
        if let refusal = outcome.refusal {
            host?.presentBatchMessage(refusal == .unavailable ? .downloadActionFailed : .downloadRefused)
        } else if outcome.queued > 0 {
            host?.presentBatchMessage(.downloadsQueued(
                queued: outcome.queued,
                alreadyStored: alreadyStored + outcome.alreadySaved + outcome.alreadyQueued
            ))
        } else {
            host?.presentBatchMessage(.nothingToDownload)
        }
    }

#if DEBUG
    /// Waits for every read the controls started, so a test can look at what they found.
    func settleForTesting() async {
        await preferenceTask?.value
        await coverageTask?.value
        await savedOnlyTask?.value
        await capacityTask?.value
        await bytesTask?.value
    }
#endif
}
