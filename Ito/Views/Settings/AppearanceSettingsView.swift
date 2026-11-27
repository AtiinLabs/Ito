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
                        Text(theme.localizedTitle).tag(theme)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            Section(
                header: Text("Layout"),
                footer: Text("Applies to an unfolded iPhone Duo in landscape, iPad and Mac. Side by Side shows a source's featured title beside its shelves; Stacked keeps the phone layout.")
            ) {
                Picker("Source Home on Wide Screens", selection: Binding(
                    get: { viewModel.sourceHomeWideLayout },
                    set: { value in
                        Task { await viewModel.selectSourceHomeWideLayout(value) }
                    }
                )) {
                    ForEach(SourceHomeWideLayoutPreference.allCases, id: \.self) { layout in
                        Text(layout.localizedTitle).tag(layout)
                    }
                }
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
