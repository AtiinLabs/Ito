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

    private var recoveryConfirmationTitle: String {
        viewModel.completionRecoveryRequest == .discard
            ? "Discard paused progress?"
            : "Send paused progress to the current account?"
    }

    private var recoveryConfirmationMessage: String {
        viewModel.completionRecoveryRequest == .discard
            ? "Paused read progress for this source is deleted without being sent. Your local reading history is unchanged."
            : "Paused read progress was recorded before this source's server or account settings changed. It is sent to the server and account configured now. Nothing is sent until you confirm."
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
            .confirmationDialog(
                recoveryConfirmationTitle,
                isPresented: Binding(
                    get: { viewModel.completionRecoveryRequest != nil },
                    set: { if !$0 { viewModel.cancelCompletionRecoveryRequest() } }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    viewModel.completionRecoveryRequest == .discard ? "Discard" : "Send to Current Account",
                    role: viewModel.completionRecoveryRequest == .discard ? .destructive : nil
                ) {
                    viewModel.confirmCompletionRecovery()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelCompletionRecoveryRequest()
                }
            } message: {
                Text(recoveryConfirmationMessage)
            }
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
            formLevelIssuesSection
            ForEach(viewModel.schema.settings, id: \.id) { setting in
                SettingRowView(setting: setting, viewModel: viewModel)
            }
            actionsSection
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
    private var formLevelIssuesSection: some View {
        if !viewModel.formLevelIssues.isEmpty {
            Section {
                ForEach(viewModel.formLevelIssues.indices, id: \.self) { index in
                    Label(viewModel.formLevelIssues[index], systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if !viewModel.actions.isEmpty {
            Section(
                header: Text("Diagnostics & Actions"),
                footer: Text("Tests use unsaved secret values when provided, otherwise saved values.")
            ) {
                ForEach(viewModel.actions, id: \.id) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            if viewModel.runningActionID == action.id {
                                ProgressView()
                            } else {
                                Button("Run") {
                                    viewModel.runAction(action.id)
                                }
                                .disabled(viewModel.runningActionID != nil)
                                .accessibilityLabel(action.title)
                            }
                        }
                        if let summary = action.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if viewModel.runningActionID != nil {
                    Button("Cancel Action", role: .cancel) {
                        viewModel.cancelRunningAction()
                    }
                }

                if let success = viewModel.actionSuccessMessage {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.footnote)
                }

                if let error = viewModel.actionErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if viewModel.isInspecting {
            Section {
                ProgressView("Validating plugin settings…")
            }
        }
        if let error = viewModel.inspectError {
            Section {
                Label("Validation could not be completed.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry Validation") {
                    viewModel.retryInspection()
                }
            }
        }
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
        completionSection
    }
    @ViewBuilder
    private var completionSection: some View {
        if let presentation = viewModel.completionPresentation {
            Section(header: Text("Read Progress Sync")) {
                if presentation.pendingCount > 0 {
                    Label(
                        "\(presentation.pendingCount) waiting to sync",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                if presentation.pausedCount > 0 {
                    Label(
                        "\(presentation.pausedCount) paused",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundColor(.orange)
                    ForEach(presentation.pauseReasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry with Current Account…") {
                        viewModel.requestCompletionRecovery(.reauthorize)
                    }
                    .disabled(viewModel.isRecoveringCompletion)
                    Button("Discard Paused Progress…", role: .destructive) {
                        viewModel.requestCompletionRecovery(.discard)
                    }
                    .disabled(viewModel.isRecoveringCompletion)
                }
                if viewModel.isRecoveringCompletion {
                    ProgressView("Updating queued progress…")
                }
                if let error = viewModel.completionRecoveryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
            }
        }
    }
}

private struct SettingRowView: View {
    let setting: Setting
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            if let issues = viewModel.issuesBySettingKey[setting.id], !issues.isEmpty {
                ForEach(issues.indices, id: \.self) { index in
                    Label(issues[index], systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
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
                get: { viewModel.storedValue(key: id).map { $0 == Setting.storedToggle(true) } ?? defaultValue },
                set: { viewModel.persistValue(key: id, value: Setting.storedToggle($0)) }
            ))
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
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

    var body: some View {
        let isSaved = viewModel.hasSecret(key: id)
        let draft = viewModel.secretDraft(key: id)
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
            SecureField(
                isSaved ? "Enter a new value to replace it" : name,
                text: Binding(
                    get: { viewModel.secretDraft(key: id) },
                    set: { viewModel.updateSecretDraft(key: id, value: $0) }
                )
            )
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
        _ = viewModel.persistSecret(key: id, value: viewModel.secretDraft(key: id))
    }
}
