import SwiftUI

struct DebugLogView: View {
    @StateObject private var viewModel: DebugLogViewModel

    init(viewModel: DebugLogViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.logs.isEmpty {
                ProgressView("Fetching Logs...")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if viewModel.filteredLogs.isEmpty {
                Text(viewModel.logs.isEmpty ? "No logs from the last 24 hours." : "No logs match your search.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(viewModel.filteredLogs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.date, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(log.category)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color(for: log.level).opacity(0.2))
                                .foregroundColor(color(for: log.level))
                                .cornerRadius(4)
                        }
                        Text(log.message)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .searchable(text: $viewModel.searchText)
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await viewModel.fetchLogs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: viewModel.copyLogs) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(viewModel.filteredLogs.isEmpty)
            }
        }
        .onAppear {
            Task { await viewModel.fetchLogs() }
        }
        .alert(item: Binding(
            get: { viewModel.alert },
            set: { alert in
                if alert == nil {
                    viewModel.dismissAlert()
                }
            }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
                }
            )
        }
    }

    private func color(for level: DebugLogLevel) -> Color {
        switch level {
        case .fault, .error: return .red
        case .info, .notice: return .blue
        case .debug: return .gray
        case .other: return .primary
        }
    }
}
