import SwiftUI

/// Every automatic download rule with its status, the limits they run under, and the notification setting. Opening it
/// reads the database only: it never checks a source.
struct AutomaticDownloadsView: View {
    @StateObject var viewModel: AutomaticDownloadsViewModel

    var body: some View {
        List {
            rulesSection
            limitsSection
            notificationsSection
        }
        .navigationTitle(Text("Automatic Downloads", comment: "Title of the screen that lists the automatic download rules"))
        .onAppear { viewModel.attach() }
        .sheet(item: ruleSheetBinding) { _ in
            if let model = viewModel.openRule { SubscriptionRuleSheet(model: model) }
        }
        .sheet(item: $viewModel.review) { review in
            SubscriptionEventReviewSheet(model: review, onClose: { viewModel.review = nil })
        }
        .alert(item: Binding(get: { viewModel.alert }, set: { if $0 == nil { viewModel.dismissAlert() } })) { alert in
            switch alert {
            case .notificationsDenied, .applicationSettingsOpenFailed:
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings", comment: "Automatic downloads alert: open the device Settings app")) {
                        Task { await viewModel.openApplicationSettings() }
                    },
                    secondaryButton: .cancel(Text("Not Now", comment: "Automatic downloads alert: leave notifications off"))
                )
            case .saveFailed, .notificationRollbackFailed:
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private var ruleSheetBinding: Binding<SubscriptionRulePresentation?> {
        Binding(
            get: { viewModel.openRule?.presentation },
            set: { if $0 == nil { viewModel.closeRule() } }
        )
    }

    // MARK: - Sections

    private var rulesSection: some View {
        Section {
            if viewModel.rows.isEmpty {
                Text(viewModel.hasLoaded
                     ? String(localized: "No automatic downloads yet. Open a series in your Library to set one up.", comment: "Automatic downloads screen: there are no rules")
                     : String(localized: "Loading…", comment: "Automatic downloads screen: the rules are being read"))
                    .foregroundColor(.secondary)
            }
            ForEach(viewModel.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Button { viewModel.open(row) } label: {
                        SubscriptionRuleStatusView(row: row, showsTitle: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("automaticRuleRow")
                    if row.attentionCount > 0 {
                        Button { viewModel.openReview(row) } label: {
                            Text("Review", comment: "Automatic downloads screen: open the chapters of a rule that wait for the person's decision")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("automaticRuleReviewButton")
                    }
                }
            }
        } footer: {
            Text(SubscriptionRuleFooter.text(intervalHours: viewModel.intervalHours))
        }
    }

    private var limitsSection: some View {
        Section {
            Stepper(
                value: Binding(get: { viewModel.queueLimit }, set: { value in Task { await viewModel.setQueueLimit(value) } }),
                in: AppPreferenceCatalogRanges.queueLimit,
                step: 10
            ) {
                Text("Up to \(viewModel.queueLimit) downloads in the queue", comment: "Automatic downloads screen: the queue limit. The placeholder is a count.")
            }
            Stepper(
                value: Binding(get: { viewModel.quotaGiB }, set: { value in Task { await viewModel.setQuotaGiB(value) } }),
                in: AppPreferenceCatalogRanges.quotaGiB
            ) {
                Text("Up to \(AutomaticDownloadsBytes.text(Int64(viewModel.quotaGiB) * AutomaticDownloadLimits.bytesPerGiB)) of space for automatic downloads", comment: "Automatic downloads screen: the space automatic downloads may fill. The placeholder is a size such as 5 GB.")
            }
            if let usage = viewModel.usage {
                if let stored = usage.storedBytes {
                    Text("\(AutomaticDownloadsBytes.text(stored)) of downloads stored", comment: "Automatic downloads screen: space used by stored downloads. The placeholder is a size.")
                        .foregroundColor(.secondary)
                }
                if let jobs = usage.queuedJobs {
                    Text("\(jobs) downloads in the queue now", comment: "Automatic downloads screen: how many downloads are queued now. The placeholder is a count.")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Limits", comment: "Automatic downloads screen: section for the limits")
        } footer: {
            Text("Automatic downloads wait when the queue is full or their space is used up, and start again when there is room.", comment: "Automatic downloads screen: what the limits do")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.attentionNotifications },
                set: { value in Task { await viewModel.setAttentionNotifications(value) } }
            )) {
                Text("Notify When Chapters Need a Decision", comment: "Automatic downloads screen: turns on notifications for new chapters that need the person's decision")
            }
            .accessibilityIdentifier("attentionNotificationsToggle")
        } footer: {
            Text("Ito posts a notification only while it is closed, and only when a background Library update finds something that needs your decision. Turn on background updates in Settings under Library. It never notifies about finished downloads.", comment: "Automatic downloads screen: when notifications are posted")
        }
    }
}

/// The ranges the steppers of the limits allow, which are the ranges the stored settings accept.
enum AppPreferenceCatalogRanges {
    static let queueLimit = 10...500
    static let quotaGiB = 1...200
}
