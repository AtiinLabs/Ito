import Combine
import Foundation
import Testing
@testable import Ito

@MainActor
private final class FakePermission: NotificationAuthorizationRequesting {
    var grants = true
    private(set) var requests = 0
    func requestPermission() async -> Bool {
        requests += 1
        return grants
    }
}

@MainActor
private final class FakeSettingsOpener: ApplicationSettingsOpening {
    var opens = true
    private(set) var attempts = 0
    func openApplicationSettings() async -> Bool {
        attempts += 1
        return opens
    }
}

/// The management screen's model: the rules ordered for a person, the limits written through the acknowledged settings
/// store, and the opt-in notification setting with its permission request.
@MainActor
struct AutomaticDownloadsViewModelTests {
    private typealias Fixture = SubscriptionRuleRowFixture

    private struct Subject {
        let database: TestDatabase
        let service: FakeAutomaticDownloads
        let settings: AppSettingsStore
        let permission: FakePermission
        let opener: FakeSettingsOpener
        let model: AutomaticDownloadsViewModel
    }

    private func subject() async throws -> Subject {
        let database = try TestDatabase()
        let settings = AppSettingsStore(dbPool: database.dbPool, networkPolicy: NetworkPolicyCenter())
        try await settings.reload()
        let service = FakeAutomaticDownloads()
        let permission = FakePermission()
        let opener = FakeSettingsOpener()
        let model = AutomaticDownloadsViewModel(
            service: service, settingsStore: settings, notificationAuthorization: permission,
            applicationSettingsOpener: opener
        )
        return Subject(database: database, service: service, settings: settings, permission: permission, opener: opener, model: model)
    }

    @Test func rulesThatWaitForAPersonComeFirstThenByTitleAndARuleWithoutATitleIsLast() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        s.service.publish([
            Fixture.row(id: "d", title: "Beta"),
            Fixture.row(id: "c", title: nil),
            Fixture.row(id: "b", title: "Zeta", attentionCount: 2),
            Fixture.row(id: "a", title: "alpha"),
            Fixture.row(id: "e", title: "Chapter 10"),
            Fixture.row(id: "f", title: "Chapter 9")
        ])

        #expect(s.model.hasLoaded)
        #expect(s.model.rows.map(\.id) == ["b", "a", "d", "f", "e", "c"])
    }

    @Test func aRuleThatIsTurnedOffIsNotListed() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        s.service.publish([Fixture.row(id: "a"), Fixture.row(id: "b", state: .disabled)])
        #expect(s.model.rows.map(\.id) == ["a"])
    }

    @Test func theLimitsAreWrittenThroughTheAcknowledgedSettingsAndTheModelFollowsThem() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        #expect(s.model.queueLimit == 100 && s.model.quotaGiB == 5)

        await s.model.setQueueLimit(250)
        await s.model.setQuotaGiB(20)

        #expect(s.settings.automaticDownloadQueueLimit == 250 && s.settings.automaticDownloadQuotaGiB == 20)
        #expect(s.model.queueLimit == 250 && s.model.quotaGiB == 20)
        #expect(s.settings.automaticDownloadLimits == AutomaticDownloadLimits(queueLimit: 250, quotaGiB: 20))
        #expect(s.model.alert == nil)

        // A value outside the range is refused by the settings and the model says so.
        await s.model.setQueueLimit(9)
        #expect(s.model.alert == .saveFailed && s.model.queueLimit == 250)
        s.model.dismissAlert()
        #expect(s.model.alert == nil)
    }

    @Test func attentionNotificationsAreOffByDefaultAndTurningThemOnAsksThePermissionOnce() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        #expect(!s.model.attentionNotifications && !s.settings.subscriptionAttentionNotifications)
        #expect(s.permission.requests == 0, "Opening the screen asks for nothing")

        await s.model.setAttentionNotifications(true)

        #expect(s.permission.requests == 1)
        #expect(s.settings.subscriptionAttentionNotifications && s.model.attentionNotifications)
        #expect(s.model.alert == nil)

        await s.model.setAttentionNotifications(false)
        #expect(!s.settings.subscriptionAttentionNotifications && s.permission.requests == 1)
    }

    @Test func aRefusedPermissionTurnsTheSettingBackOffAndSaysWhy() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        s.permission.grants = false

        await s.model.setAttentionNotifications(true)

        #expect(!s.settings.subscriptionAttentionNotifications && !s.model.attentionNotifications)
        #expect(s.model.alert == .notificationsDenied)

        await s.model.openApplicationSettings()
        #expect(s.opener.attempts == 1 && s.model.alert == nil)
        s.opener.opens = false
        await s.model.openApplicationSettings()
        #expect(s.model.alert == .applicationSettingsOpenFailed)
        #expect(AutomaticDownloadsAlert.notificationsDenied.message.contains("Settings"))
    }

    @Test func opensTheSheetOfARowAndTheReviewOnlyForARuleThatWaitsForAPerson() async throws {
        let s = try await subject()
        defer { s.database.cleanup() }
        s.model.attach()
        let plain = Fixture.row(id: "a")
        let waiting = Fixture.row(id: "b", attentionCount: 1)
        s.service.publish([plain, waiting])

        s.model.openReview(plain)
        #expect(s.model.review == nil)
        s.model.openReview(waiting)
        #expect(s.model.review?.subscriptionId == "b")

        s.model.open(plain)
        #expect(s.model.openRule?.presentation != nil)
        #expect(s.model.openRule?.canChooseGroups == false, "The chapter list belongs to the series screen")
        s.model.closeRule()
        #expect(s.model.openRule == nil)
        #expect(s.service.commandCount == 0)
    }

    @Test func theNotificationSettingStartsOffInTheCatalog() {
        #expect(AppPreferenceCatalog.subscriptionAttentionNotifications.defaultValue == false)
        #expect(AppPreferenceKeys.subscriptionAttentionNotifications == "Ito.SubscriptionAttentionNotifications")
    }
}
