import SwiftUI

struct DownloadsSeriesView: View {
    @ObservedObject var viewModel: DownloadsViewModel
    let identity: MediaIdentity
    let viewFactory: AppViewFactory
    @State private var confirmingDelete = false

    private var series: DownloadsSeries? { viewModel.series(identity) }
    private var selectedRows: [DownloadListRow] {
        series?.rows.filter { viewModel.selectedChapters.contains($0.id) } ?? []
    }

    var body: some View {
        List(selection: $viewModel.selectedChapters) {
            if let series {
                Section {
                    Text("\(series.rows.count) chapters · \(DownloadsViewModel.bytes(series.byteCount))",
                         comment: "Downloaded series storage summary")
                    if let item = viewModel.libraryItems[identity] {
                        NavigationLink {
                            viewFactory.makeDeferredPluginView(item: item)
                        } label: {
                            Label {
                                Text("Open Series", comment: "Open saved Library details; reading is through details")
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                        }
                    }
                }
                Section {
                    ForEach(series.rows) { row in
                        DownloadsChapterRow(row: row).tag(row.id)
                    }
                }
            } else {
                Text("No downloaded chapters", comment: "Downloaded series is empty after deletion")
            }
        }
        .navigationTitle(series?.title ?? String(localized: "Downloads", comment: "Empty downloaded series title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .bottomBar) {
                if !selectedRows.isEmpty {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text("Delete", comment: "Delete selected downloaded chapters")
                    }
                }
            }
        }
        .disabled(viewModel.isWorking)
        .onAppear { viewModel.attach() }
        .task { await viewModel.refreshAvailableSpace() }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            DownloadsViewModel.deleteConfirmation(selectedRows),
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                let selected = Set(selectedRows.map(\.id))
                Task { await viewModel.deleteChapters(selected) }
            } label: {
                Text("Delete Downloads", comment: "Confirm deletion of selected offline chapters")
            }
        }
        .downloadsMessage($viewModel.message)
    }
}

struct DownloadsChapterRow: View {
    let row: DownloadListRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ReaderChapterTitle.text(title: row.title, number: row.number))
                if let scanlator = row.scanlator { Text(scanlator).font(.caption).foregroundColor(.secondary) }
                row.state.label.font(.caption).foregroundColor(.secondary)
                if let progress = row.state.progressValue { progress.font(.caption) }
            }
            Spacer()
            if row.jobID == nil { Text(DownloadsViewModel.bytes(row.byteCount)).font(.caption).foregroundColor(.secondary) }
            ChapterDownloadIndicator(state: row.state)
        }
        .accessibilityElement(children: .combine)
    }
}
