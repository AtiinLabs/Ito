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
    @Published private(set) var sheet: DownloadSheet? {
        didSet {
            // A sheet the screen reported on screen is still dismissing when it is cleared; a metered prompt waits
            // for that. One cleared before it was ever shown never reports a dismissal, so nothing waits for it.
            if sheet == nil, oldValue != nil, sheetIsOnScreen { sheetDismissalPending = true }
        }
    }
    /// SHA-256 hex digest of the chapter list as the source returned it. Empty where nothing is downloadable.
    @Published private(set) var catalogDigest = ""
    /// A batch is being queued; a second one waits for it instead of being dropped.
    @Published var isEnqueuing = false
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
    /// Set while a planned batch waits for the user to decide whether it may use cellular data.
    @Published var meteredPrompt: MeteredDownloadPrompt?
    /// The saved custom presets, in order. Read from the store; the model never writes them.
    @Published private(set) var customPresets: [CustomDownloadPreset] = []

    weak var host: (any MediaDetailDownloadBatchHost)? {
        didSet {
            catalogDigest = currentDigest()
            librarySavedStateDidChange(host?.batchIsSaved ?? false)
        }
    }

    let downloads: any MediaDetailDownloadServing
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
    /// Saved-only snapshots whose metadata still belongs to this exact source series.
    private var policySavedOnlyChapters: [Chapter] = []
    private var presetSubscription: AnyCancellable?

    private var preferenceTask: Task<Void, Never>?
    /// The read that may still publish; a replaced or superseded read finds another token and leaves.
    private var preferenceReadToken: UUID?
    private var coverageTask: Task<Void, Never>?
    private var savedOnlyTask: Task<Void, Never>?
    private var capacityTask: Task<Void, Never>?
    private var bytesTask: Task<Void, Never>?
    // The queueing state below is internal, not private, so MediaDetailDownloadBatchModel+Queueing can reach it.
    var enqueueTask: Task<Void, Never>?
    private var choiceOperationID: UUID?
    /// A More prompt confirmation is scoped to this exact prompt until it either replaces it with a chooser/preview
    /// or admits the batch write. Dismissal, replacement and navigation invalidate it.
    var pendingMoreOperationID: UUID?
    var pendingMorePromptID: UUID?
    private var scopeGeneration = 0
    private var lastSavedState: Bool?
    /// Advances when the saved series is removed or reset, and never on a catalogue change alone.
    private(set) var savedScopeGeneration = 0
    /// The submission that set `isEnqueuing`; only that submission may end the queueing state.
    var enqueueOperationID: UUID?
    /// The batch held until the user decides whether it may use an expensive path.
    var pendingMeteredBatch: PendingMeteredBatch?
    /// Whether the screen reported the current download sheet on screen, and so will report its dismissal.
    var sheetIsOnScreen = false
    /// Set from the moment a shown sheet is cleared until SwiftUI reports it dismissed. A metered prompt waits for
    /// that, because a dialog presented over a sheet that is still going away is not shown.
    var sheetDismissalPending = false

    /// The saved editions asked of the inventory, for one series and one set of unlisted keys.
    private struct SavedOnlyRequest: Equatable {
        let identity: MediaIdentity
        let missing: Set<String>
    }

    /// A planned batch held for the user's decision about expensive paths.
    struct PendingMeteredBatch {
        let id: UUID
        let request: DownloadBatchRequest
        let alreadyStored: Int
        /// The count a "Download More" request asked for, reported against what was actually queued.
        let requestedMore: Int?
        let scope: BatchScope
        /// The dialog has been shown for this batch; hiding it does not show it again.
        var wasPresented = false
    }

    struct BatchScope {
        let identity: MediaIdentity
        let generation: Int
        let catalogDigest: String
        let sourceEpoch: String
    }

    init(
        downloads: any MediaDetailDownloadServing,
        progress: any MediaDetailProgressServing,
        snapshots: MediaDetailSnapshotRefresher,
        inventory: ((MediaIdentity) async -> [DownloadedChapterRecord])?,
        loadsFromSource: Bool,
        presets: any DownloadPresetProviding
    ) {
        self.downloads = downloads
        self.progress = progress
        self.snapshots = snapshots
        self.inventory = inventory
        self.loadsFromSource = loadsFromSource
        presetSubscription = presets.presetsPublisher.sink { [weak self] in self?.customPresets = $0 }
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
        // A remembered choice this build cannot read is not the source list, so it makes no entire-series claim:
        // the same fail-closed rule the Library's filter applies.
        let snapshot = remembered == .unreadable ? nil : coverageBasis?.snapshot
        let result = SeriesOfflineCoverage.evaluate(
            snapshot: snapshot,
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

    func librarySavedStateDidChange(_ isSaved: Bool) {
        let wasSaved = lastSavedState
        lastSavedState = isSaved
        guard wasSaved == true, !isSaved else { return }
        scopeGeneration &+= 1
        savedScopeGeneration &+= 1
        sheet = nil
        sheetDismissalPending = false
        sheetIsOnScreen = false
        cancelMeteredPrompt()
        choiceOperationID = nil
        isApplyingChoice = false
        releaseEnqueueOwnership()
        // The removal forgot the series' remembered choice, so a re-added series reads it again instead of reusing it.
        preferenceTask?.cancel()
        preferenceTask = nil
        preferenceIdentity = nil
        invalidateMoreOperation()
        remembered = .unknown
    }

    func mediaDidChange() {
        let digest = currentDigest()
        guard digest != catalogDigest else { return }
        scopeGeneration &+= 1
        catalogDigest = digest
        if case .chooser = sheet {
            sheet = nil
            choiceOperationID = nil
            isApplyingChoice = false
        }
        revalidatePreview()
        invalidateMoreOperation()
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

    /// A new series identity starts over. A batch already submitted is not cancelled; it no longer reports here.
    func reset() {
        cancelMeteredPrompt()
        scopeGeneration &+= 1
        savedScopeGeneration &+= 1
        releaseEnqueueOwnership()
        invalidateMoreOperation()
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
        choiceOperationID = nil
        lastSavedState = nil
        isApplyingChoice = false
        sheet = nil
        sheetDismissalPending = false
        sheetIsOnScreen = false
        remembered = .unknown
        preferenceIdentity = nil
        coverageBasis = nil
        savedOnlyChapters = []
        policySavedOnlyChapters = []
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

    func loadPreference(force: Bool) {
        guard let identity = host?.batchIdentity else { return }
        if !force, preferenceIdentity == identity, remembered != .unreadable { return }
        preferenceIdentity = identity
        preferenceTask?.cancel()
        remembered = .unknown
        let downloads = downloads
        let savedGeneration = savedScopeGeneration
        let token = UUID()
        preferenceReadToken = token
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
            // A read that was replaced belongs to its replacement.
            guard let self, self.preferenceReadToken == token else { return }
            self.preferenceReadToken = nil
            self.preferenceTask = nil
            guard !Task.isCancelled, self.host?.batchIdentity == identity,
                  self.host?.batchIsSaved == true,
                  self.savedScopeGeneration == savedGeneration else {
                // The series was not saved (or was replaced) while the read ran. Nothing was learned, so a
                // later action reads again instead of finding a finished read that says nothing.
                self.preferenceIdentity = nil
                return
            }
            // A choice made while the read ran is newer than what it found.
            if self.remembered == .unknown, let result { self.remembered = result }
        }
    }

    /// Waits for the remembered choice. One that could not be read is read again first.
    private func ensurePreferenceRead(validating isValid: () -> Bool = { true }) async -> Bool {
        if remembered == .unreadable || (remembered == .unknown && preferenceTask == nil) {
            loadPreference(force: true)
        }
        await preferenceTask?.value
        guard !Task.isCancelled, isValid() else { return false }
        return await refreshStoredPreference(validating: isValid)
    }

    /// Reads the stored choice once more before an action plans with it. A prompt-bound action validates its token
    /// immediately after the read resumes, before using the resulting choice.
    private func refreshStoredPreference(validating isValid: () -> Bool) async -> Bool {
        let before = remembered
        guard before != .unknown, before != .unreadable, let identity = host?.batchIdentity else {
            return isValid()
        }
        let savedGeneration = savedScopeGeneration
        let fresh: RememberedEditionChoice
        do {
            if let stored = try await downloads.editionPreference(for: identity) {
                fresh = .chosen(stored)
            } else {
                fresh = .none
            }
        } catch SeriesEditionPreferenceError.unreadable {
            fresh = .unreadable
        } catch {
            return isValid()
        }
        guard !Task.isCancelled, isValid() else { return false }
        guard host?.batchIdentity == identity, host?.batchIsSaved == true,
              savedScopeGeneration == savedGeneration, remembered == before else { return true }
        remembered = fresh
        return true
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
        policySavedOnlyChapters.removeAll { !missing.contains($0.key) }
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
            self.policySavedOnlyChapters = SavedChapterMerge.savedOnly(
                listedKeys: Set(host.batchChapters.map(\.key)),
                inventory: records.filter { record in
                    guard missing.contains(record.chapterKey), record.pluginId == identity.pluginId,
                          record.mediaKind == identity.mediaKind,
                          record.canonicalMediaId == identity.canonicalMediaId else { return false }
                    // Nil means the metadata belongs to the record's own series, not whichever screen asked.
                    guard let data = record.originIdentity else { return true }
                    guard let origin = try? JSONDecoder().decode(OfflineOriginIdentity.self, from: data) else { return false }
                    return origin.pluginId == identity.pluginId && origin.canonicalMediaId == identity.canonicalMediaId
                }
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

    /// The scope an action starts under. The source epoch is read once here; the stores compare it again
    /// inside their write transactions. A read that fails is reported: an action never silently does nothing.
    func currentBatchScope(reportingFailure: Bool = true) -> BatchScope? {
        guard let host, host.batchIsSaved else { return nil }
        guard let epoch = try? downloads.editionPreferenceEpoch(for: host.batchIdentity.pluginId) else {
            if reportingFailure { host.presentBatchMessage(.downloadActionFailed) }
            return nil
        }
        return BatchScope(
            identity: host.batchIdentity, generation: scopeGeneration,
            catalogDigest: catalogDigest, sourceEpoch: epoch
        )
    }

    func isCurrent(_ scope: BatchScope) -> Bool {
        host?.batchIdentity == scope.identity
            && host?.batchIsSaved == true
            && scopeGeneration == scope.generation
            && catalogDigest == scope.catalogDigest
    }

    /// Whether the source's epoch is still the one a sheet was made under. A read that fails is not "the
    /// same": the consent is stale.
    private func isCurrentEpoch(_ epoch: String, for identity: MediaIdentity) -> Bool {
        (try? downloads.editionPreferenceEpoch(for: identity.pluginId)) == epoch
    }

    /// A consent was made under a source epoch, policy or catalog that is no longer current. The sheet closes,
    /// nothing is stored or queued, and the user is asked to review again; a confirm that cannot work is
    /// never left on screen.
    private func closeStaleConsent() {
        sheet = nil
        choiceOperationID = nil
        isApplyingChoice = false
        host?.presentBatchMessage(.editionChoiceChanged)
    }

    private func ownsChooser(_ id: UUID?) -> Bool {
        guard let id else { return true }
        guard case .chooser(let current)? = sheet else { return false }
        return current.id == id
    }

    private func resolveSelection(
        _ selection: EditionSelection,
        chapters: [Chapter]? = nil
    ) -> ResolvedEditionSelection? {
        if selection.references.isEmpty { return selection.resolve(in: []) }
        let catalog = chapters ?? host?.batchChapters ?? []
        return ScanlatorCatalogIndex(
            catalog,
            id: { $0.scanlatorID },
            name: { $0.scanlator }
        ).resolve(selection)
    }

    // MARK: - Presets

    /// Runs a menu preset. The remembered scanlator choice is read first; when the catalog spans several
    /// scanlators and none was remembered, the chooser comes first and the preset continues from it. A plan with
    /// nothing to confirm is queued at once; anything else is shown in the preview. The returned task lets a
    /// caller wait for the queueing.
    @discardableResult
    func startDownload(_ action: DownloadAction) -> Task<Void, Never> {
        invalidateMoreOperation()
        return startDownload(action, promptOperationID: nil)
    }

    /// Internal continuation for a confirmed More prompt. Its token must still own the visible prompt after every
    /// asynchronous read; once consumed by a chooser/preview or batch admission, the token no longer owns work.
    func startDownload(
        _ action: DownloadAction,
        promptOperationID: UUID?
    ) -> Task<Void, Never> {
        guard showsControls, !isEnqueuing, let scope = currentBatchScope() else {
            if let promptOperationID, pendingMoreOperationID == promptOperationID { invalidateMoreOperation() }
            return Task {}
        }
        return Task { [weak self] in
            guard let self else { return }
            let validPrompt = { self.isValidMoreOperation(promptOperationID) }
            guard validPrompt() else { return }
            guard await self.ensurePreferenceRead(validating: validPrompt),
                  validPrompt(),
                  self.isCurrent(scope),
                  self.showsControls,
                  !self.isEnqueuing else { return }
            await self.savedOnlyTask?.value
            guard validPrompt(),
                  self.isCurrent(scope),
                  self.showsControls,
                  !self.isEnqueuing else { return }
            switch self.remembered {
            case .chosen(let selection):
                let resolution = self.resolveSelection(selection)
                if resolution == nil {
                    guard self.consumeMoreOperation(promptOperationID) else { return }
                    self.sheet = .chooser(self.makeChooser(action: action, problem: .needsReview, scope: scope))
                } else if let resolution {
                    guard validPrompt() else { return }
                    await self.resolveDownload(
                        action, selection: resolution.selection, resolvedSelection: resolution, scope: scope,
                        promptOperationID: promptOperationID
                    )?.value
                }
            case .none:
                if self.scanlatorOptions().count >= 2 {
                    guard self.consumeMoreOperation(promptOperationID) else { return }
                    self.sheet = .chooser(self.makeChooser(action: action, problem: nil, scope: scope))
                } else if let resolution = self.resolveSelection(.sourceList) {
                    guard validPrompt() else { return }
                    await self.resolveDownload(
                        action, selection: resolution.selection, resolvedSelection: resolution, scope: scope,
                        promptOperationID: promptOperationID
                    )?.value
                }
            case .unreadable, .unknown:
                let problem: StoredChoiceProblem = self.remembered == .unreadable ? .unreadable : .readFailed
                if self.scanlatorOptions().count >= 2 {
                    guard self.consumeMoreOperation(promptOperationID) else { return }
                    self.sheet = .chooser(self.makeChooser(action: action, problem: problem, scope: scope))
                } else if let resolution = self.resolveSelection(.sourceList) {
                    guard validPrompt() else { return }
                    self.host?.presentBatchMessage(
                        problem == .unreadable ? .editionChoiceUnreadable : .editionChoiceReadFailed(reviewing: true)
                    )
                    await self.resolveDownload(
                        action, selection: resolution.selection, resolvedSelection: resolution,
                        alwaysPreview: true, scope: scope, promptOperationID: promptOperationID
                    )?.value
                }
            }
        }
    }

    /// Opens the scanlator chooser without a preset behind it ("Scanlators…"). The remembered choice is read
    /// first, so the chooser never opens on a default the series has already replaced.
    @discardableResult
    func openEditionChooser() -> Task<Void, Never> {
        invalidateMoreOperation()
        guard showsControls, let scope = currentBatchScope() else { return Task {} }
        return Task { [weak self] in
            await self?.ensurePreferenceRead()
            guard let self, self.isCurrent(scope), self.showsControls else { return }
            if self.remembered == .unknown {
                self.host?.presentBatchMessage(.editionChoiceReadFailed(reviewing: false))
                return
            }
            let resolution = self.resolveSelection(self.rememberedSelection)
            let unresolved: Bool
            if !self.rememberedSelection.references.isEmpty {
                unresolved = resolution == nil
            } else {
                unresolved = false
            }
            let problem: StoredChoiceProblem? = unresolved
                ? .needsReview
                : (self.remembered == .unreadable ? .unreadable : nil)
            self.sheet = .chooser(
                self.makeChooser(action: nil, problem: problem, resolvedSelection: resolution, scope: scope)
            )
        }
    }

    /// Applies the scanlators the user chose and continues with the preset that asked for the choice. With
    /// `remember` the choice is stored for the series first; without it, the choice applies to this batch only
    /// and nothing else changes. A choice made without a preset has no batch to apply to, so it is always
    /// remembered. A failed save leaves the draft editable; batch-only use is a separate explicit choice.
    func applyEditionChoice(
        _ selection: EditionSelection,
        remember: Bool,
        then action: DownloadAction?,
        chooserID: UUID? = nil
    ) -> Task<Void, Never> {
        guard showsControls, !isApplyingChoice, let scope = currentBatchScope() else { return Task {} }
        if let chooserID {
            guard case .chooser(let presentation)? = sheet,
                  presentation.id == chooserID,
                  presentation.identity == scope.identity,
                  presentation.scopeGeneration == scope.generation,
                  presentation.catalogDigest == scope.catalogDigest else { return Task {} }
            guard presentation.sourceEpoch == scope.sourceEpoch, presentation.policy == remembered else {
                closeStaleConsent()
                return Task {}
            }
        }
        guard let resolution = resolveSelection(selection) else { return Task {} }
        let reviewedSelection = resolution.selection
        if case .scanlators(let references) = reviewedSelection, references.isEmpty { return Task {} }
        isApplyingChoice = true
        let operationID = UUID()
        choiceOperationID = operationID
        let downloads = downloads
        return Task { [weak self] in
            defer {
                if let self, self.choiceOperationID == operationID {
                    self.choiceOperationID = nil
                    self.isApplyingChoice = false
                }
            }
            guard let self,
                  self.choiceOperationID == operationID,
                  self.isCurrent(scope),
                  self.host?.batchIdentity == scope.identity else { return }
            if let chooserID {
                guard case .chooser(let current)? = self.sheet, current.id == chooserID else { return }
            }
            var storeFailed = false
            var sourceChanged = false
            let store = remember || action == nil
            if store {
                do {
                    try await downloads.setEditionPreference(
                        reviewedSelection, for: scope.identity, sourceEpoch: scope.sourceEpoch
                    )
                } catch SeriesEditionPreferenceError.sourceChanged {
                    storeFailed = true
                    sourceChanged = true
                } catch {
                    storeFailed = true
                }
            }
            // A write already admitted to the store can finish after dismissal, a catalog refresh or a source
            // change. The database is the authority, so a stale sheet reloads it for the series that is saved
            // and shown now. It never installs the sheet's own choice, and a removed series is not reloaded.
            if store, !storeFailed,
               self.host?.batchIsSaved == true, self.host?.batchIdentity == scope.identity,
               self.choiceOperationID != operationID || !self.isCurrent(scope) || !self.ownsChooser(chooserID) {
                self.loadPreference(force: true)
            }
            guard self.choiceOperationID == operationID,
                  self.isCurrent(scope),
                  self.host?.batchIdentity == scope.identity else { return }
            if let chooserID {
                guard case .chooser(let current)? = self.sheet, current.id == chooserID else { return }
            }
            if store, !storeFailed { self.remembered = .chosen(reviewedSelection) }
            if sourceChanged {
                // The source changed after the review. Nothing was stored; the user reviews again.
                self.closeStaleConsent()
                return
            }
            if storeFailed {
                self.host?.presentBatchMessage(action == nil ? .editionChoiceNotSaved : .editionChoiceNotRemembered)
                self.sheet = .chooser(self.makeChooser(
                    action: action, problem: nil, initialSelection: reviewedSelection, scope: scope
                ))
                return
            }
            if let action {
                await self.resolveDownload(
                    action, selection: reviewedSelection, resolvedSelection: resolution, scope: scope
                )?.value
            } else {
                self.sheet = nil
            }
        }
    }

    /// Queues what the open preview lists, plus the other uploads the user ticked. The list must still be the
    /// one the preview was made from; if it changed, the preview is made again and nothing is queued. While a
    /// batch is being queued the preview stays open, so a second confirm is never dropped silently.
    @discardableResult
    func confirmDownloadPreview(
        including alternativeKeys: Set<String> = [],
        previewID: UUID? = nil
    ) -> Task<Void, Never> {
        guard case .preview(let preview)? = sheet, !isEnqueuing,
              previewID == nil || previewID == preview.id else { return Task {} }
        guard host?.batchIsSaved == true,
              host?.batchIdentity == preview.identity,
              scopeGeneration == preview.scopeGeneration else {
            sheet = nil
            return Task {}
        }
        guard preview.catalogDigest == catalogDigest else {
            revalidatePreview()
            return Task {}
        }
        guard isCurrentEpoch(preview.sourceEpoch, for: preview.identity), preview.policy == remembered else {
            closeStaleConsent()
            return Task {}
        }
        let scope = BatchScope(
            identity: preview.identity, generation: preview.scopeGeneration,
            catalogDigest: preview.catalogDigest, sourceEpoch: preview.sourceEpoch
        )
        guard isCurrent(scope) else {
            sheet = nil
            return Task {}
        }
        let wanted = Set(preview.toQueue.map(\.key))
            .union(preview.alternatives.map(\.key).filter(alternativeKeys.contains))
        let chapters = frozenChapters(keys: wanted)
        sheet = nil
        guard !chapters.isEmpty else {
            host?.presentBatchMessage(.nothingToDownload)
            return Task {}
        }
        return enqueueBatch(
            action: preview.action,
            selection: preview.selection,
            chapters: chapters,
            alreadyStored: preview.storedCount,
            scope: scope,
            policy: preview.policy
        ) ?? Task {}
    }

    func dismissDownloadSheet() {
        invalidateMoreOperation()
        sheet = nil
        choiceOperationID = nil
        isApplyingChoice = false
    }

    /// The screen is taking the download sheet for choosing a saved copy. A preset or chooser still waiting on
    /// a read must not present into it afterwards, so the scope generation moves on before the sheet and the
    /// choice are released. The catalog, coverage, summary and remembered choice stay as they are, and a batch
    /// already submitted finishes normally.
    func relinquishPresentationForLocalReading() {
        scopeGeneration &+= 1
        dismissDownloadSheet()
    }

    /// Replaces the download sheet with the count prompt. Kept in the main declaration because `sheet` has a
    /// private setter; the prompt continuation itself lives in the focused More extension.
    func presentDownloadMore() {
        invalidateMoreOperation()
        guard showsControls, !isEnqueuing, let identity = host?.batchIdentity else { return }
        sheet = .moreCount(DownloadMorePrompt(id: UUID(), identity: identity))
    }

    /// Editing fallback is a separate deliberate save, not promotion of checked exact uploads.
    func editFallbackOrder(previewID: UUID) {
        guard case .preview(let preview)? = sheet, preview.id == previewID,
              let scope = currentBatchScope(), preview.identity == scope.identity,
              preview.catalogDigest == scope.catalogDigest else { return }
        guard preview.sourceEpoch == scope.sourceEpoch, preview.policy == remembered else {
            closeStaleConsent()
            return
        }
        sheet = .chooser(makeChooser(
            action: preview.action, problem: nil, initialSelection: preview.selection, scope: scope
        ))
    }

    // MARK: - Planning

    private struct PlannedDownload {
        let chapters: [Chapter]
        let plan: DownloadPlan<Int>
    }

    private func planDownload(
        _ window: DownloadWindow,
        selection: EditionSelection,
        resolvedSelection: ResolvedEditionSelection,
        identity: MediaIdentity
    ) -> PlannedDownload {
        var chapters = host?.batchChapters ?? []
        var rows = chapters.map { chapter in
            DownloadPlanRow(
                facts: ChapterFacts(chapter),
                isRead: progress.isRead(media: identity, chapterID: chapter.key, chapterNumber: chapter.chapterNumber),
                stored: StoredEditionState(states[chapter.key])
            )
        }
        // A committed permitted copy can satisfy a current proven unit even when no longer listed.
        // Historical source order is never compared with the current response's order.
        if case .preferred = selection {
            var liveUnits: [ScanlatorUTF8: ChapterFacts] = [:]
            var listedKeys = Set(chapters.map { ScanlatorUTF8(value: $0.key) })
            for row in rows {
                if let unit = row.facts.sourceLogicalUnitID { liveUnits[ScanlatorUTF8(value: unit)] = row.facts }
            }
            for saved in policySavedOnlyChapters where states[saved.key] == .downloaded {
                let savedFacts = ChapterFacts(saved)
                guard let unit = savedFacts.sourceLogicalUnitID,
                      let live = liveUnits[ScanlatorUTF8(value: unit)],
                      listedKeys.insert(ScanlatorUTF8(value: saved.key)).inserted else { continue }
                chapters.append(saved)
                rows.append(DownloadPlanRow(
                    facts: ChapterFacts(
                        key: saved.key, number: live.number, volume: live.volume,
                        scanlator: saved.scanlator, scanlatorID: saved.scanlatorID,
                        logicalUnitID: unit, readingOrder: live.readingOrder
                    ),
                    isRead: progress.isRead(media: identity, chapterID: saved.key, chapterNumber: saved.chapterNumber),
                    stored: .verified
                ))
            }
        }
        let plan = DownloadPresetResolver.plan(
            rows: rows,
            window: window,
            selection: selection,
            anchorKey: progress.lastReadChapter(for: identity),
            resolvedSelection: resolvedSelection
        )
        return PlannedDownload(chapters: chapters, plan: plan)
    }

    private func isFailed(_ key: String) -> Bool {
        if case .failed? = states[key] { return true }
        return false
    }

    private func resolveDownload(
        _ action: DownloadAction,
        selection: EditionSelection,
        resolvedSelection: ResolvedEditionSelection,
        alwaysPreview: Bool = false,
        scope: BatchScope,
        promptOperationID: UUID? = nil
    ) -> Task<Void, Never>? {
        guard isCurrent(scope), isValidMoreOperation(promptOperationID) else { return nil }
        let planned = planDownload(
            action.window, selection: selection, resolvedSelection: resolvedSelection, identity: scope.identity
        )
        let holdsFailedJob = planned.plan.satisfied.contains { isFailed(planned.chapters[$0].key) }
        if alwaysPreview || planned.plan.requiresPreview || holdsFailedJob {
            guard consumeMoreOperation(promptOperationID) else { return nil }
            sheet = .preview(makePreview(planned, action: action, selection: selection, scope: scope, listChanged: false))
            loadAvailableCapacity()
            return nil
        }
        let queueable = planned.plan.toQueue.map { planned.chapters[$0] }
        guard !queueable.isEmpty else {
            guard consumeMoreOperation(promptOperationID) else { return nil }
            sheet = nil
            var explainsAbsence = false
            if case .preferred = selection {
                explainsAbsence = !planned.chapters.contains {
                    resolvedSelection.admits(scanlator: $0.scanlator, groupID: $0.scanlatorID)
                }
            }
            host?.presentBatchMessage(explainsAbsence ? .preferredGroupNotListed : .nothingToDownload)
            return nil
        }
        guard consumeMoreOperation(promptOperationID) else { return nil }
        sheet = nil
        return enqueueBatch(
            action: action,
            selection: selection,
            chapters: queueable,
            alreadyStored: planned.plan.satisfied.count,
            scope: scope,
            policy: remembered
        )
    }

    private func makePreview(
        _ planned: PlannedDownload,
        action: DownloadAction,
        selection: EditionSelection,
        scope: BatchScope,
        listChanged: Bool
    ) -> DownloadPreview {
        func rows(_ indices: [Int]) -> [DownloadPreviewRow] {
            indices.map { index in
                let chapter = planned.chapters[index]
                return DownloadPreviewRow(
                    key: chapter.key,
                    title: ReaderChapterTitle.text(title: chapter.title, number: chapter.chapterNumber),
                    scanlator: chapter.scanlator,
                    stored: StoredEditionState(states[chapter.key]),
                    isFailed: isFailed(chapter.key)
                )
            }
        }
        let plan = planned.plan
        return DownloadPreview(
            id: UUID(),
            action: action,
            selection: selection,
            identity: scope.identity,
            scopeGeneration: scope.generation,
            catalogDigest: scope.catalogDigest,
            sourceEpoch: scope.sourceEpoch,
            policy: remembered,
            toQueue: rows(plan.toQueue),
            satisfied: rows(plan.satisfied),
            damaged: rows(plan.damaged),
            locked: rows(plan.locked),
            alternatives: rows(plan.alternatives),
            skippedReadCount: plan.skippedReadCount,
            missingPositionCount: plan.missingPositionCount,
            issues: plan.issues,
            listChanged: listChanged
        )
    }

    /// Replaces an open preview made from a chapter list that has since changed.
    private func revalidatePreview() {
        guard case .preview(let preview)? = sheet else { return }
        guard let host, host.batchIsSaved, host.batchIdentity == preview.identity else {
            sheet = nil
            return
        }
        guard preview.catalogDigest != catalogDigest else { return }
        // A list change is not a user action: a policy changed meanwhile is never stamped onto the old selection.
        guard preview.policy == remembered, let scope = currentBatchScope(reportingFailure: false) else {
            closeStaleConsent()
            return
        }
        guard let resolution = resolveSelection(preview.selection) else {
            sheet = .chooser(
                makeChooser(
                    action: preview.action,
                    problem: .needsReview,
                    initialSelection: preview.selection,
                    scope: scope
                )
            )
            return
        }
        let planned = planDownload(
            preview.action.window, selection: resolution.selection,
            resolvedSelection: resolution, identity: scope.identity
        )
        sheet = .preview(
            makePreview(
                planned, action: preview.action, selection: resolution.selection,
                scope: scope, listChanged: true
            )
        )
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

    private func makeChooser(
        action: DownloadAction?,
        problem: StoredChoiceProblem?,
        resolvedSelection: ResolvedEditionSelection? = nil,
        initialSelection: EditionSelection? = nil,
        scope: BatchScope
    ) -> EditionChooserPresentation {
        EditionChooserPresentation(
            identity: scope.identity,
            scopeGeneration: scope.generation,
            catalogDigest: scope.catalogDigest,
            sourceEpoch: scope.sourceEpoch,
            policy: remembered,
            options: scanlatorOptions(),
            initialSelection: initialSelection ?? resolvedSelection?.selection ?? rememberedSelection,
            remember: problem != .readFailed,
            offersRemember: action != nil,
            action: action,
            storedChoiceProblem: problem
        )
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

/// A batch the user must decide about before it can use an expensive path (cellular or a hotspot). Only the
/// size is shown; the batch itself stays with the model, bound to the series and catalog it was planned for.
struct MeteredDownloadPrompt: Identifiable, Equatable {
    let id: UUID
    let chapterCount: Int
}
