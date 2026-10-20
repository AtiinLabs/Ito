import Foundation
import Combine

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published private(set) var incognitoMode: Bool
    @Published private(set) var discordRPCEnabled: Bool
    @Published private(set) var discordRPCURL: String
    /// Text in the server address field; saved by `commitDiscordRPCURLDraft()`.
    @Published var discordRPCURLDraft: String
    @Published private(set) var discordState: DiscordRPCState
    @Published private(set) var alert: SettingsAlert?

    var showsDiscordDetails: Bool {
        discordRPCEnabled
    }

    private let settingsStore: AppSettingsStore
    private let discordRPCManager: DiscordRPCManager
    private var cancellables = Set<AnyCancellable>()
    private var committingDiscordRPCURL: String?

    init(
        settingsStore: AppSettingsStore,
        discordRPCManager: DiscordRPCManager
    ) {
        self.settingsStore = settingsStore
        self.discordRPCManager = discordRPCManager
        incognitoMode = settingsStore.incognitoMode
        discordRPCEnabled = settingsStore.discordRPCEnabled
        discordRPCURL = settingsStore.discordRPCURL
        discordRPCURLDraft = settingsStore.discordRPCURL
        discordState = discordRPCManager.state

        settingsStore.$discordRPCEnabled
            .sink { [weak self] enabled in
                self?.discordRPCEnabled = enabled
            }
            .store(in: &cancellables)
        settingsStore.$incognitoMode
            .sink { [weak self] enabled in
                self?.incognitoMode = enabled
            }
            .store(in: &cancellables)
        settingsStore.$discordRPCURL
            .sink { [weak self] url in
                guard let self else { return }
                // Follow outside changes (e.g. a restore) unless the user is mid-edit.
                if self.discordRPCURLDraft == self.discordRPCURL {
                    self.discordRPCURLDraft = url
                }
                self.discordRPCURL = url
            }
            .store(in: &cancellables)
        discordRPCManager.$state
            .sink { [weak self] state in
                self?.discordState = state
            }
            .store(in: &cancellables)
    }

    func setIncognitoMode(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.incognitoMode)
            incognitoMode = settingsStore.incognitoMode
            alert = nil
        } catch {
            incognitoMode = settingsStore.incognitoMode
            alert = .saveFailed
        }
    }

    func setDiscordRPCEnabled(_ value: Bool) async {
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCEnabled)
            discordRPCEnabled = settingsStore.discordRPCEnabled
            alert = nil
        } catch {
            discordRPCEnabled = settingsStore.discordRPCEnabled
            alert = .saveFailed
        }
    }

    /// Saves the address field. While editing, invalid text stays in the field so
    /// it can be corrected; when the page closes (`discardingInvalid`) it is reset.
    func commitDiscordRPCURLDraft(discardingInvalid: Bool = false) async {
        let value = discordRPCURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != settingsStore.discordRPCURL, value != committingDiscordRPCURL else {
            if value == discordRPCURL { discordRPCURLDraft = value }
            return
        }
        guard AppPreferenceCatalog.discordRPCURL.isValid(value) else {
            if discardingInvalid {
                discordRPCURLDraft = discordRPCURL
            } else {
                alert = .invalidDiscordURL
            }
            return
        }
        committingDiscordRPCURL = value
        defer { committingDiscordRPCURL = nil }
        do {
            try await settingsStore.set(value, for: AppPreferenceCatalog.discordRPCURL)
            discordRPCURL = settingsStore.discordRPCURL
            if discordRPCURLDraft.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                discordRPCURLDraft = value
            }
            alert = nil
        } catch {
            discordRPCURL = settingsStore.discordRPCURL
            alert = .saveFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}
