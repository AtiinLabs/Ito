import SwiftUI
import NukeUI

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel

    init(viewModel: HistoryViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .empty:
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(.tertiary)

                    Text("No History")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("Items you read or watch\nwill appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 60)
            case .content:
                List {
                    ForEach(viewModel.history) { entry in
                        HistoryItemRow(entry: entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteEntry(id: entry.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(viewModel.deletingEntryIDs.contains(entry.id))
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.isClearVisible {
                    Button(role: .destructive) {
                        viewModel.requestClear()
                    } label: {
                        Text("Clear")
                    }
                    .disabled(viewModel.isClearing)
                }
            }
        }
        .confirmationDialog(
            "Clear All History?",
            isPresented: clearConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await viewModel.confirmClear() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelClear()
            }
        } message: {
            Text("This removes all reading and watch history.")
        }
        .alert(
            viewModel.failure?.alertTitle ?? "History Change Failed",
            isPresented: failureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
    }

    private var clearConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isClearConfirmationPresented },
            set: { if !$0 { viewModel.cancelClear() } }
        )
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure != nil },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }
}

struct HistoryItemRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            if let coverUrl = entry.record.coverUrl, let url = URL(string: coverUrl) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else if state.error != nil {
                        Color.itoCardBackground
                            .overlay(Image(systemName: "photo.slash").foregroundStyle(.tertiary))
                    } else {
                        Color.itoCardBackground
                    }
                }
                .frame(width: 50, height: 75)
                .cornerRadius(6)
                .clipped()
                .accessibilityHidden(true)
            } else {
                Color.itoCardBackground
                    .frame(width: 50, height: 75)
                    .cornerRadius(6)
                    .overlay(Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.record.title)
                    .font(.headline)
                    .lineLimit(2)

                if let chapterTitle = entry.record.chapterTitle {
                    Text(chapterTitle)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Text(timeAgo(from: entry.record.readAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(entry.record.pluginId.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
