import SwiftUI

struct MergeResolverView: View {
    @Binding var conflicts: [MergeConflict]
    let onResolve: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("Merge Conflicts (\(conflicts.count))"),
                    footer: Text("We found active data in your local library that differs from the backup. Choose which data to keep for each item.")
                ) {
                    ForEach($conflicts) { $conflict in
                        MergeConflictRow(conflict: $conflict)
                    }
                }
            }
            .navigationTitle("Resolve Conflicting Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm Merge") {
                        onResolve()
                    }
                    .font(.headline)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Keep All Local") {
                        for i in conflicts.indices { conflicts[i].resolution = .keepLocal }
                    }
                    Spacer()
                    Button("Keep All Backup") {
                        for i in conflicts.indices { conflicts[i].resolution = .keepBackup }
                    }
                }
            }
        }
    }
}

struct MergeConflictRow: View {
    @Binding var conflict: MergeConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(conflict.item.title)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                // Local State Card
                ConflictDetailCard(
                    title: "Local State",
                    category: conflict.localCategoryName,
                    history: conflict.localHistoryCount,
                    isSelected: conflict.resolution == .keepLocal,
                    onTap: { conflict.resolution = .keepLocal }
                )

                // Backup State Card
                ConflictDetailCard(
                    title: "Backup State",
                    category: conflict.backupCategoryName,
                    history: conflict.backupHistoryCount,
                    isSelected: conflict.resolution == .keepBackup,
                    onTap: { conflict.resolution = .keepBackup }
                )
            }
        }
        .padding(.vertical, 8)
    }
}

struct ConflictDetailCard: View {
    let title: String
    let category: String?
    let history: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(isSelected ? .itoOnAccent : .secondary)
                    Spacer()
                    Group {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.itoOnAccent)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Label(category ?? "Uncategorized", systemImage: "folder")
                        .font(.caption2)
                        .foregroundColor(isSelected ? .itoOnAccent : .primary)

                    Label(history == 1 ? "1 history entry" : "\(history) history entries", systemImage: "text.book.closed")
                        .font(.caption2)
                        .foregroundColor(isSelected ? .itoOnAccent : .primary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor : Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
