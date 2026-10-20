import SwiftUI

struct BackupRestoreReportView: View {
    let report: BackupRestoreReport
    let onAcknowledge: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Restore") {
                    valueRow(
                        "Mode",
                        report.mode == .wipe ? "Wipe and replace" : "Merge"
                    )
                }

                totalsSection

                Section("Components") {
                    ForEach(report.outcomes, id: \.component) { outcome in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(outcome.component.displayName)
                                .font(.headline)
                            Text(outcome.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !report.preflightWarnings.isEmpty {
                    Section("Warnings") {
                        ForEach(
                            Array(report.preflightWarnings.enumerated()),
                            id: \.offset
                        ) { _, warning in
                            Text(warning.reason.userMessage)
                                .font(.caption)
                        }
                    }
                }

                if let migrationReport = report.migrationReport {
                    Section("Migration details") {
                        NavigationLink(
                            destination:
                            MigrationReportView.readOnly(report: migrationReport)
                        ) {
                            Text("Unmatched Sources")
                        }
                    }
                }
            }
            .navigationTitle("Restore Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Acknowledge", action: onAcknowledge)
                        .font(.headline)
                }
            }
        }
    }

    private var totalsSection: some View {
        let totals = report.totals
        return Section("Totals") {
            valueRow("Inserted", "\(totals.inserted)")
            valueRow("Replaced", "\(totals.replaced)")
            valueRow("Preserved local", "\(totals.preservedLocal)")
            valueRow("Skipped", "\(totals.skipped)")
            valueRow("Unresolved", "\(totals.unresolved)")
            valueRow("Dependency repaired", "\(totals.dependencyRepaired)")
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension BackupComponent {
    var displayName: String {
        switch self {
        case .libraryCore: "Library"
        case .readingHistory: "Reading history"
        case .sourceMappings: "Source mappings"
        case .scalarAppPreferences: "App preferences"
        case .readProgressAndResume: "Read progress and resume"
        case .trackerLinks: "Tracker links"
        case .updateBadges: "Update badges"
        case .repositories: "Repositories"
        case .userImporterAliases: "Importer aliases"
        case .pluginIdentityAndAliases: "Plugin identities"
        case .pluginSettings: "Plugin settings"
        case .legacyUnscopedMediaState: "Unresolved legacy media"
        case .legacyStateArchive: "Legacy archive"
        }
    }
}

private extension ComponentOutcome {
    var summary: String {
        [
            "inserted \(inserted)",
            "replaced \(replaced)",
            "preserved \(preservedLocal)",
            "skipped \(skipped)",
            "unresolved \(unresolved)",
            "repaired \(dependencyRepaired)"
        ].joined(separator: " · ")
    }
}
