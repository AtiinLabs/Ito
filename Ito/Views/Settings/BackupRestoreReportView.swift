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
                        report.mode == .wipe ? String(localized: "Wipe and replace") : String(localized: "Merge")
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

    private func valueRow(_ title: LocalizedStringKey, _ value: String) -> some View {
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
        case .libraryCore: String(localized: "Library", comment: "Backup component name for library entries")
        case .readingHistory: String(localized: "Reading history")
        case .sourceMappings: String(localized: "Source mappings")
        case .scalarAppPreferences: String(localized: "App preferences")
        case .readProgressAndResume: String(localized: "Read progress and resume")
        case .trackerLinks: String(localized: "Tracker links")
        case .updateBadges: String(localized: "Update badges")
        case .repositories: String(localized: "Repositories")
        case .userImporterAliases: String(localized: "Importer aliases")
        case .pluginIdentityAndAliases: String(localized: "Plugin identities")
        case .pluginSettings: String(localized: "Plugin settings")
        case .legacyUnscopedMediaState: String(localized: "Unresolved legacy media")
        case .savedLibraryThumbnails: String(localized: "Saved cover thumbnails")
        case .legacyStateArchive: String(localized: "Legacy archive")
        }
    }
}

private extension ComponentOutcome {
    var summary: String {
        [
            String(localized: "inserted \(inserted)"),
            String(localized: "replaced \(replaced)"),
            String(localized: "preserved \(preservedLocal)"),
            String(localized: "skipped \(skipped)"),
            String(localized: "unresolved \(unresolved)"),
            String(localized: "repaired \(dependencyRepaired)")
        ].joined(separator: " · ")
    }
}
