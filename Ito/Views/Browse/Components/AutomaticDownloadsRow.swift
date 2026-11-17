import SwiftUI

/// The sentences about one rule: its status, when it was last checked, what went wrong, and the badges that hold beside
/// them. It is read by VoiceOver as one element whose label is those sentences.
struct SubscriptionRuleStatusView: View {
    let row: SubscriptionRuleRow
    var showsTitle = false

    private var status: SubscriptionRuleStatus { SubscriptionRuleStatus(row) }
    private var badges: [SubscriptionRuleBadge] { SubscriptionRuleBadge.badges(for: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle, let title = row.title {
                Text(title).font(.headline).lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.systemImage)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(status.title)
                    .font(showsTitle ? .subheadline : .body)
                    .foregroundColor(status.isChecking ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = status.detail(now: Date()) {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            if let note = status.failureNote {
                Text(note).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(badges, id: \.self) { badge in
                Text(badge.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(badge.isAttention ? .accentColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SubscriptionRuleBadge {
    /// Whether the badge asks the person to do something.
    var isAttention: Bool {
        if case .attention = self { return true }
        return false
    }
}

/// The row on the series screen that opens the rule of automatic downloads. It reads the rule from the database, so
/// showing it never checks a source.
struct AutomaticDownloadsRow: View {
    let entry: SubscriptionRuleModel.Entry
    let row: SubscriptionRuleRow?
    let action: () -> Void

    var body: some View {
        switch entry {
        case .hidden:
            EmptyView()
        case .addToLibrary:
            Label {
                Text("Add to Library to download new chapters automatically", comment: "Series screen: automatic downloads need the series to be in the Library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.down.circle").foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("automaticDownloadsUnavailableRow")
        case .rule(let status):
            Button(action: action) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Download New Chapters Automatically", comment: "Series screen: opens the rule that downloads new chapters of this series automatically")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if let row {
                            SubscriptionRuleStatusView(row: row)
                        } else if let status {
                            Text(status.title).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("automaticDownloadsRow")
        }
    }
}
