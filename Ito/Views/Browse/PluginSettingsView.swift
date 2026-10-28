import SwiftUI
import ito_runner

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
            if let failure = viewModel.presentation.formFailure {
                Section {
                    Label("Some settings of this source couldn't be shown.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(failure.localizedDescription).font(.caption).foregroundColor(.secondary)
                }
            }
            ForEach(viewModel.visibleSections) { section in
                if section.isPage {
                    NavigationLink(destination: PluginSettingsSectionView(section: section, viewModel: viewModel)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                            if let summary = section.summary {
                                Text(summary).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    Section(
                        header: section.title.isEmpty ? nil : Text(section.title),
                        footer: section.summary.map { Text($0) }
                    ) {
                        ForEach(section.controls, id: \.id) { control in
                            SettingsControlRow(control: control, viewModel: viewModel)
                        }
                    }
                }
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

private struct PluginSettingsSectionView: View {
    let section: PluginSettingsPresentation.Section
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        List {
            Section {
                ForEach(viewModel.visibleSections.first(where: { $0.id == section.id })?.controls ?? [], id: \.id) { control in
                    SettingsControlRow(control: control, viewModel: viewModel)
                }
            } footer: {
                if let summary = section.summary { Text(summary) }
            }
        }
        .navigationTitle(section.title)
    }
}

private struct SettingsControlRow: View {
    let control: Control
    @ObservedObject var viewModel: PluginSettingsViewModel

    private var storedValue: String? { viewModel.storedValue(key: control.id) }
    private var effective: (value: ControlValue?, state: StoredValueState) {
        control.effectiveValue(stored: storedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if case let .secret(secret) = control.kind {
                SecretSettingRow(control: control, placeholder: secret.placeholder, viewModel: viewModel)
            } else if let value = effective.value {
                ControlValueRow(
                    control: control,
                    value: value,
                    currentValue: { viewModel.effectiveValue(for: control) ?? value },
                    onChange: { updated in
                        if case .select(nil) = updated, case let .select(spec) = control.kind, spec.defaultValue == nil {
                            _ = viewModel.resetControl(control)
                        } else {
                            _ = viewModel.persistControlValue(updated, for: control)
                        }
                    },
                    optionCatalog: viewModel.optionCatalog(for: control)
                )
            } else {
                Text(control.title)
                Text("This control type is not supported.").font(.caption).foregroundColor(.secondary)
            }

            if storedValue != nil, control.kind.defaultValue != nil, effective.state != .invalid {
                Button("Reset") { _ = viewModel.resetControl(control) }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            if effective.state == .invalid {
                Label("Saved value isn't valid; the source uses the default.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                Button("Reset") { _ = viewModel.resetControl(control) }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            if let issues = viewModel.issuesBySettingKey[control.id], !issues.isEmpty {
                ForEach(issues.indices, id: \.self) { index in
                    Label(issues[index], systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.caption)
                }
            }
        }
    }
}

private struct SecretSettingRow: View {
    let control: Control
    let placeholder: String?
    @ObservedObject var viewModel: PluginSettingsViewModel

    var body: some View {
        let isSaved = viewModel.hasSecret(key: control.id)
        let draft = viewModel.secretDraft(key: control.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(control.title)
                Spacer()
                if isSaved {
                    Label("Saved", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SecureField(
                placeholder ?? (isSaved ? "Enter a new value to replace it" : control.title),
                text: Binding(
                    get: { viewModel.secretDraft(key: control.id) },
                    set: { viewModel.updateSecretDraft(key: control.id, value: $0) }
                )
            )
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .onSubmit(save)
            HStack {
                if isSaved { Button("Remove", role: .destructive) { viewModel.clearSecret(key: control.id) } }
                Spacer()
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.borderless)
            if let summary = control.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func save() {
        _ = viewModel.persistSecret(key: control.id, value: viewModel.secretDraft(key: control.id))
    }
}
