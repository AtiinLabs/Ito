import NukeUI
import SwiftUI

private enum DownloadsSelection: Hashable {
    case series(MediaIdentity)
    case job(OfflineChapterEdition)
}

struct DownloadsView: View {
    @StateObject var viewModel: DownloadsViewModel
    let viewFactory: AppViewFactory
    @State private var confirmingDelete = false

    var body: some View {
        List(selection: selection) {
            Section {
                if let available = viewModel.availableBytes {
                    Text("Downloads use \(DownloadsViewModel.bytes(viewModel.snapshot.byteCount)) · \(DownloadsViewModel.bytes(available)) available",
                         comment: "Downloads storage usage and volume free space")
                } else {
                    Text("Downloads use \(DownloadsViewModel.bytes(viewModel.snapshot.byteCount))",
                         comment: "Downloads storage usage when free space could not be read")
                }
            }
            Section {
                ForEach(viewModel.snapshot.inProgress) { series in
                    VStack(alignment: .leading) {
                        Text(series.title).font(.headline)
                        Text(viewModel.sourceLabel(for: series.id)).font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(series.rows) { row in
                        DownloadsChapterRow(row: row)
                            .tag(DownloadsSelection.job(row.id))
                            .contextMenu {
                                if row.canRetry {
                                    Button {
                                        Task {
                                            if row.state == .waiting(.restoredPendingReview) {
                                                await viewModel.resumePaused([row])
                                            } else {
                                                await viewModel.retry([row])
                                            }
                                        }
                                    } label: {
                                        if row.state == .waiting(.restoredPendingReview) {
                                            Text("Resume Paused", comment: "Approve a download paused after restoring a backup")
                                        } else {
                                            Text("Retry", comment: "Downloads queue: retry a failed or paused job")
                                        }
                                    }
                                }
                                Button(role: .destructive) {
                                    Task { await viewModel.cancel([row]) }
                                } label: {
                                    Text("Cancel Download", comment: "Downloads queue: cancel one job")
                                }
                            }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In Progress", comment: "Downloads manager queue section")
                    if !viewModel.allJobs.isEmpty { jobActions }
                }
                .textCase(nil)
            }
            Section {
                ForEach(viewModel.snapshot.downloaded) { series in
                    NavigationLink {
                        DownloadsSeriesView(viewModel: viewModel, identity: series.id, viewFactory: viewFactory)
                    } label: {
                        seriesLabel(series)
                    }
                    .tag(DownloadsSelection.series(series.id))
                }
                if viewModel.snapshot.downloaded.isEmpty {
                    Text("No downloaded chapters", comment: "Downloads manager empty inventory")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Downloaded", comment: "Downloads manager stored inventory section")
            }
        }
        .navigationTitle(Text("Downloads", comment: "Downloads manager title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItemGroup(placement: .bottomBar) {
                if !viewModel.selectedSeries.isEmpty {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text("Delete", comment: "Downloads manager: delete selected series")
                    }
                }
                if !viewModel.selectedJobRows.isEmpty {
                    Button {
                        Task { await viewModel.cancel(viewModel.selectedJobRows) }
                    } label: {
                        Text("Cancel Downloads", comment: "Downloads manager: cancel the selected queued or running downloads")
                    }
                    Button {
                        Task { await viewModel.retry(viewModel.selectedRetryableJobs) }
                    } label: {
                        Text("Retry", comment: "Downloads manager: retry selected jobs")
                    }
                    .disabled(viewModel.selectedRetryableJobs.isEmpty)
                    if !viewModel.selectedPausedJobs.isEmpty {
                        Button {
                            Task { await viewModel.resumePaused(viewModel.selectedPausedJobs) }
                        } label: {
                            Text("Resume Paused", comment: "Downloads manager: explicitly approve selected restored jobs")
                        }
                    }
                }
            }
        }
        .disabled(viewModel.isWorking)
        .onAppear { viewModel.attach() }
        .task { await viewModel.refreshAvailableSpace() }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            DownloadsViewModel.deleteConfirmation(viewModel.selectedDownloadRows),
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                let selected = viewModel.selectedSeries
                Task { await viewModel.deleteSeries(selected) }
            } label: {
                Text("Delete Downloads", comment: "Confirm permanent deletion of selected downloads")
            }
        } message: {
            Text(DownloadsViewModel.deleteSeriesMessage(seriesCount: viewModel.selectedSeries.count))
        }
        .downloadsMessage($viewModel.message)
    }

    private var selection: Binding<Set<DownloadsSelection>> {
        Binding(
            get: {
                Set(viewModel.selectedSeries.map(DownloadsSelection.series))
                    .union(viewModel.selectedJobs.map(DownloadsSelection.job))
            },
            set: { values in
                viewModel.selectedSeries = Set(values.compactMap { if case .series(let id) = $0 { id } else { nil } })
                viewModel.selectedJobs = Set(values.compactMap { if case .job(let id) = $0 { id } else { nil } })
            }
        )
    }

    private var jobActions: some View {
        HStack(spacing: 12) {
            if !viewModel.retryableJobs.isEmpty {
                Button {
                    Task { await viewModel.retry(viewModel.retryableJobs) }
                } label: {
                    Text("Retry Failed", comment: "Downloads manager: retry failures and source-related pauses")
                }
            }
            if !viewModel.pausedJobs.isEmpty {
                Button {
                    Task { await viewModel.resumePaused(viewModel.pausedJobs) }
                } label: {
                    Text("Resume Paused", comment: "Downloads manager: approve jobs paused after restoring a backup")
                }
            }
            Button(role: .destructive) {
                Task { await viewModel.cancel(viewModel.allJobs) }
            } label: {
                Text("Cancel All", comment: "Downloads manager: cancel all queued jobs, keeping saved copies")
            }
        }
        .buttonStyle(.borderless)
    }

    private func seriesLabel(_ series: DownloadsSeries) -> some View {
        HStack {
            DownloadsManagedCover(viewModel: viewModel, identity: series.id)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.title).font(.headline)
                Text(viewModel.sourceLabel(for: series.id)).font(.caption).foregroundColor(.secondary)
                Text("\(series.rows.count) chapters · \(DownloadsViewModel.bytes(series.byteCount))",
                     comment: "Downloads manager series: stored edition count and bytes, including damaged copies")
                    .font(.subheadline)
                if series.damagedCount > 0 {
                    Text("\(series.damagedCount) damaged", comment: "Downloads manager damaged edition count")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        }
    }
}

private struct DownloadsManagedCover: View {
    @ObservedObject var viewModel: DownloadsViewModel
    let identity: MediaIdentity
    @State private var owner = UUID()

    var body: some View {
        DownloadsCover(cover: viewModel.thumbnails[identity], item: viewModel.libraryItems[identity])
            .task(id: viewModel.thumbnailRevision) {
                await viewModel.loadThumbnail(for: identity, owner: owner)
            }
            .onDisappear { viewModel.releaseThumbnail(for: identity, owner: owner) }
    }
}

private struct DownloadsCover: View {
    let cover: LibraryDurableCover?
    let item: LibraryItem?

    var body: some View {
        Group {
            if let cover, let address = item?.coverUrl,
               cover.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(address) {
                Image(uiImage: cover.image).resizable().scaledToFill()
            } else if let cover = item?.coverUrl, let url = URL(string: cover) {
                LazyImage(url: url) { state in
                    if let image = state.image { image.resizable().scaledToFill() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 66).clipped().cornerRadius(4)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "book.closed").frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.itoCardBackground)
    }
}

extension View {
    func downloadsMessage(_ message: Binding<String?>) -> some View {
        alert(Text("Downloads", comment: "Downloads action error alert title"), isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button { message.wrappedValue = nil } label: { Text("OK", comment: "Dismiss downloads action error") }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

}
