import SwiftUI

// MARK: - MigrationReportView

/// Presented as a sheet after a backup restore completes.
/// HIG: Sheets are appropriate for "task-specific workflows" that present
/// additional information after an action. The user initiated a restore,
/// so surfacing resolution options in a sheet is the correct pattern.
struct MigrationReportView: View {
    @StateObject private var viewModel: MigrationReportViewModel
    private let onDismiss: () -> Void
    private let showsDismissButton: Bool

    init(
        viewModel: @autoclosure @escaping () -> MigrationReportViewModel,
        onDismiss: @escaping () -> Void,
        showsDismissButton: Bool = true
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.onDismiss = onDismiss
        self.showsDismissButton = showsDismissButton
    }

    /// Read-only acknowledgment-route report: no remediation dependencies, no Done button.
    static func readOnly(report: MigrationReport) -> MigrationReportView {
        MigrationReportView(
            viewModel: MigrationReportViewModel(readOnlyReport: report),
            onDismiss: {},
            showsDismissButton: false
        )
    }

    var body: some View {
        NavigationView {
            List {
                summarySection
                unresolvedSourcesSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Import Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .font(.headline)
                        .opacity(showsDismissButton ? 1 : 0)
                        .disabled(!showsDismissButton)
                }
            }
            .sheet(item: Binding(
                get: { viewModel.remapPicker },
                set: { if $0 == nil { viewModel.cancelRemapPicker() } }
            )) { picker in
                RemapPickerView(
                    foreignId: picker.foreignID,
                    options: viewModel.filteredPickerOptions,
                    searchText: $viewModel.pickerSearchText,
                    onSelect: { _ = viewModel.selectRemapTarget(pluginID: $0) },
                    onCancel: viewModel.cancelRemapPicker
                )
            }
            // HIG: Alerts inform people about a problem or a change.
            .alert(item: Binding(
                get: { viewModel.alert },
                set: { if $0 == nil { viewModel.dismissAlert() } }
            )) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // HIG: Use SF Symbols that match the semantic meaning.
                // checkmark.circle for success tone, exclamationmark.triangle for warning.
                let activeCount = viewModel.activeUnresolvedCount
                let allResolved = viewModel.isAllResolved

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(viewModel.report.totalItemsImported) items imported")
                            .font(.headline)
                        if allResolved {
                            Text("All sources resolved")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(activeCount) source\(activeCount == 1 ? "" : "s") need\(activeCount == 1 ? "s" : "") attention")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: allResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(allResolved ? .green : .orange)
                        .symbolRenderingMode(.multicolor)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Unresolved Sources Section

    @ViewBuilder
    private var unresolvedSourcesSection: some View {
        // HIG: Section headers should be clear, single-word or short-phrase labels.
        Section {
            ForEach(viewModel.report.unresolvedPlugins) { plugin in
                unresolvedPluginRow(plugin)
            }
        } header: {
            Text("Sources")
        } footer: {
            if viewModel.isRemediationAllowed {
                Text("Install missing extensions, remap them to an existing Ito plugin, or skip to handle later from your library.")
            } else {
                Text("Series from these sources stay in your library. Install their sources from Browse to read them again.")
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func unresolvedPluginRow(_ plugin: MigrationReport.UnresolvedPlugin) -> some View {
        let isResolved = viewModel.disposition(for: plugin.foreignId) != nil

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // HIG: Use Label for icon+text pairs. Display the foreign source name
                // prominently so the user can identify what they're acting on.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.foreignId)
                            .font(.body)
                            .fontWeight(.medium)
                        Text("\(plugin.affectedItemCount) item\(plugin.affectedItemCount == 1 ? "" : "s") affected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isResolved ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .foregroundStyle(isResolved ? .green : .orange)
                }

                Spacer()

                if !isResolved {
                    confidenceBadge(plugin.confidence, isInstalled: plugin.isInstalled)
                }
            }

            if !isResolved && viewModel.isRemediationAllowed {
                // HIG: Button roles communicate intent. Normal for install/remap,
                // no destructive action here. Capsule shape provides clear tap targets.
                // HIG: "Maintain movement in progress indicators" — ProgressView shown inline.
                HStack(spacing: 8) {
                    if viewModel.canInstall(plugin) {
                        Button {
                            _ = viewModel.install(foreignID: plugin.foreignId)
                        } label: {
                            Group {
                                if viewModel.isInstalling(foreignID: plugin.foreignId) {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Label("Install", systemImage: "arrow.down.circle")
                                }
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                        .disabled(viewModel.isBusy)
                    }

                    Button {
                        _ = viewModel.presentRemapPicker(foreignID: plugin.foreignId)
                    } label: {
                        Label("Remap", systemImage: "arrow.triangle.swap")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.purple.opacity(0.12))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    .disabled(viewModel.isBusy)

                    Button {
                        withAnimation { _ = viewModel.skip(foreignID: plugin.foreignId) }
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.default, value: isResolved)
        .opacity(isResolved ? 0.5 : 1.0)
    }

    // MARK: - Confidence Badge

    /// HIG: Status indicators should use semantic colors (green/yellow/red)
    /// and include a text label for accessibility rather than relying solely on color.
    @ViewBuilder
    private func confidenceBadge(_ confidence: Int, isInstalled: Bool) -> some View {
        if isInstalled && confidence >= 45 {
            Text("Ready")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if confidence >= 20 {
            Text("Low Match")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.yellow.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else {
            Text("Not Found")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Remap Picker

/// HIG: This is a selection sheet (sub-modal). It uses .searchable for filtering,
/// a Cancel button in .cancellationAction placement, and clear row layout
/// distinguishing installed vs. available plugins.
/// Pure renderer: the ViewModel owns the option set and search filtering inputs.
struct RemapPickerView: View {
    let foreignId: String
    let options: [MigrationPluginOption]
    @Binding var searchText: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                // HIG: Section footer provides guidance without cluttering the header.
                Section {
                    ForEach(options, id: \.id) { option in
                        Button {
                            onSelect(option.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(option.id)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if option.isInstalled {
                                    Text("Installed")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.12))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                } header: {
                    Text("Available Plugins")
                } footer: {
                    Text("Choose the Ito plugin that matches \"\(foreignId)\". This mapping will be remembered for future imports.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search plugins…")
            .navigationTitle("Remap Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // HIG: Cancel in .cancellationAction placement
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
