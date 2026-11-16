import Combine
import Foundation

/// A message of the management screen that the person must see.
enum AutomaticDownloadsAlert: Identifiable, Equatable {
    case saveFailed
    case notificationsDenied
    case notificationRollbackFailed
    case applicationSettingsOpenFailed

    var id: Self { self }

    var title: String {
        switch self {
        case .saveFailed:
            String(localized: "Unable to Save", comment: "Automatic downloads: title of the alert when a limit or setting could not be saved")
        case .notificationsDenied:
            String(localized: "Notifications Are Off", comment: "Automatic downloads: title of the alert when the system does not allow notifications")
        case .notificationRollbackFailed:
            String(localized: "Unable to Turn Off Alerts", comment: "Automatic downloads: title of the alert when the alert setting could not be turned off after notifications were refused")
        case .applicationSettingsOpenFailed:
            String(localized: "Unable to Open Settings", comment: "Automatic downloads: title of the alert when the device Settings app could not be opened")
        }
    }

    var message: String {
        switch self {
        case .saveFailed:
            String(localized: "Your change could not be saved. Try again.", comment: "Automatic downloads: the alert when a limit or setting could not be saved")
        case .notificationsDenied:
            String(localized: "Allow notifications for Ito in your device Settings to hear when new chapters need your decision.", comment: "Automatic downloads: the alert when notifications are not allowed")
        case .notificationRollbackFailed:
            String(localized: "Notifications were refused, but the setting could not be turned off. Try again.", comment: "Automatic downloads: the alert when the alert setting stays on after notifications were refused")
        case .applicationSettingsOpenFailed:
            String(localized: "Ito could not open the device Settings app. Open it yourself and allow notifications for Ito.", comment: "Automatic downloads: the alert when the device Settings app could not be opened")
        }
    }
}

/// The management screen of automatic downloads: every rule with its status, the limits, and the notification
/// setting. It observes the database and never checks a source.
@MainActor
final class AutomaticDownloadsViewModel: ObservableObject {
    @Published private(set) var rows: [SubscriptionRuleRow] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var queueLimit: Int
    @Published private(set) var quotaGiB: Int
    @Published private(set) var attentionNotifications: Bool
    @Published private(set) var intervalHours: Int
    @Published private(set) var usage: AutomaticDownloadUsage?
    @Published private(set) var alert: AutomaticDownloadsAlert?
    /// The rule whose sheet is open.
    @Published private(set) var openRule: SubscriptionRuleModel?
    /// The review of one rule's events that is open.
    @Published var review: SubscriptionEventReviewModel?

    let service: any AutomaticDownloadServing
    private let settingsStore: AppSettingsStore
    private let notificationAuthorization: any NotificationAuthorizationRequesting
    private let applicationSettingsOpener: any ApplicationSettingsOpening
    private var mutationTail: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var ruleChange: AnyCancellable?

    init(
        service: any AutomaticDownloadServing,
        settingsStore: AppSettingsStore,
        notificationAuthorization: any NotificationAuthorizationRequesting,
        applicationSettingsOpener: any ApplicationSettingsOpening
    ) {
        self.service = service
        self.settingsStore = settingsStore
        self.notificationAuthorization = notificationAuthorization
        self.applicationSettingsOpener = applicationSettingsOpener
        queueLimit = settingsStore.automaticDownloadQueueLimit
        quotaGiB = settingsStore.automaticDownloadQuotaGiB
        attentionNotifications = settingsStore.subscriptionAttentionNotifications
        intervalHours = settingsStore.updateInterval.rawValue
    }

    /// Starts reading. Safe to call again; a second call does nothing.
    func attach() {
        guard cancellables.isEmpty else { return }
        service.rules()
            .sink { @MainActor [weak self] rules in
                guard let self else { return }
                self.rows = Self.sorted(rules)
                self.hasLoaded = true
            }
            .store(in: &cancellables)
        settingsStore.$automaticDownloadQueueLimit
            .sink { @MainActor [weak self] in self?.queueLimit = $0 }
            .store(in: &cancellables)
        settingsStore.$automaticDownloadQuotaGiB
            .sink { @MainActor [weak self] in self?.quotaGiB = $0 }
            .store(in: &cancellables)
        settingsStore.$subscriptionAttentionNotifications
            .sink { @MainActor [weak self] in self?.attentionNotifications = $0 }
            .store(in: &cancellables)
        settingsStore.$updateInterval
            .sink { @MainActor [weak self] in self?.intervalHours = $0.rawValue }
            .store(in: &cancellables)
        Task { [weak self] in
            guard let self else { return }
            self.usage = await self.service.usage()
        }
    }

    /// Rules that wait for the person first, then by title; a rule without a Library title goes last.
    static func sorted(_ rules: [SubscriptionRuleRow]) -> [SubscriptionRuleRow] {
        rules.sorted { left, right in
            if (left.attentionCount > 0) != (right.attentionCount > 0) { return left.attentionCount > 0 }
            switch (left.title, right.title) {
            case (let a?, let b?):
                let order = a.localizedStandardCompare(b)
                if order != .orderedSame { return order == .orderedAscending }
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): break
            }
            return left.id < right.id
        }
    }

    // MARK: - Rules

    /// Opens the rule of one row. The sheet reads and changes the rule as the series screen's does, except that the
    /// group choice is only shown: the chapter list it comes from belongs to the series screen.
    func open(_ row: SubscriptionRuleRow) {
        let model = SubscriptionRuleModel(service: service, identity: row.media, title: row.title)
        ruleChange = model.objectWillChange.sink { @MainActor [weak self] in self?.objectWillChange.send() }
        openRule = model
        model.open()
    }

    func closeRule() {
        openRule?.dismiss()
        openRule = nil
        ruleChange = nil
    }

    func openReview(_ row: SubscriptionRuleRow) {
        guard row.attentionCount > 0 else { return }
        review = SubscriptionEventReviewModel(subscriptionId: row.id, service: service)
    }

    // MARK: - Limits and notifications

    func setQueueLimit(_ value: Int) async {
        await store { try await $0.set(value, for: AppPreferenceCatalog.automaticDownloadQueueLimit) }
    }

    func setQuotaGiB(_ value: Int) async {
        await store { try await $0.set(value, for: AppPreferenceCatalog.automaticDownloadQuotaGiB) }
    }

    /// Turns the attention notifications on or off. Turning them on asks the system for permission; when it is
    /// refused the setting goes back off, with an alert that says why.
    func setAttentionNotifications(_ value: Bool) async {
        let preceding = mutationTail
        let mutation = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self else { return }
            do {
                try await self.settingsStore.set(value, for: AppPreferenceCatalog.subscriptionAttentionNotifications)
                self.alert = nil
            } catch {
                self.alert = .saveFailed
                return
            }
            guard value else { return }
            let granted = await self.notificationAuthorization.requestPermission()
            guard !granted else { return }
            do {
                try await self.settingsStore.set(false, for: AppPreferenceCatalog.subscriptionAttentionNotifications)
                self.alert = .notificationsDenied
            } catch {
                self.alert = .notificationRollbackFailed
            }
        }
        mutationTail = mutation
        await mutation.value
    }

    func openApplicationSettings() async {
        alert = await applicationSettingsOpener.openApplicationSettings() ? nil : .applicationSettingsOpenFailed
    }

    func dismissAlert() { alert = nil }

    private func store(_ write: @escaping @MainActor (AppSettingsStore) async throws -> Void) async {
        do {
            try await write(settingsStore)
            alert = nil
        } catch {
            alert = .saveFailed
        }
    }
}
