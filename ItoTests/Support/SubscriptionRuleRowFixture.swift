import Foundation
import ito_runner
@testable import Ito

/// A rule row with everything a test does not care about at a harmless value.
enum SubscriptionRuleRowFixture {
    static let media = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    static func row(
        id: String = "rule-1",
        media: MediaIdentity = SubscriptionRuleRowFixture.media,
        title: String? = "Series",
        state: SubscriptionState = .enabled,
        pauseReason: SubscriptionPauseReason? = nil,
        configuration: SubscriptionConfiguration? = SubscriptionConfiguration(),
        incarnation: Int64 = 1,
        configGeneration: Int64 = 1,
        hasBaseline: Bool = true,
        lastAttemptAt: Date? = Date(timeIntervalSince1970: 1_000),
        lastAttemptOutcome: SubscriptionCheckOutcome? = .unchanged,
        attentionCount: Int = 0,
        pending: [SubscriptionPendingReason: Int] = [:],
        queuedJobs: Int = 0,
        heldJobs: Int = 0,
        heldReason: DownloadHoldReason? = nil,
        sourceInstalled: Bool = true
    ) -> SubscriptionRuleRow {
        SubscriptionRuleRow(
            id: id, media: media, title: title, state: state, pauseReason: pauseReason,
            configuration: configuration, incarnation: incarnation, configGeneration: configGeneration,
            hasBaseline: hasBaseline, baselineAcceptedAt: hasBaseline ? lastAttemptAt : nil,
            lastAttemptAt: lastAttemptAt, lastAttemptOutcome: lastAttemptOutcome, lastSuccessAt: lastAttemptAt,
            attentionCount: attentionCount, pending: pending, queuedJobs: queuedJobs, heldJobs: heldJobs,
            heldReason: heldReason, sourceInstalled: sourceInstalled
        )
    }
}
