import Combine
import Foundation
import ito_runner

/// What the rule sheet of a series needs from the screen that shows it. The management screen has no such screen, so
/// the sheet works without a host and shows the stored choice of groups as it is.
@MainActor
protocol SubscriptionRuleHost: AnyObject {
    var ruleIsSaved: Bool { get }
    /// The scanlators the series' current chapter list offers.
    var ruleScanlatorOptions: [ScanlatorOption] { get }
    /// The choice of groups the series remembers, which a new rule starts from.
    var ruleDefaultSelection: EditionSelection { get }
    var ruleCatalogDigest: String { get }
}

/// The values the rule sheet edits. They become a rule's configuration only when the person saves.
nonisolated struct SubscriptionRuleDraft: Equatable, Sendable {
    var mode: SubscriptionMode = .newReleases
    var windowSize = 5
    var perRunPositionCap = SubscriptionConfiguration.defaultPerRunPositionCap
    var selection: EditionSelection = .sourceList
    var replacesChangedChapters = false

    init(selection: EditionSelection = .sourceList) {
        self.selection = selection
    }

    init(_ configuration: SubscriptionConfiguration) {
        mode = configuration.mode
        windowSize = configuration.windowSize ?? 5
        perRunPositionCap = configuration.perRunPositionCap
        selection = configuration.selection
        replacesChangedChapters = configuration.replacementRule == .sameKeyReliableRevision
    }

    var configuration: SubscriptionConfiguration {
        SubscriptionConfiguration(
            mode: mode,
            windowSize: mode == .maintainNextUnread ? windowSize : nil,
            perRunPositionCap: perRunPositionCap,
            selection: selection,
            replacementRule: replacesChangedChapters ? .sameKeyReliableRevision : .off
        )
    }
}

/// What the sheet's main button does, by the rule's state.
nonisolated enum SubscriptionRulePrimaryAction: Equatable, Sendable {
    /// There is no rule, or it was turned off: create one.
    case turnOn
    /// The rule is enabled: apply the edit.
    case save
    /// The person paused the rule: enable it as it was.
    case resume
    /// A restore or a source change paused the rule: enable the configuration the person reviewed.
    case reviewAndTurnOn
}

/// The one presentation of the rule sheet. Its id names the session, so a completion that belongs to a sheet that was
/// dismissed publishes nothing.
struct SubscriptionRulePresentation: Identifiable, Equatable {
    let id = UUID()
}

/// The group chooser shown over the rule sheet.
struct SubscriptionGroupChoice: Identifiable, Equatable {
    let id = UUID()
    let presentation: EditionChooserPresentation
}

/// The rule of one series as its sheet and its entry row show it: enroll, edit, review to resume, pause and turn off.
/// It reads the rule by observation and never checks a source; every command is the store's, through the facade, and
/// every outcome is reported as the store gave it.
@MainActor
final class SubscriptionRuleModel: ObservableObject {
    /// What the entry row of the series screen shows.
    enum Entry: Equatable {
        /// Not offered: automatic downloads are not composed, or the series is an anime.
        case hidden
        /// The series is not in the Library, so no rule can exist.
        case addToLibrary
        /// The rule's status; nil until the rule has been read.
        case rule(SubscriptionRuleStatus?)
    }

    @Published private(set) var row: SubscriptionRuleRow?
    @Published private(set) var hasLoadedRow = false
    @Published var draft = SubscriptionRuleDraft()
    @Published private(set) var presentation: SubscriptionRulePresentation?
    @Published private(set) var message: SubscriptionRuleMessage?
    @Published private(set) var isWorking = false
    @Published private(set) var usage: AutomaticDownloadUsage?
    /// The newest usage read; an older read that finishes later is dropped.
    private var usageRead = 0
    @Published var groupChoice: SubscriptionGroupChoice?
    @Published var backfill: SubscriptionBackfillModel?
    @Published var review: SubscriptionEventReviewModel?

    weak var host: (any SubscriptionRuleHost)?
    let service: any AutomaticDownloadServing

    private var identity: MediaIdentity
    private let title: String?
    private var capturedEpoch: String?
    private var capturedGeneration: Int64?
    /// The row the sheet's draft and generation came from.
    private var capturedRow: SubscriptionRuleRow?
    /// Set after a refusal that changed what the sheet is about: the draft and the captured values are taken again from
    /// the row once it is a different row than the one the refusal was about.
    private var recaptureAfter: SubscriptionRuleRow??
    private var ruleSubscription: AnyCancellable?

    init(
        service: any AutomaticDownloadServing,
        identity: MediaIdentity,
        title: String? = nil,
        host: (any SubscriptionRuleHost)? = nil
    ) {
        self.service = service
        self.identity = identity
        self.title = title
        self.host = host
        follow(identity)
    }

    /// Follows another series, as a relink moves the screen to one. The sheet, if open, is closed.
    func follow(_ identity: MediaIdentity) {
        if presentation != nil, identity != self.identity { dismiss() }
        self.identity = identity
        row = nil
        hasLoadedRow = false
        ruleSubscription = service.rule(for: identity)
            .sink { @MainActor [weak self] row in self?.rowDidChange(row) }
    }

    private func rowDidChange(_ new: SubscriptionRuleRow?) {
        row = new
        hasLoadedRow = true
        if let from = recaptureAfter, from != new {
            recaptureAfter = nil
            capture()
        }
        // The numbers beside the limits follow the same observation as the rule.
        if presentation != nil { loadUsage() }
    }

    // MARK: - Entry

    var entry: Entry {
        guard service.isAvailable, identity.mediaKind != .anime else { return .hidden }
        let saved = host?.ruleIsSaved ?? (row != nil)
        guard saved else { return .addToLibrary }
        guard hasLoadedRow else { return .rule(nil) }
        return .rule(row.map(SubscriptionRuleStatus.init) ?? .off)
    }

    var seriesTitle: String? { row?.title ?? title }

    /// The sentences that go beside the status: the badges of the row.
    var badges: [SubscriptionRuleBadge] { row.map(SubscriptionRuleBadge.badges(for:)) ?? [] }

    var primaryAction: SubscriptionRulePrimaryAction {
        guard let row, row.state != .disabled else { return .turnOn }
        switch (row.state, row.pauseReason) {
        case (.enabled, _): return .save
        case (.paused, .user?): return .resume
        case (.paused, _): return .reviewAndTurnOn
        case (.disabled, _): return .turnOn
        }
    }

    /// Whether the draft can be edited: a rule the person paused is resumed as it was, and an edit is a separate edit.
    var canEditDraft: Bool { primaryAction != .resume }

    /// Whether the group choice has a chooser: the series screen knows the chapter list the groups come from.
    var canChooseGroups: Bool { host != nil && canEditDraft }

    var canReviewAttention: Bool { (row?.attentionCount ?? 0) > 0 && row?.state == .enabled }

    /// Whether unread chapters can be reviewed for download: an enabled rule that fills unread chapters, with its first
    /// chapter list accepted.
    var canReviewUnread: Bool {
        guard let row, row.state == .enabled, row.hasBaseline else { return false }
        return row.configuration?.mode == .newAndFillUnread
    }

    var canPause: Bool { row?.state == .enabled }
    var canTurnOff: Bool { row.map { $0.state != .disabled } ?? false }

    // MARK: - Presenting

    /// Opens the sheet. It captures the source's epoch and the rule's generation now: the store verifies both when the
    /// person saves, so a change in between is refused instead of overwritten.
    func open() {
        guard case .rule = entry, presentation == nil else { return }
        presentation = SubscriptionRulePresentation()
        message = nil
        recaptureAfter = nil
        capture()
        loadUsage()
    }

    func dismiss() {
        presentation = nil
        groupChoice = nil
        backfill = nil
        review = nil
        message = nil
        isWorking = false
        recaptureAfter = nil
    }

    private func capture() {
        capturedGeneration = row?.configGeneration
        capturedRow = row
        capturedEpoch = try? service.sourceEpoch(for: identity.pluginId)
        if let row, row.state != .disabled, let configuration = row.configuration {
            draft = SubscriptionRuleDraft(configuration)
        } else {
            draft = SubscriptionRuleDraft(selection: host?.ruleDefaultSelection ?? .sourceList)
        }
    }

    private func loadUsage() {
        guard let session = presentation?.id else { return }
        usageRead &+= 1
        let read = usageRead
        Task { [weak self, service] in
            let usage = await service.usage()
            guard let self, self.presentation?.id == session, read == self.usageRead else { return }
            self.usage = usage
        }
    }

    func presentGroupChoice() {
        guard canChooseGroups, let host else { return }
        groupChoice = SubscriptionGroupChoice(presentation: EditionChooserPresentation(
            identity: identity,
            scopeGeneration: 0,
            catalogDigest: host.ruleCatalogDigest,
            options: host.ruleScanlatorOptions,
            initialSelection: draft.selection,
            // The rule keeps its own copy: nothing here changes the series' remembered choice.
            remember: false,
            offersRemember: false,
            action: nil,
            storedChoiceProblem: nil
        ))
    }

    func chooseGroups(_ selection: EditionSelection) {
        draft.selection = selection
        groupChoice = nil
    }

    func presentAttentionReview() {
        guard canReviewAttention, let row else { return }
        review = SubscriptionEventReviewModel(subscriptionId: row.id, service: service)
    }

    func presentBackfill() {
        guard canReviewUnread, let row else { return }
        backfill = SubscriptionBackfillModel(subscriptionId: row.id, service: service)
    }

    // MARK: - Commands

    /// Runs the main action. The returned task lets a caller wait for it.
    @discardableResult
    func performPrimaryAction() -> Task<Void, Never> {
        let action = primaryAction
        let configuration = draft.configuration
        let generation = capturedGeneration
        let epoch = capturedEpoch
        let ruleId = row?.id
        let identity = identity
        return perform { service, session, model in
            switch action {
            case .turnOn:
                guard let epoch else { return model.finish(session, refusal: .sourceChanged) }
                let outcome = try await service.enable(SubscriptionEnableRequest(
                    media: identity, reviewedSourceEpoch: epoch, configuration: configuration
                ))
                switch outcome {
                case .enabled: model.finish(session, closing: true)
                case .alreadyExists: model.finish(session, refusal: .alreadyExists, recapture: true)
                case .refused(let refusal): model.finish(session, refusal: Self.message(for: refusal))
                }
            case .save:
                guard let ruleId, let generation else { return model.finish(session, refusal: .unavailable, recapture: true) }
                let outcome = try await service.edit(SubscriptionEdit(
                    subscriptionId: ruleId, expectedConfigGeneration: generation, configuration: configuration
                ))
                switch outcome {
                case .applied: model.finish(session, closing: true)
                case .stale: model.finish(session, refusal: .stale, recapture: true)
                case .unavailable: model.finish(session, refusal: .unavailable, recapture: true)
                case .invalidConfiguration: model.finish(session, refusal: .invalidConfiguration)
                }
            case .resume, .reviewAndTurnOn:
                guard let ruleId, let generation else { return model.finish(session, refusal: .unavailable, recapture: true) }
                let reviewed = action == .reviewAndTurnOn
                if reviewed, epoch == nil { return model.finish(session, refusal: .sourceChanged) }
                let outcome = try await service.resume(SubscriptionResumeRequest(
                    subscriptionId: ruleId,
                    expectedConfigGeneration: generation,
                    reviewedSourceEpoch: reviewed ? epoch : nil,
                    configuration: reviewed ? configuration : nil
                ))
                switch outcome {
                case .resumed: model.finish(session, closing: true)
                case .stale: model.finish(session, refusal: .stale, recapture: true)
                case .reviewRequired: model.finish(session, refusal: .reviewRequired, recapture: true)
                case .sourceChanged: model.finish(session, refusal: .sourceChanged)
                case .seriesNotSaved: model.finish(session, refusal: .seriesNotSaved)
                case .invalidConfiguration: model.finish(session, refusal: .invalidConfiguration)
                case .unavailable: model.finish(session, refusal: .unavailable, recapture: true)
                }
            }
        }
    }

    @discardableResult
    func pause() -> Task<Void, Never> {
        guard let id = row?.id, canPause else { return Task {} }
        return perform { service, session, model in
            try await service.pause(id: id)
            model.finish(session, closing: true)
        }
    }

    /// Turns the rule off. Downloaded chapters stay; queued automatic downloads are removed. The view asks first.
    @discardableResult
    func turnOff() -> Task<Void, Never> {
        guard let id = row?.id, canTurnOff else { return Task {} }
        return perform { service, session, model in
            try await service.turnOff(id: id)
            model.finish(session, closing: true)
        }
    }

    private func perform(
        _ body: @escaping @MainActor (any AutomaticDownloadServing, UUID, SubscriptionRuleModel) async throws -> Void
    ) -> Task<Void, Never> {
        guard let session = presentation?.id, !isWorking else { return Task {} }
        isWorking = true
        message = nil
        let service = service
        return Task { [weak self] in
            do {
                guard let self else { return }
                try await body(service, session, self)
            } catch {
                self?.finish(session, refusal: .failed)
            }
        }
    }

    /// Ends one command. A command whose sheet was dismissed meanwhile publishes nothing.
    private func finish(
        _ session: UUID,
        closing: Bool = false,
        refusal: SubscriptionRuleMessage? = nil,
        recapture: Bool = false
    ) {
        guard presentation?.id == session else { return }
        isWorking = false
        if closing {
            dismiss()
            return
        }
        message = refusal
        guard refusal != nil else { return }
        if recapture {
            if row?.configGeneration != capturedRow?.configGeneration {
                // The row the person is looking at is already newer than the one the sheet took: take it now. Waiting for
                // another change would never end, and the message says the sheet was reloaded.
                capture()
            } else {
                // The store holds a newer rule than the observation has delivered yet: start from it when it arrives.
                recaptureAfter = .some(row)
            }
        } else {
            capturedEpoch = try? service.sourceEpoch(for: identity.pluginId)
        }
    }

    private static func message(for refusal: SubscriptionRefusal) -> SubscriptionRuleMessage {
        switch refusal {
        case .unsupportedKind: .unsupportedKind
        case .sourceChanged: .sourceChanged
        case .seriesNotSaved: .seriesNotSaved
        case .invalidConfiguration: .invalidConfiguration
        }
    }
}

/// How a stored choice of groups reads in a sheet. Group names are source content and are shown as they are.
nonisolated enum SubscriptionSelectionSummary {
    static func text(_ selection: EditionSelection) -> String {
        switch selection {
        case .sourceList:
            return String(localized: "Follow the source's chapter list", comment: "Automatic downloads: the rule takes the chapters the source lists, whichever group made them")
        case .allUploads:
            return String(localized: "Every upload of every group", comment: "Automatic downloads: the rule takes every upload of a chapter")
        case .scanlators(let references):
            let names = ListFormatter.localizedString(byJoining: references.map(Self.name))
            return String(localized: "Only these groups: \(names)", comment: "Automatic downloads: the rule takes chapters of the chosen groups. The placeholder is the list of group names.")
        case .preferred(let primary, _):
            let name = Self.name(primary)
            return String(localized: "Prefer \(name)", comment: "Automatic downloads: the rule prefers the chapters of one group. The placeholder is the group's name.")
        }
    }

    private static func name(_ reference: ScanlatorRef) -> String {
        guard let name = reference.name, !name.isEmpty else {
            return String(localized: "No group listed", comment: "Scanlator choice: the chapters whose source names no scanlator.")
        }
        return name
    }
}
