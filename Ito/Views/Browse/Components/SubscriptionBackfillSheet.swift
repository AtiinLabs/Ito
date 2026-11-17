import SwiftUI

/// The unread chapters a rule that fills unread chapters would download, listed exactly. Everything is ticked; the person
/// unticks what they do not want. The queue limit and the space for automatic downloads still apply, and the result says
/// what was queued and what waits.
struct SubscriptionBackfillSheet: View {
    @ObservedObject var model: SubscriptionBackfillModel
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            List {
                if let report = model.report {
                    Section { Text(report.text).foregroundColor(report.isRefusal ? .orange : .primary) }
                        .accessibilityIdentifier("backfillReport")
                }
                if model.failedToApprove {
                    Section {
                        Text("The approval could not be saved. Try again.", comment: "Backfill sheet: saving the approval failed")
                            .foregroundColor(.orange)
                    }
                }
                switch model.phase {
                case .loading:
                    Section { ProgressView() }
                case .failed:
                    Section {
                        Text("The unread chapters could not be listed.", comment: "Backfill sheet: reading the unread chapters failed")
                        Button { model.load() } label: { Text("Try Again", comment: "Backfill sheet: read the unread chapters again") }
                    }
                case .refused(let refusal):
                    Section { Text(refusal.localizedExplanation).foregroundColor(.secondary) }
                case .loaded:
                    loaded
                }
            }
            .navigationTitle(Text("Unread Chapters", comment: "Title of the sheet where the person approves unread chapters for download"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Text("Close", comment: "Backfill sheet: close") }
                        .accessibilityIdentifier("closeBackfillSheet")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.approve() } label: {
                        Text("Download", comment: "Backfill sheet: queue the ticked chapters").fontWeight(.semibold)
                    }
                    .disabled(!model.canApprove)
                    .accessibilityIdentifier("approveBackfillButton")
                }
            }
            .task { await model.load().value }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var loaded: some View {
        if let preview = model.preview {
            if preview.positions.isEmpty {
                Section {
                    Text("There are no unread chapters to download.", comment: "Backfill sheet: nothing is left to approve")
                        .foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(Array(preview.positions.enumerated()), id: \.offset) { index, keys in
                    Button { model.toggle(index) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(keys, id: \.self) { key in
                                if let row = preview.rows[key] {
                                    SubscriptionCandidateRowView(row: row, isSelected: keys.first == key ? model.isSelected(index) : nil)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.isSelected(index) ? [.isSelected] : [])
                }
            } footer: {
                if preview.truncatedCount > 0 {
                    Text("\(preview.truncatedCount) more chapters are not listed. Once these are approved, the list shows the next ones.", comment: "Backfill sheet: how many chapters beyond the list's limit remain. The placeholder is a count.")
                }
            }
        }
    }
}
