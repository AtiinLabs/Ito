import SwiftUI

/// One chapter row of a review. Title, group and numbers are the source's own words and are shown as they are.
struct SubscriptionCandidateRowView: View {
    let row: SubscriptionCandidateRow
    var isSelected: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = row.title, !title.isEmpty {
                    Text(title).foregroundColor(.primary)
                }
                if let number = row.number {
                    Text("Chapter \(Self.format(number))", comment: "Review row: the chapter number. The placeholder is the number.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let volume = row.volume {
                    Text("Volume \(Self.format(volume))", comment: "Review row: the volume number. The placeholder is the number.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let scanlator = row.scanlator, !scanlator.isEmpty {
                    Text(scanlator).font(.caption).foregroundColor(.secondary)
                } else {
                    Text("No group listed", comment: "Scanlator choice: the chapters whose source names no scanlator.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            if row.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .accessibilityLabel(Text("Locked", comment: "Review row: the chapter is locked behind a paywall"))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private static func format(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// The events of one rule that wait for a person. Choosing and reviewing events can be approved; a catalog anomaly and a
/// review of the whole window can only be dismissed, because the store refuses to approve them.
struct SubscriptionEventReviewSheet: View {
    @ObservedObject var model: SubscriptionEventReviewModel
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            List {
                if let report = model.report {
                    Section { Text(report.text).foregroundColor(report.isRefusal ? .orange : .primary) }
                        .accessibilityIdentifier("reviewReport")
                }
                if model.failedToDecide {
                    Section {
                        Text("The decision could not be saved. Try again.", comment: "Review sheet: saving the person's decision failed")
                            .foregroundColor(.orange)
                    }
                }
                switch model.phase {
                case .loading:
                    Section { ProgressView() }
                case .failed:
                    Section {
                        Text("The chapters could not be loaded.", comment: "Review sheet: reading the waiting chapters failed")
                        Button { model.load() } label: { Text("Try Again", comment: "Review sheet: read the waiting chapters again") }
                    }
                case .loaded:
                    if !model.ruleIsEnabled {
                        Section {
                            Text("This rule is not turned on. Turn it on or resume it to download these chapters. You can still dismiss them.", comment: "Review sheet: the rule is paused or off, so chapters can be dismissed but not approved")
                                .foregroundColor(.secondary)
                        }
                        .accessibilityIdentifier("reviewRuleNotEnabledNote")
                    }
                    if model.events.isEmpty {
                        Section {
                            Text("Nothing is waiting for your decision.", comment: "Review sheet: no chapters wait for the person")
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(model.events) { event in eventSection(event) }
                    if model.hiddenCount > 0 {
                        Section {
                            Text("\(model.hiddenCount) more are waiting. They appear here once these are decided.", comment: "Review sheet: how many more events wait than are listed. The placeholder is a count.")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(Text("New Chapters", comment: "Title of the sheet where the person decides about new chapters of a rule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onClose) { Text("Done", comment: "Review sheet: close") }
                        .accessibilityIdentifier("closeReviewSheet")
                }
            }
            .task { await model.load().value }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func eventSection(_ event: SubscriptionEventReview) -> some View {
        Section {
            ForEach(event.candidates) { row in
                if model.offersApproval(event) {
                    Button { model.toggle(row.key, in: event) } label: {
                        SubscriptionCandidateRowView(row: row, isSelected: model.isSelected(row.key, in: event))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.isSelected(row.key, in: event) ? [.isSelected] : [])
                } else {
                    SubscriptionCandidateRowView(row: row)
                }
            }
            if model.offersApproval(event) {
                Button { model.approve(event) } label: {
                    Text("Download Selected", comment: "Review sheet: queue the chapters the person ticked")
                        .fontWeight(.semibold)
                }
                .disabled(!model.canApprove(event))
                .accessibilityIdentifier("approveEventButton")
            }
            Button(role: .destructive) { model.dismiss(event) } label: {
                Text("Dismiss", comment: "Review sheet: decide not to download these chapters")
            }
            .disabled(model.busyEventId != nil)
            .accessibilityIdentifier("dismissEventButton")
        } header: {
            Text(event.reviewReason?.localizedExplanation ?? event.kind.localizedSummary)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
