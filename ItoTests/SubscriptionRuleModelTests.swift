import Combine
import Foundation
import ito_runner
import Testing
@testable import Ito

/// Holds a command at a point until the test lets it go, and tells the test when it got there.
@MainActor
final class CommandGate {
    private var arrival: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    private var release: CheckedContinuation<Void, Never>?

    func pass() async {
        hasArrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilReached() async {
        if hasArrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

/// V3 to V5: the sheet of a series' rule. It captures the source's epoch and the rule's generation when it opens, says
/// only what the store said, and a completion that belongs to a sheet that was dismissed publishes nothing.
@MainActor
struct SubscriptionRuleModelTests {
    private typealias Fixture = SubscriptionRuleRowFixture
    private let media = Fixture.media

    private func make(
        kind: MediaKind = .manga,
        saved: Bool = true,
        rows: [SubscriptionRuleRow]? = []
    ) -> (FakeAutomaticDownloads, FakeRuleHost, SubscriptionRuleModel) {
        let service = FakeAutomaticDownloads()
        let host = FakeRuleHost()
        host.ruleIsSaved = saved
        service.retained = host
        let identity = MediaIdentity(pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: kind)
        let model = SubscriptionRuleModel(service: service, identity: identity, title: "Series", host: host)
        if let rows { service.publish(rows) }
        return (service, host, model)
    }

    // MARK: - V3: enrollment

    @Test func v3_theEpochCapturedWhenTheSheetOpensIsTheOneTheStoreChecksAndARotationIsRefusedWithoutASuccess() async throws {
        let (service, _, model) = make()
        model.open()
        #expect(model.primaryAction == .turnOn)
        #expect(service.epochReads == 1)

        // The source's settings change before Save: the store refuses, because it holds the epoch the person reviewed.
        service.epoch = "epoch-2"
        service.enableOutcome = .refused(.sourceChanged)
        await model.performPrimaryAction().value

        #expect(service.enables.map(\.reviewedSourceEpoch) == ["epoch-1"])
        #expect(model.message == .sourceChanged)
        #expect(model.presentation != nil, "A refusal leaves the sheet open and claims nothing")
        #expect(model.row == nil)
        #expect(!model.isWorking)

        // The sheet takes the new epoch; the next Save is the person's review of it.
        service.enableOutcome = .enabled(id: "rule-1", incarnation: 1)
        await model.performPrimaryAction().value
        #expect(service.enables.map(\.reviewedSourceEpoch) == ["epoch-1", "epoch-2"])
        #expect(model.presentation == nil)
    }

    @Test func v3_aSeriesThatIsNotInTheLibraryAndAnAnimeOfferNoAction() {
        let (service, _, notSaved) = make(saved: false)
        #expect(notSaved.entry == .addToLibrary)
        notSaved.open()
        #expect(notSaved.presentation == nil)
        #expect(service.epochReads == 0)

        let (_, _, anime) = make(kind: .anime)
        #expect(anime.entry == .hidden)
        anime.open()
        #expect(anime.presentation == nil)

        let unavailable = SubscriptionRuleModel(
            service: UnavailableAutomaticDownloads(), identity: media, host: FakeRuleHost()
        )
        #expect(unavailable.entry == .hidden)
    }

    @Test func theEntryNamesTheRuleStatusAndNeverSaysAnythingBeforeTheRuleWasRead() {
        let (service, _, model) = make(rows: nil)
        #expect(model.entry == .rule(nil))

        service.publish([])
        #expect(model.entry == .rule(.off))
        service.publish([Fixture.row(state: .paused, pauseReason: .user)])
        #expect(model.entry == .rule(.paused))
        service.publish([Fixture.row(state: .disabled)])
        #expect(model.entry == .rule(.off))
    }

    @Test func aNewRuleStartsFromTheSeriesRememberedGroupsAndTheDocumentedDefaults() {
        let (_, host, model) = make()
        host.ruleDefaultSelection = .allUploads
        model.open()
        let draft = model.draft
        #expect(draft.selection == .allUploads)
        #expect(draft.mode == .newReleases && draft.windowSize == 5 && draft.perRunPositionCap == 5)
        #expect(!draft.replacesChangedChapters)
        #expect(draft.configuration.windowSize == nil, "A window size belongs to Keep Next N only")
        #expect(draft.configuration.isValid)

        var keep = draft
        keep.mode = .maintainNextUnread
        keep.windowSize = 7
        #expect(keep.configuration.windowSize == 7 && keep.configuration.isValid)
        keep.replacesChangedChapters = true
        #expect(keep.configuration.replacementRule == .sameKeyReliableRevision)
    }

    @Test func aRefusalOfTheEnableIsShownAsFixedMessagesAndAnExistingRuleReloadsTheRow() async throws {
        let (service, _, model) = make()
        model.open()
        let cases: [(SubscriptionEnableOutcome, SubscriptionRuleMessage)] = [
            (.refused(.seriesNotSaved), .seriesNotSaved), (.refused(.invalidConfiguration), .invalidConfiguration),
            (.refused(.unsupportedKind), .unsupportedKind), (.alreadyExists(id: "rule-9"), .alreadyExists)
        ]
        for (outcome, message) in cases {
            service.enableOutcome = outcome
            await model.performPrimaryAction().value
            #expect(model.message == message)
            #expect(model.presentation != nil)
        }
        // The rule that exists is read in; the sheet then works on it, from its own generation.
        service.publish([Fixture.row(id: "rule-9", configGeneration: 4)])
        #expect(model.primaryAction == .save)
        service.editOutcome = .applied(configGeneration: 5)
        await model.performPrimaryAction().value
        #expect(service.edits.last?.expectedConfigGeneration == 4)
    }

    @Test func aFailedWriteSaysSoAndKeepsTheSheet() async {
        let (service, _, model) = make()
        model.open()
        service.commandError = AutomaticDownloadsError.unavailable
        await model.performPrimaryAction().value
        #expect(model.message == .failed)
        #expect(model.presentation != nil && !model.isWorking)
    }

    // MARK: - V4: edit

    @Test func v4_anEditWithAStaleGenerationIsRefusedReloadedAndTheNextSaveCarriesTheCurrentGeneration() async throws {
        let (service, _, model) = make(rows: [Fixture.row(configGeneration: 3)])
        model.open()
        #expect(model.primaryAction == .save)
        model.draft.perRunPositionCap = 9

        service.editOutcome = .stale
        await model.performPrimaryAction().value
        #expect(service.edits.map(\.expectedConfigGeneration) == [3])
        #expect(model.message == .stale)
        #expect(model.presentation != nil)

        // The stored rule moved on (an edit elsewhere): the sheet takes it, draft included.
        service.publish([Fixture.row(configuration: SubscriptionConfiguration(perRunPositionCap: 2), configGeneration: 4)])
        #expect(model.draft.perRunPositionCap == 2, "The reload replaces the draft with what is stored")
        service.editOutcome = .applied(configGeneration: 5)
        await model.performPrimaryAction().value
        #expect(service.edits.map(\.expectedConfigGeneration) == [3, 4])
        #expect(model.presentation == nil)
    }

    @Test func v4_aSheetDismissedBeforeItsCommandEndsPublishesNothingWhenTheCommandFinishes() async throws {
        let (service, _, model) = make(rows: [Fixture.row(configGeneration: 3)])
        let gate = CommandGate()
        service.gate = { await gate.pass() }
        service.editOutcome = .stale
        model.open()
        let command = model.performPrimaryAction()
        await gate.waitUntilReached()
        #expect(model.isWorking)

        model.dismiss()
        gate.open()
        await command.value

        #expect(model.message == nil, "A late refusal is not shown on a sheet that is gone")
        #expect(model.presentation == nil && !model.isWorking)

        // A sheet opened afterwards starts clean and works.
        service.gate = nil
        service.editOutcome = .applied(configGeneration: 4)
        model.open()
        #expect(model.message == nil && !model.isWorking)
        await model.performPrimaryAction().value
        #expect(model.presentation == nil)
    }

    @Test func aSecondCommandWhileOneRunsIsIgnored() async {
        let (service, _, model) = make(rows: [Fixture.row()])
        let gate = CommandGate()
        service.gate = { await gate.pass() }
        model.open()
        let first = model.performPrimaryAction()
        await gate.waitUntilReached()
        await model.performPrimaryAction().value
        #expect(service.edits.count == 1)
        gate.open()
        await first.value
    }

    // MARK: - V5: a restored rule

    @Test func v5_aRestoredRuleIsTurnedOnOnlyWithTheShownConfigurationAndTheEpochItWasReviewedUnder() async throws {
        let stored = SubscriptionConfiguration(
            mode: .maintainNextUnread, windowSize: 8, perRunPositionCap: 3, selection: .allUploads,
            replacementRule: .sameKeyReliableRevision
        )
        let restored = Fixture.row(
            state: .paused, pauseReason: .restored, configuration: stored, configGeneration: 2,
            hasBaseline: false, lastAttemptAt: nil, lastAttemptOutcome: nil
        )
        let (service, _, model) = make(rows: [restored])
        model.open()
        #expect(model.primaryAction == .reviewAndTurnOn)
        #expect(model.draft.configuration == stored, "The sheet shows the stored configuration")
        #expect(model.canEditDraft)

        service.resumeOutcome = .resumed(configGeneration: 3)
        await model.performPrimaryAction().value

        let request = try #require(service.resumes.first)
        #expect(request.subscriptionId == "rule-1" && request.expectedConfigGeneration == 2)
        #expect(request.reviewedSourceEpoch == "epoch-1")
        #expect(request.configuration == stored)
        #expect(model.presentation == nil)

        // The store enabled it, and it waits for its first chapter list.
        service.publish([Fixture.row(
            configuration: stored, configGeneration: 3, hasBaseline: false, lastAttemptAt: nil, lastAttemptOutcome: nil
        )])
        #expect(model.entry == .rule(.waitingForBaseline(.notChecked)))
    }

    @Test func aRuleThePersonPausedIsResumedAsItWasWithNoConfigurationAndNoEpoch() async throws {
        let (service, _, model) = make(rows: [Fixture.row(state: .paused, pauseReason: .user, configGeneration: 6)])
        model.open()
        #expect(model.primaryAction == .resume)
        #expect(!model.canEditDraft, "An edit is a separate edit")

        await model.performPrimaryAction().value

        let request = try #require(service.resumes.first)
        #expect(request.expectedConfigGeneration == 6)
        #expect(request.reviewedSourceEpoch == nil && request.configuration == nil)
    }

    @Test func everyRefusalOfAResumeIsAFixedMessageNeverASuccess() async {
        let (service, _, model) = make(rows: [Fixture.row(state: .paused, pauseReason: .restored)])
        model.open()
        let cases: [(SubscriptionResumeOutcome, SubscriptionRuleMessage)] = [
            (.stale, .stale), (.reviewRequired, .reviewRequired), (.sourceChanged, .sourceChanged),
            (.seriesNotSaved, .seriesNotSaved), (.invalidConfiguration, .invalidConfiguration), (.unavailable, .unavailable)
        ]
        for (outcome, message) in cases {
            service.resumeOutcome = outcome
            await model.performPrimaryAction().value
            #expect(model.message == message, "\(outcome)")
            #expect(model.presentation != nil)
        }
    }

    @Test func aRestoredRuleWhoseSourceHasNoEpochCannotBeReviewedAndAsksNothingOfTheStore() async {
        let (service, _, model) = make(rows: [Fixture.row(state: .paused, pauseReason: .restored)])
        service.epochFailure = true
        model.open()
        await model.performPrimaryAction().value
        #expect(service.resumes.isEmpty)
        #expect(model.message == .sourceChanged)
    }

    // MARK: - Pause and turn off

    @Test func pausingAndTurningOffGoThroughTheFacadeAndCloseTheSheet() async {
        let (service, _, model) = make(rows: [Fixture.row()])
        model.open()
        #expect(model.canPause && model.canTurnOff)
        await model.pause().value
        #expect(service.pauses == ["rule-1"] && model.presentation == nil)

        model.open()
        await model.turnOff().value
        #expect(service.turnOffs == ["rule-1"] && model.presentation == nil)
    }

    @Test func aPausedRuleCannotBePausedAgainAndAnOffRuleCannotBeTurnedOff() {
        let (_, _, paused) = make(rows: [Fixture.row(state: .paused, pauseReason: .user)])
        #expect(!paused.canPause && paused.canTurnOff)
        let (_, _, off) = make(rows: [Fixture.row(state: .disabled)])
        #expect(!off.canTurnOff && off.primaryAction == .turnOn)
    }

    // MARK: - Chooser and sub-sheets

    @Test func theRulesGroupChoiceIsItsOwnCopyAndIsOfferedOnlyWithAChapterList() {
        let (_, host, model) = make()
        host.ruleScanlatorOptions = [ScanlatorOption(ref: ScanlatorRef(id: "ga", name: "A"), chapterCount: 3)]
        model.open()
        model.presentGroupChoice()
        let choice = model.groupChoice
        #expect(choice?.presentation.options.count == 1)
        #expect(choice?.presentation.offersRemember == false && choice?.presentation.remember == false)
        #expect(choice?.presentation.action == nil)

        let picked = EditionSelection.scanlators([ScanlatorRef(id: "ga", name: "A")])
        model.chooseGroups(picked)
        #expect(model.draft.selection == picked && model.groupChoice == nil)

        let hostless = SubscriptionRuleModel(service: FakeAutomaticDownloads(), identity: media)
        #expect(!hostless.canChooseGroups)
        #expect(SubscriptionSelectionSummary.text(picked).contains("A"))
    }

    @Test func theReviewAndBackfillSheetsOpenOnlyWhereTheyApply() {
        let fill = SubscriptionConfiguration(mode: .newAndFillUnread)
        let (_, _, withFill) = make(rows: [Fixture.row(configuration: fill, attentionCount: 2)])
        #expect(withFill.canReviewAttention && withFill.canReviewUnread)
        withFill.open()
        withFill.presentAttentionReview()
        withFill.presentBackfill()
        #expect(withFill.review?.subscriptionId == "rule-1" && withFill.backfill?.subscriptionId == "rule-1")

        let (_, _, plain) = make(rows: [Fixture.row()])
        #expect(!plain.canReviewAttention && !plain.canReviewUnread)
        let (_, _, waiting) = make(rows: [Fixture.row(configuration: fill, hasBaseline: false)])
        #expect(!waiting.canReviewUnread, "There is no accepted chapter list to review yet")
    }

    // MARK: - A20: showing a screen asks nothing of a source and writes nothing

    @Test func openingTheSheetAndReadingTheRuleNeverCommandsAnythingOrChecksASource() async {
        let (service, _, model) = make(rows: [Fixture.row(attentionCount: 1)])
        model.open()
        _ = model.entry
        _ = model.badges
        model.presentAttentionReview()
        await model.review?.load().value
        model.dismiss()
        #expect(service.commandCount == 0)
    }
}
