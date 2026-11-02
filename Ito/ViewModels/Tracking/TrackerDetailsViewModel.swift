import Combine
import Foundation

enum TrackerRemoteEntryPresentationState: Equatable {
    case loading
    case existing
    case new
    case failure
}

enum TrackerLocalProgressSyncCandidate: Equatable {
    case found(Int)
    case notFound
}

enum TrackerDetailsFailure: Equatable {
    case remoteUpdate
    case remoteUpdateExplanation(String)
    case linkPersistenceAfterRemoteUpdate
    case unlinkPersistence
    case progressWouldDecrease(providerName: String)

    var message: String {
        switch self {
        case .remoteUpdate:
            return String(localized: "Your tracker entry could not be updated. Please try again.")
        case .remoteUpdateExplanation(let message):
            return message
        case .linkPersistenceAfterRemoteUpdate:
            return String(localized: "The tracker entry was updated remotely, but the local link was not saved. Please retry to finish linking.")
        case .unlinkPersistence:
            return String(localized: "Tracking could not be stopped locally. Please try again.")
        case .progressWouldDecrease(let providerName):
            return String(localized: "\(providerName) progress only moves forward from Ito. Choose Repeating to start over, or change it on \(providerName).")
        }
    }
}

struct TrackerDetailsOutput: Equatable, Identifiable {
    enum Kind: Equatable {
        case saved(progress: Int?, status: String?)
        case unlinked
        case cancelled
    }

    let id: UUID
    let kind: Kind
}

@MainActor
final class TrackerDetailsViewModel: ObservableObject {
    static let statuses = [
        "CURRENT", "PLANNING", "COMPLETED", "DROPPED", "PAUSED", "REPEATING"
    ]

    let providerID: String
    let providerName: String
    let mediaIdentity: MediaIdentity
    let media: TrackerMedia
    let showCancelButton: Bool

    @Published private(set) var remoteEntryState: TrackerRemoteEntryPresentationState = .loading
    @Published var status: String? = "PLANNING"
    @Published var progress = "0" {
        didSet {
            if let value = Int(progress), value > 0, status == "PLANNING" {
                status = "CURRENT"
            }
        }
    }
    @Published private(set) var score: Double?
    @Published private(set) var scoreFormat: TrackerScoreFormat?
    @Published var scoreInput = "" {
        didSet {
            guard !isDurableOperationInFlight, scoreFormat == .numeric100,
                  let value = TrackerScoreFormat.parseNumericScore(scoreInput) else { return }
            score = value == 0 ? nil : value
        }
    }
    @Published private(set) var startDate: Date?
    @Published private(set) var finishDate: Date?
    /// The tracker status of the entry as last loaded from the remote, or `nil` when there is none.
    @Published private(set) var loadedStatus: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isUnlinking = false
    @Published private(set) var isOpeningExternalURL = false
    @Published private(set) var localProgressCandidate: TrackerLocalProgressSyncCandidate?
    @Published private(set) var failure: TrackerDetailsFailure?
    @Published private(set) var output: TrackerDetailsOutput?
    @Published private(set) var isLocallyLinked: Bool
    @Published var isPresentingLocalProgressAlert = false {
        didSet {
            if !isPresentingLocalProgressAlert {
                localProgressCandidate = nil
            }
        }
    }
    @Published var isPresentingFailureAlert = false {
        didSet {
            if !isPresentingFailureAlert {
                failure = nil
            }
        }
    }

    private let detailsService: any TrackerDetailsServicing
    private let linkStore: any TrackerLinkPersisting
    private let localProgressReader: any TrackerLocalProgressReading
    private let externalURLOpener: any TrackerExternalURLOpening
    private let messagePresenter: any TrackingMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var unlinkTask: Task<Void, Never>?
    private var externalURLTask: Task<Void, Never>?
    private var loadOperationID: UUID?
    private var saveOperationID: UUID?
    private var saveOperationKind: PresentationEventKind?
    private var unlinkOperationID: UUID?
    private var externalURLOperationID: UUID?
    private var hasStarted = false
    /// The progress of the entry as last loaded from the remote; `nil` when there is none.
    private var loadedProgress: Int?
    private var loadedScore: Double?
    private var scoreSession: TrackerScoreSession?
    /// The tracker's own explanation of the last load failure, when it has one.
    private var remoteLoadFailureMessage: String?

    init(
        destination: TrackerDetailsDestination,
        detailsService: any TrackerDetailsServicing,
        linkStore: any TrackerLinkPersisting,
        localProgressReader: any TrackerLocalProgressReading,
        externalURLOpener: any TrackerExternalURLOpening,
        messagePresenter: any TrackingMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        providerID = destination.providerID
        providerName = destination.providerName
        mediaIdentity = destination.mediaIdentity
        media = destination.media
        showCancelButton = destination.showCancelButton
        isLocallyLinked = destination.isLocallyLinked
        self.detailsService = detailsService
        self.linkStore = linkStore
        self.localProgressReader = localProgressReader
        self.externalURLOpener = externalURLOpener
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
    }

    var isLoadingEntry: Bool { remoteEntryState == .loading }

    var remoteLoadErrorMessage: String? {
        guard remoteEntryState == .failure else { return nil }
        return remoteLoadFailureMessage
            ?? String(localized: "Existing tracker progress could not be checked. Please retry before saving.")
    }

    var currentStatusLabel: String {
        media.isReadingFormat ? String(localized: "Reading") : String(localized: "Watching")
    }

    var totalProgress: Int? {
        media.episodes ?? media.chapters
    }

    var scoreText: String {
        if let scoreFormat { return scoreFormat.label(for: score ?? 0) }
        return score.map { String(format: "%.1f", $0) } ?? String(localized: "Not set")
    }

    var isScoreInputValid: Bool {
        scoreFormat != .numeric100 || TrackerScoreFormat.parseNumericScore(scoreInput) != nil
    }

    func setScore(_ value: Double) {
        guard !isDurableOperationInFlight, remoteEntryState == .existing || remoteEntryState == .new,
              let scoreFormat, scoreFormat.isValid(value) else { return }
        score = value == 0 ? nil : value
        if scoreFormat == .numeric100 { scoreInput = TrackerScoreFormat.numericStyle.format(value) }
    }

    var startDateText: String {
        startDate.map { Self.dateFormatter.string(from: $0) } ?? String(localized: "Not set")
    }

    var finishDateText: String {
        finishDate.map { Self.dateFormatter.string(from: $0) } ?? String(localized: "Not set")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var canStopTracking: Bool {
        isLocallyLinked && remoteEntryState != .loading
    }

    var isDurableOperationInFlight: Bool {
        isSaving || isUnlinking
    }

    static func statusLabel(for status: String, isReadingFormat: Bool) -> String {
        switch status {
        case "CURRENT": return isReadingFormat ? String(localized: "Reading") : String(localized: "Watching")
        case "PLANNING": return String(localized: "Planning")
        case "COMPLETED": return String(localized: "Completed")
        case "PAUSED": return String(localized: "Paused")
        case "DROPPED": return String(localized: "Dropped")
        case "REPEATING": return String(localized: "Repeating")
        default: return status.capitalized
        }
    }

    func displayLabel(for statusOption: String) -> String {
        Self.statusLabel(for: statusOption, isReadingFormat: media.isReadingFormat)
    }

    /// Explains when Ito's automatic updates are off for the loaded entry on trackers that only
    /// move entries the user is reading or watching. `nil` when they are on.
    var automaticSyncNote: String? {
        guard TrackerWriteRules.movesProgressForwardOnly(providerID), let loadedStatus else { return nil }
        switch loadedStatus {
        case "COMPLETED", "PAUSED", "DROPPED":
            return String(localized: "Automatic progress updates are off while this entry is \(displayLabel(for: loadedStatus)). Set it to \(currentStatusLabel) to resume them.")
        case "PLANNING":
            return media.isReadingFormat
                ? String(localized: "Ito marks this entry \(currentStatusLabel) when you start chapter 1.")
                : String(localized: "Ito marks this entry \(currentStatusLabel) when you start episode 1.")
        default:
            return nil
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        loadRemoteEntry()
    }

    func retryRemoteEntryLoad() {
        loadRemoteEntry()
    }

    func incrementProgress() {
        guard let value = Int(progress) else { return }
        progress = String(value + 1)
    }

    func decrementProgress() {
        guard let value = Int(progress), value > 0 else { return }
        progress = String(value - 1)
    }

    func prepareLocalProgressSync() {
        if let maximum = localProgressReader.readProgress(for: mediaIdentity).max() {
            localProgressCandidate = .found(Int(maximum))
        } else {
            localProgressCandidate = .notFound
        }
        isPresentingLocalProgressAlert = true
    }

    func cancelLocalProgressSync() {
        isPresentingLocalProgressAlert = false
    }

    func confirmLocalProgressSync() {
        if case .found(let maximum) = localProgressCandidate {
            progress = String(maximum)
        }
        isPresentingLocalProgressAlert = false
    }

    func openExternalURL() {
        guard externalURLOperationID == nil else { return }
        let operationID = UUID()
        externalURLOperationID = operationID
        isOpeningExternalURL = true
        presentationLogger.log(
            .started(
                feature: .trackerDetails,
                kind: .externalURL,
                operationID: operationID
            )
        )

        externalURLTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await externalURLOpener.open(providerID: providerID, media: media)
                guard externalURLOperationID == operationID, !Task.isCancelled else {
                    logIgnoredStale(kind: .externalURL, operationID: operationID)
                    return
                }
                finishExternalURL(operationID, outcome: .succeeded)
            } catch {
                guard externalURLOperationID == operationID, !Task.isCancelled else {
                    logIgnoredStale(kind: .externalURL, operationID: operationID)
                    return
                }
                messagePresenter.present(.externalURLOpenFailed)
                finishExternalURL(operationID, outcome: .failed(.externalURL))
            }
        }
    }

    func save() {
        guard saveOperationID == nil,
              unlinkOperationID == nil,
              remoteEntryState == .existing || remoteEntryState == .new, isScoreInputValid else { return }
        if TrackerWriteRules.movesProgressForwardOnly(providerID),
           remoteEntryState == .existing,
           status != "REPEATING",
           let loadedProgress, let newProgress = Int(progress), newProgress < loadedProgress {
            failure = .progressWouldDecrease(providerName: providerName)
            isPresentingFailureAlert = true
            return
        }

        let operationID = UUID()
        saveOperationID = operationID
        saveOperationKind = .remoteUpdate
        isSaving = true
        failure = nil
        let savedProgress = Int(progress)
        let savedStatus = status
        // Only an explicit changed selection writes a score. Zero clears it; nil preserves it.
        let selectedScore = score ?? 0
        let scoreChanged = scoreFormat == .numeric100 || selectedScore == 0
            ? selectedScore != (loadedScore ?? 0)
            : abs(selectedScore - (loadedScore ?? 0)) > 0.000_001
        let savedScore = scoreFormat != nil && scoreChanged ? selectedScore : nil
        let savedScoreSession = scoreSession
        // A rating-only save must not overwrite progress advanced while the sheet was open.
        let omitUnchanged = scoreFormat != nil && remoteEntryState == .existing
        let submittedProgress = omitUnchanged && savedProgress == loadedProgress ? nil : savedProgress
        let repeatingDecrease: Bool
        if TrackerWriteRules.movesProgressForwardOnly(providerID), savedStatus == "REPEATING",
           let target = savedProgress, let baseline = loadedProgress, target < baseline {
            repeatingDecrease = true
        } else {
            repeatingDecrease = false
        }
        let submittedStatus = omitUnchanged && savedStatus == loadedStatus && !repeatingDecrease ? nil : savedStatus
        let needsRemoteUpdate = !omitUnchanged || submittedProgress != nil || submittedStatus != nil || savedScore != nil
        presentationLogger.log(
            .started(
                feature: .trackerDetails,
                kind: .remoteUpdate,
                operationID: operationID
            )
        )

        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let savedScoreSession {
                    try detailsService.validateScoreSession(providerID: providerID, scoreSession: savedScoreSession)
                }
                if needsRemoteUpdate {
                    try await detailsService.updateEntry(
                        providerID: providerID,
                        mediaID: media.id,
                        progress: submittedProgress,
                        status: submittedStatus,
                        score: savedScore,
                        scoreSession: savedScoreSession
                    )
                }
                if let savedScoreSession {
                    try detailsService.validateScoreSession(providerID: providerID, scoreSession: savedScoreSession)
                }
            } catch is CancellationError {
                guard isCurrentSave(operationID) else {
                    logIgnoredStale(kind: .remoteUpdate, operationID: operationID)
                    return
                }
                finishCancelledSave(operationID)
                return
            } catch {
                guard isCurrentSave(operationID), !Task.isCancelled else {
                    logIgnoredStale(kind: .remoteUpdate, operationID: operationID)
                    return
                }
                failure = (error as? any TrackerUserFacingError).map { .remoteUpdateExplanation($0.userMessage) }
                    ?? .remoteUpdate
                isPresentingFailureAlert = true
                messagePresenter.present(.remoteUpdateFailed)
                finishSave(
                    operationID,
                    kind: .remoteUpdate,
                    outcome: .failed(.network)
                )
                return
            }

            guard isCurrentSave(operationID), !Task.isCancelled else {
                logIgnoredStale(kind: .remoteUpdate, operationID: operationID)
                return
            }
            // Keep acknowledged values if linking fails, so retrying does not replay stale edits.
            loadedProgress = savedProgress
            loadedStatus = savedStatus
            loadedScore = selectedScore == 0 ? nil : selectedScore
            remoteEntryState = .existing
            presentationLogger.log(
                .finished(
                    feature: .trackerDetails,
                    kind: .remoteUpdate,
                    operationID: operationID,
                    outcome: .succeeded
                )
            )

            if !isLocallyLinked {
                saveOperationKind = .link
                presentationLogger.log(
                    .started(
                        feature: .trackerDetails,
                        kind: .link,
                        operationID: operationID
                    )
                )
                do {
                    try await linkStore.link(
                        media: mediaIdentity,
                        providerID: providerID,
                        remoteMediaID: media.id,
                        scoreSession: savedScoreSession
                    )
                    // A returned link receipt is durable, even if this presentation became stale.
                    isLocallyLinked = isCurrentSave(operationID)
                        || linkStore.remoteMediaID(for: mediaIdentity, providerID: providerID) == media.id
                    if let savedScoreSession {
                        try detailsService.validateScoreSession(providerID: providerID, scoreSession: savedScoreSession)
                    }
                } catch {
                    guard isCurrentSave(operationID), !Task.isCancelled else {
                        logIgnoredStale(kind: .link, operationID: operationID)
                        return
                    }
                    if let explanation = error as? any TrackerUserFacingError {
                        failure = .remoteUpdateExplanation(explanation.userMessage)
                        messagePresenter.present(.remoteUpdateFailed)
                    } else {
                        failure = .linkPersistenceAfterRemoteUpdate
                        messagePresenter.present(.linkPersistenceFailed)
                    }
                    isPresentingFailureAlert = true
                    finishSave(
                        operationID,
                        kind: .link,
                        outcome: .failed(.persistence)
                    )
                    return
                }

                guard isCurrentSave(operationID), !Task.isCancelled else {
                    logIgnoredStale(kind: .link, operationID: operationID)
                    return
                }
                presentationLogger.log(
                    .finished(
                        feature: .trackerDetails,
                        kind: .link,
                        operationID: operationID,
                        outcome: .succeeded
                    )
                )
            }

            output = TrackerDetailsOutput(
                id: UUID(),
                kind: .saved(progress: savedProgress, status: savedStatus)
            )
            clearSaveOperation(operationID)
        }
    }

    func stopTracking() {
        guard unlinkOperationID == nil,
              saveOperationID == nil,
              isLocallyLinked else { return }

        let operationID = UUID()
        unlinkOperationID = operationID
        isUnlinking = true
        failure = nil
        presentationLogger.log(
            .started(
                feature: .trackerDetails,
                kind: .unlink,
                operationID: operationID
            )
        )

        unlinkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await linkStore.unlink(media: mediaIdentity, providerID: providerID)
            } catch is CancellationError {
                guard isCurrentUnlink(operationID) else {
                    logIgnoredStale(kind: .unlink, operationID: operationID)
                    return
                }
                finishUnlink(operationID, outcome: .cancelled)
                return
            } catch {
                guard isCurrentUnlink(operationID), !Task.isCancelled else {
                    logIgnoredStale(kind: .unlink, operationID: operationID)
                    return
                }
                failure = .unlinkPersistence
                isPresentingFailureAlert = true
                messagePresenter.present(.unlinkFailed)
                finishUnlink(operationID, outcome: .failed(.persistence))
                return
            }

            guard isCurrentUnlink(operationID), !Task.isCancelled else {
                logIgnoredStale(kind: .unlink, operationID: operationID)
                return
            }
            isLocallyLinked = false
            output = TrackerDetailsOutput(id: UUID(), kind: .unlinked)
            finishUnlink(operationID, outcome: .succeeded)
        }
    }

    func cancel() {
        guard !isDurableOperationInFlight else { return }
        output = TrackerDetailsOutput(id: UUID(), kind: .cancelled)
    }

    func dismissFailure() {
        isPresentingFailureAlert = false
    }

    func consumeOutput() -> TrackerDetailsOutput? {
        defer { output = nil }
        return output
    }

    func cancelOwnedWork() {
        cancelOperation(
            id: loadOperationID,
            task: loadTask,
            kind: .remoteLoad
        )
        loadOperationID = nil
        loadTask = nil

        cancelOperation(
            id: externalURLOperationID,
            task: externalURLTask,
            kind: .externalURL
        )
        externalURLOperationID = nil
        externalURLTask = nil
        isOpeningExternalURL = false

        cancelOperation(
            id: saveOperationID,
            task: saveTask,
            kind: saveOperationKind ?? .remoteUpdate
        )
        saveOperationID = nil
        saveOperationKind = nil
        saveTask = nil
        isSaving = false

        cancelOperation(id: unlinkOperationID, task: unlinkTask, kind: .unlink)
        unlinkOperationID = nil
        unlinkTask = nil
        isUnlinking = false
    }

    private func loadRemoteEntry() {
        cancelOperation(id: loadOperationID, task: loadTask, kind: .remoteLoad)
        let operationID = UUID()
        loadOperationID = operationID
        remoteLoadFailureMessage = nil
        scoreFormat = nil
        scoreSession = nil
        remoteEntryState = .loading
        presentationLogger.log(
            .started(
                feature: .trackerDetails,
                kind: .remoteLoad,
                operationID: operationID
            )
        )

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await detailsService.getScoreFormat(providerID: providerID)
                let entry: TrackerMediaEntry?
                if let session {
                    entry = try await detailsService.getScoredMediaListEntry(
                        providerID: providerID, mediaID: media.id, scoreSession: session
                    )
                } else {
                    entry = try await detailsService.getMediaListEntry(providerID: providerID, mediaID: media.id)
                }
                guard loadOperationID == operationID, !Task.isCancelled else {
                    logIgnoredStale(kind: .remoteLoad, operationID: operationID)
                    return
                }
                scoreSession = session
                scoreFormat = session?.format
                if let entry {
                    apply(entry)
                    remoteEntryState = .existing
                } else {
                    remoteEntryState = .new
                    loadedStatus = nil
                    loadedProgress = nil
                    score = nil
                    loadedScore = nil
                    scoreInput = TrackerScoreFormat.numericStyle.format(0)
                }
                finishLoad(operationID, outcome: .succeeded)
            } catch is CancellationError {
                guard loadOperationID == operationID else {
                    logIgnoredStale(kind: .remoteLoad, operationID: operationID)
                    return
                }
                remoteEntryState = .failure
                finishLoad(operationID, outcome: .cancelled)
            } catch {
                guard loadOperationID == operationID, !Task.isCancelled else {
                    logIgnoredStale(kind: .remoteLoad, operationID: operationID)
                    return
                }
                remoteLoadFailureMessage = (error as? any TrackerUserFacingError)?.userMessage
                remoteEntryState = .failure
                finishLoad(operationID, outcome: .failed(.network))
            }
        }
    }

    private func apply(_ entry: TrackerMediaEntry) {
        // Progress first: setting it while the status is still Planning would promote the loaded
        // entry to Reading or Watching through `progress`'s didSet.
        if let entryProgress = entry.progress {
            progress = String(entryProgress)
        }
        status = entry.status ?? "PLANNING"
        score = entry.score.flatMap { $0 > 0 ? $0 : nil }
        loadedScore = score
        scoreInput = TrackerScoreFormat.numericStyle.format(score ?? 0)
        startDate = entry.startDate
        finishDate = entry.finishDate
        loadedStatus = entry.status
        loadedProgress = entry.progress
    }

    private func finishLoad(_ operationID: UUID, outcome: PresentationEventOutcome) {
        guard loadOperationID == operationID else { return }
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: .remoteLoad,
                operationID: operationID,
                outcome: outcome
            )
        )
        loadOperationID = nil
        loadTask = nil
    }

    private func finishExternalURL(
        _ operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard externalURLOperationID == operationID else { return }
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: .externalURL,
                operationID: operationID,
                outcome: outcome
            )
        )
        externalURLOperationID = nil
        externalURLTask = nil
        isOpeningExternalURL = false
    }

    private func finishCancelledSave(_ operationID: UUID) {
        finishSave(operationID, kind: .remoteUpdate, outcome: .cancelled)
    }

    private func finishSave(
        _ operationID: UUID,
        kind: PresentationEventKind,
        outcome: PresentationEventOutcome
    ) {
        guard isCurrentSave(operationID) else { return }
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
        clearSaveOperation(operationID)
    }

    private func clearSaveOperation(_ operationID: UUID) {
        guard isCurrentSave(operationID) else { return }
        saveOperationID = nil
        saveOperationKind = nil
        saveTask = nil
        isSaving = false
    }

    private func finishUnlink(_ operationID: UUID, outcome: PresentationEventOutcome) {
        guard isCurrentUnlink(operationID) else { return }
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: .unlink,
                operationID: operationID,
                outcome: outcome
            )
        )
        unlinkOperationID = nil
        unlinkTask = nil
        isUnlinking = false
    }

    private func cancelOperation(
        id: UUID?,
        task: Task<Void, Never>?,
        kind: PresentationEventKind
    ) {
        guard let id else {
            task?.cancel()
            return
        }
        task?.cancel()
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: kind,
                operationID: id,
                outcome: .cancelled
            )
        )
    }

    private func logIgnoredStale(kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .finished(
                feature: .trackerDetails,
                kind: kind,
                operationID: operationID,
                outcome: .ignoredStale
            )
        )
    }

    private func isCurrentSave(_ operationID: UUID) -> Bool {
        saveOperationID == operationID
    }

    private func isCurrentUnlink(_ operationID: UUID) -> Bool {
        unlinkOperationID == operationID
    }
}
