import SwiftUI

struct LibrarySettingsView: View {
    @StateObject private var viewModel: LibrarySettingsViewModel

    init(viewModel: LibrarySettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.alwaysShowCategoryPicker },
                    set: { value in
                        Task { await viewModel.setAlwaysShowCategoryPicker(value) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose List on Save")
                        Text("Show the list picker when saving a new series.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Saving")
            } footer: {
                Text("When on, saving a new series opens the list picker instead of saving to Uncategorized. Only applies when you have at least one list of your own.")
            }

            Section {
                Toggle("Check in Background", isOn: Binding(
                    get: { viewModel.backgroundUpdatesEnabled },
                    set: { value in
                        Task { await viewModel.setBackgroundUpdatesEnabled(value) }
                    }
                ))

                if viewModel.showsUpdateOptions {
                    Toggle("Notify on New Chapters", isOn: Binding(
                        get: { viewModel.updateNotifications },
                        set: { value in
                            Task { await viewModel.setUpdateNotifications(value) }
                        }
                    ))

                    Picker("Update Frequency", selection: Binding(
                        get: { viewModel.updateInterval },
                        set: { value in
                            Task { await viewModel.setUpdateInterval(value) }
                        }
                    )) {
                        ForEach(viewModel.updateIntervals, id: \.self) { interval in
                            Text(interval.rawValue == 1 ? "1 Hour" : "\(interval.rawValue) Hours")
                                .tag(interval)
                        }
                    }
                }
            } header: {
                Text("Background Updates")
            } footer: {
                Text("When on, Ito checks your library for new chapters while the app is closed. iOS decides the exact timing.")
            }

            Section {
                Toggle("Skip Completed Series", isOn: Binding(
                    get: { viewModel.skipCompleted },
                    set: { value in
                        Task { await viewModel.setSkipCompleted(value) }
                    }
                ))
            } footer: {
                Text("Completed and cancelled series are not checked for new chapters, in the background or when you refresh the library.")
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: Binding(
            get: { viewModel.alert },
            set: { alert in
                if alert == nil {
                    viewModel.dismissAlert()
                }
            }
        )) { alert in
            makeAlert(alert)
        }
    }

    private func makeAlert(_ alert: SettingsAlert) -> Alert {
        if alert == .notificationsDisabled {
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .cancel(Text("Cancel")) {
                    viewModel.dismissAlert()
                },
                secondaryButton: .default(Text("Settings")) {
                    Task { await viewModel.openApplicationSettings() }
                }
            )
        }
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text("OK")) {
                viewModel.dismissAlert()
            }
        )
    }
}
