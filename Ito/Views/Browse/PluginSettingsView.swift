import SwiftUI
import ito_runner

extension Setting: @retroactive Identifiable {
    public var id: String {
        switch self {
        case .toggle(let id, _, _, _): return id
        case .text(let id, _, _, _): return id
        case .picker(let id, _, _, _, _): return id
        case .secret(let id, _, _): return id
        }
    }
}

struct PluginSettingsView: View {
    @StateObject private var viewModel: PluginSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: PluginSettingsViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            Form {
                settingsContent
            }
            .navigationTitle("\(viewModel.plugin.info.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .task {
                await viewModel.loadIfNeeded()
            }
            .onDisappear {
                viewModel.cancel()
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if viewModel.isPrepared {
            ForEach(viewModel.schema.settings, id: \.id) { setting in
                SettingRowView(setting: setting, viewModel: viewModel)
            }
            statusSections
        } else if let error = viewModel.loadError {
            Section {
                Label(
                    "Plugin settings could not be loaded. No changes were applied.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.load() }
                }
            }
        } else {
            ProgressView("Preparing plugin settings…")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if viewModel.isReloading {
            Section {
                ProgressView("Reloading plugin settings…")
            }
        }
        if let error = viewModel.reloadError {
            Section {
                Label("Plugin settings could not be reloaded.", systemImage: "arrow.clockwise.circle")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry Reload") {
                    Task { await viewModel.reload() }
                }
            }
        }
        if let error = viewModel.persistenceError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
    }
}

private struct SettingRowView: View {
    let setting: Setting
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        switch setting {
        case .toggle(let id, let name, let summary, let defaultValue):
            ToggleSettingRow(
                id: id,
                name: name,
                summary: summary,
                defaultValue: defaultValue,
                viewModel: viewModel
            )
        case .text(let id, let name, let summary, let defaultValue):
            TextSettingRow(
                id: id,
                name: name,
                summary: summary,
                defaultValue: defaultValue,
                viewModel: viewModel
            )
        case .picker(let id, let name, let summary, let options, let defaultValue):
            PickerSettingRow(
                id: id,
                name: name,
                summary: summary,
                options: options,
                defaultValue: defaultValue,
                viewModel: viewModel
            )
        case .secret(let id, let name, let summary):
            SecretSettingRow(id: id, name: name, summary: summary, viewModel: viewModel)
        }
    }
}

private struct ToggleSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: Bool
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(name, isOn: Binding(
                get: { viewModel.storedValue(key: id).map { $0 == "true" } ?? defaultValue },
                set: { viewModel.persistValue(key: id, value: $0 ? "true" : "false") }
            ))
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            viewModel.ensureDefault(key: id, value: defaultValue ? "true" : "false")
        }
    }
}

private struct TextSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let defaultValue: String
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            TextField(name, text: Binding(
                get: { viewModel.storedValue(key: id) ?? defaultValue },
                set: { viewModel.persistValue(key: id, value: $0) }
            ))
            .textFieldStyle(RoundedBorderTextFieldStyle())

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            viewModel.ensureDefault(key: id, value: defaultValue)
        }
    }
}

private struct PickerSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    let options: [String]
    let defaultValue: String
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(name, selection: Binding(
                get: { viewModel.storedValue(key: id) ?? defaultValue },
                set: { viewModel.persistValue(key: id, value: $0) }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            viewModel.ensureDefault(key: id, value: defaultValue)
        }
    }
}

/// A masked field for API keys and passwords. A saved value is never shown again; entering a new
/// one replaces it. The field stays on screen after saving (emptied), because iOS offers to save a
/// secure field's text as a website password when the field leaves the screen still holding it.
private struct SecretSettingRow: View {
    let id: String
    let name: String
    let summary: String?
    @ObservedObject var viewModel: PluginSettingsViewModel
    @State private var draft = ""

    var body: some View {
        let isSaved = viewModel.hasSecret(key: id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                Spacer()
                if isSaved {
                    Label("Saved", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SecureField(isSaved ? "Enter a new value to replace it" : name, text: $draft)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit(save)
            HStack {
                if isSaved {
                    Button("Remove", role: .destructive) { viewModel.clearSecret(key: id) }
                }
                Spacer()
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.borderless)
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func save() {
        guard viewModel.persistSecret(key: id, value: draft) else { return }
        draft = ""
    }
}
