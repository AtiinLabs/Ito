import Combine

@MainActor
final class AppearanceSettingsViewModel: ObservableObject {
    @Published private(set) var currentTheme: AppThemePreference
    @Published private(set) var alert: SettingsAlert?
    @Published private(set) var sourceHomeWideLayout: SourceHomeWideLayoutPreference

    let availableThemes = AppThemePreference.allCases

    private let settingsStore: AppSettingsStore
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        currentTheme = settingsStore.appTheme
        sourceHomeWideLayout = settingsStore.sourceHomeWideLayout

        settingsStore.$appTheme
            .sink { [weak self] theme in
                self?.currentTheme = theme
            }
            .store(in: &cancellables)

        settingsStore.$sourceHomeWideLayout
            .sink { [weak self] layout in
                self?.sourceHomeWideLayout = layout
            }
            .store(in: &cancellables)
    }

    func selectTheme(_ theme: AppThemePreference) async {
        do {
            try await settingsStore.set(theme, for: AppPreferenceCatalog.appTheme)
            currentTheme = settingsStore.appTheme
            alert = nil
        } catch {
            currentTheme = settingsStore.appTheme
            alert = .saveFailed
        }
    }

    func selectSourceHomeWideLayout(_ layout: SourceHomeWideLayoutPreference) async {
        do {
            try await settingsStore.set(layout, for: AppPreferenceCatalog.sourceHomeWideLayout)
            sourceHomeWideLayout = settingsStore.sourceHomeWideLayout
            alert = nil
        } catch {
            sourceHomeWideLayout = settingsStore.sourceHomeWideLayout
            alert = .saveFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}
