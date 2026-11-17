import Foundation
import Testing
@testable import Ito

/// V1: the status of a rule is derived from its row alone, in a fixed order where the first match wins, and every
/// sentence is whole.
struct SubscriptionRuleStatusTests {
    private func status(_ row: SubscriptionRuleRow) -> SubscriptionRuleStatus { SubscriptionRuleStatus(row) }
    private typealias Fixture = SubscriptionRuleRowFixture

    @Test func theStatusFollowsTheDocumentedPrecedenceExactly() {
        #expect(status(Fixture.row(state: .disabled)) == .off)
        #expect(status(Fixture.row(state: .paused, pauseReason: .restored)) == .restoredNeedsReview)
        #expect(status(Fixture.row(state: .paused, pauseReason: .sourceRemapped)) == .sourceChangedNeedsReview)
        #expect(status(Fixture.row(state: .paused, pauseReason: .user)) == .paused)
        #expect(status(Fixture.row(sourceInstalled: false)) == .sourceNotInstalled)
        #expect(status(Fixture.row(configuration: nil)) == .selectionUnreadable)
        #expect(status(Fixture.row(lastAttemptOutcome: .selectionUnreadable)) == .selectionUnreadable)
        #expect(status(Fixture.row(hasBaseline: false, lastAttemptAt: nil, lastAttemptOutcome: nil))
            == .waitingForBaseline(.notChecked))
        #expect(status(Fixture.row(lastAttemptAt: Date(timeIntervalSince1970: 5), lastAttemptOutcome: .advanced))
            == .active(lastCheckedAt: Date(timeIntervalSince1970: 5), failure: nil))
    }

    @Test func aPausedOrOffRuleIsNeverSaidToBeUnreadableOrUninstalledAndAnUninstalledSourceBeatsALaterRow() {
        // Rows 2 to 4 win over everything below them.
        #expect(status(Fixture.row(state: .paused, pauseReason: .restored, configuration: nil, sourceInstalled: false))
            == .restoredNeedsReview)
        #expect(status(Fixture.row(state: .disabled, sourceInstalled: false)) == .off)
        // Row 5 beats rows 6 to 8.
        #expect(status(Fixture.row(configuration: nil, hasBaseline: false, sourceInstalled: false)) == .sourceNotInstalled)
        // Row 6 beats rows 7 and 8.
        #expect(status(Fixture.row(configuration: nil, hasBaseline: false)) == .selectionUnreadable)
    }

    @Test func aRuleWithoutABaselineSaysWhyTheLastCheckAcceptedNothing() {
        let reasons: [(SubscriptionCheckOutcome?, SubscriptionRuleStatus.WaitingReason)] = [
            (nil, .notChecked),
            (.incompleteCatalog, .incompleteCatalog), (.unknownScope, .unknownScope),
            (.emptyCatalog, .emptyCatalog), (.oversizedCatalog, .oversizedCatalog),
            (.fetchFailed, .fetchFailed), (.sourceChanged, .sourceChanged),
            (.seriesNotSaved, .other), (.superseded, .other)
        ]
        for (outcome, reason) in reasons {
            let row = Fixture.row(hasBaseline: false, lastAttemptAt: outcome == nil ? nil : Date(), lastAttemptOutcome: outcome)
            #expect(status(row) == .waitingForBaseline(reason), "\(String(describing: outcome))")
        }
    }

    @Test func anActiveRuleReportsAFailedLastCheckAsANoteAndASuccessAsNone() {
        let failures: [SubscriptionCheckOutcome: SubscriptionRuleStatus.CheckFailure] = [
            .fetchFailed: .fetchFailed, .incompleteCatalog: .incompleteCatalog, .unknownScope: .unknownScope,
            .emptyCatalog: .emptyCatalog, .oversizedCatalog: .oversizedCatalog, .sourceChanged: .sourceChanged
        ]
        for outcome in SubscriptionCheckOutcome.allCases where ![.selectionUnreadable].contains(outcome) {
            let result = status(Fixture.row(lastAttemptOutcome: outcome))
            guard case .active(_, let failure) = result else {
                Issue.record("\(outcome) should leave the rule active")
                continue
            }
            #expect(failure == failures[outcome], "\(outcome)")
            #expect((result.failureNote != nil) == (failures[outcome] != nil))
        }
    }

    @Test func everyStatusHasAWholeNonEmptySentenceAndOnlyAnActiveRuleHasALastChecked() {
        let all: [SubscriptionRuleStatus] = [
            .off, .restoredNeedsReview, .sourceChangedNeedsReview, .paused, .sourceNotInstalled, .selectionUnreadable,
            .waitingForBaseline(.notChecked), .waitingForBaseline(.incompleteCatalog), .waitingForBaseline(.unknownScope),
            .waitingForBaseline(.emptyCatalog), .waitingForBaseline(.oversizedCatalog), .waitingForBaseline(.fetchFailed),
            .waitingForBaseline(.sourceChanged), .waitingForBaseline(.other),
            .active(lastCheckedAt: nil, failure: nil), .active(lastCheckedAt: Date(), failure: .fetchFailed)
        ]
        for item in all {
            #expect(!item.title.isEmpty)
            #expect(!item.title.contains("%"), "An unresolved placeholder in \(item)")
            if case .active = item { continue }
            #expect(item.detail(now: Date()) == nil)
        }
        #expect(Set(all.map(\.title)).count == all.count - 1, "Only the two active rows share a title")
        #expect(SubscriptionRuleStatus.active(lastCheckedAt: nil, failure: nil).detail(now: Date()) != nil)
        let now = Date(timeIntervalSince1970: 10_000)
        let checked = SubscriptionRuleStatus.active(lastCheckedAt: now.addingTimeInterval(-300), failure: nil)
        #expect(checked.detail(now: now, locale: Locale(identifier: "en_US"))?.contains("5 minutes ago") == true)
    }

    @Test func theBadgesAreIndependentAndEachIsItsOwnSentence() {
        let row = Fixture.row(
            attentionCount: 2,
            pending: [.runCap: 1, .queueCap: 3, .quota: 1],
            queuedJobs: 4, heldJobs: 2, heldReason: .automaticSpaceFull
        )
        #expect(SubscriptionRuleBadge.badges(for: row) == [
            .attention(2), .moreAtNextCheck, .waitingForQueueRoom, .waitingForSpace, .held(.automaticSpaceFull)
        ])
        #expect(SubscriptionRuleBadge.badges(for: Fixture.row()) == [])
        #expect(SubscriptionRuleBadge.badges(for: Fixture.row(pending: [.queueCap: 1])) == [.waitingForQueueRoom])
        #expect(SubscriptionRuleBadge.badges(for: Fixture.row(pending: [.quota: 1])) == [.waitingForSpace])
        #expect(SubscriptionRuleBadge.badges(for: Fixture.row(pending: [.runCap: 2])) == [.moreAtNextCheck])
        // A paused rule promises no more chapters, but its held jobs and open choices are still true.
        let paused = Fixture.row(
            state: .paused, pauseReason: .user, attentionCount: 1, pending: [.queueCap: 1], heldJobs: 1,
            heldReason: .automaticRulePaused
        )
        #expect(SubscriptionRuleBadge.badges(for: paused) == [.attention(1), .held(.automaticRulePaused)])

        let titles = [SubscriptionRuleBadge.moreAtNextCheck, .waitingForQueueRoom, .waitingForSpace,
                      .held(.automaticRulePaused), .held(.automaticSpaceFull), .held(.automaticMeteredNotAllowed)].map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty && !$0.contains("%") })
        #expect(Set(titles).count == 5, "Waiting for space says the same thing as being held for space")
        #expect(SubscriptionRuleBadge.moreAtNextCheck.title == "More new chapters will be queued at the next check")
        #expect(SubscriptionRuleBadge.waitingForQueueRoom.title == "Waiting for room in the download queue")
        #expect(SubscriptionRuleBadge.waitingForSpace.title == "Waiting for automatic download space")
    }

    @Test func aCheckInTheFutureReadsAsJustNowAndASizeNeverReadsAsAWord() {
        let now = Date(timeIntervalSince1970: 10_000)
        let ahead = SubscriptionRuleStatus.active(lastCheckedAt: now.addingTimeInterval(30), failure: nil)
        let text = ahead.detail(now: now, locale: Locale(identifier: "en_US"))
        #expect(text?.contains("now") == true && text?.contains("in ") == false, "\(String(describing: text))")
        #expect(AutomaticDownloadsBytes.text(0) == "0 bytes")
        #expect(AutomaticDownloadsBytes.text(5 * (1 << 30)) == "5 GB", "The quota is binary, like its setting")
        #expect(!AutomaticDownloadsBytes.text(0).contains("Zero"))
    }

    @Test func aRulesHeldReasonDoesNotDependOnTheOrderItsJobsAreRead() {
        let reasons: [DownloadHoldReason] = [.automaticMeteredNotAllowed, .automaticSpaceFull, .automaticRulePaused]
        #expect(reasons.map(\.priority).sorted() == [0, 1, 2])
        #expect(DownloadHoldReason.automaticRulePaused.priority < DownloadHoldReason.automaticSpaceFull.priority)
        #expect(DownloadHoldReason.automaticSpaceFull.priority < DownloadHoldReason.automaticMeteredNotAllowed.priority)
    }

    @Test func theFooterNamesTheIntervalAndPromisesNothingAboutTheBackground() {
        let text = SubscriptionRuleFooter.text(intervalHours: 4)
        #expect(text == "Ito checks rules when it opens or when you refresh the Library, at most every 4 hours.")
        #expect(!text.lowercased().contains("background"))
    }

    @Test func aReviewReasonEventKindAndCommitReportAreEachWholeSentences() {
        for reason in SubscriptionReviewReason.allCases { #expect(reason.localizedExplanation.hasSuffix(".")) }
        for kind in SubscriptionEventKind.allCases { #expect(!kind.localizedSummary.isEmpty) }
        for refusal in [SubscriptionBackfillRefusal.unavailable, .unsupportedMode, .numberOnlyReadState,
                        .catalogUnreadable, .selectionUnreadable] {
            #expect(!refusal.localizedExplanation.isEmpty)
        }
        for message in [SubscriptionRuleMessage.stale, .sourceChanged, .seriesNotSaved, .reviewRequired,
                        .invalidConfiguration, .unavailable, .alreadyExists, .unsupportedKind, .failed] {
            #expect(!message.text.isEmpty)
        }
    }
}
