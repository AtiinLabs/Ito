import SwiftUI

struct AppearanceSettingsView: View {
    @StateObject private var viewModel: AppearanceSettingsViewModel

    init(viewModel: AppearanceSettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section(header: Text("Theme"), footer: Text("System follows your device's Light or Dark Mode setting.")) {
                Picker("Appearance", selection: Binding(
                    get: { viewModel.currentTheme },
                    set: { value in
                        Task { await viewModel.selectTheme(value) }
                    }
                )) {
                    ForEach(viewModel.availableThemes) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: Binding(
            get: { viewModel.alert },
            set: { alert in
                if alert == nil {
                    viewModel.dismissAlert()
                }
            }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
                }
            )
        }
    }
}
