import SwiftUI

/// The explicit "Find All Uploads" part of the scanlator sheet. Nothing here runs unless the user taps the
/// button: it asks the source to list every exact upload, shows what came back grouped by reading position
/// with what the listing does and does not claim, and queues the uploads the user ticks. The listing is for
/// this sheet only; it is not the series' chapter list. Group names and titles are source content.
struct EditionUploadsSection: View {
    let state: EditionEnumerationState
    /// Whether this series' source can be asked at all.
    let canFind: Bool
    /// Another action holds the sheet: a choice is being applied or a batch is being queued.
    let isBusy: Bool
    let onFind: () -> Void
    let onCancel: () -> Void
    /// Called with the keys of the uploads the user ticked.
    let onDownload: (Set<String>) -> Void

    @State private var ticked = Set<String>()

    private var resultID: UUID? {
        guard case .loaded(let result) = state else { return nil }
        return result.id
    }

    var body: some View {
        Group {
            if canFind {
                controlSection
            }
            if canFind, case .loaded(let result) = state {
                disclosureSection(result)
                ForEach(result.groups) { group in
                    groupSection(group)
                }
                if !result.groups.isEmpty {
                    downloadSection(result)
                }
            }
        }
        .onChange(of: resultID) { _ in ticked = [] }
    }

    // MARK: - Control

    private var controlSection: some View {
        Section {
            switch state {
            case .idle, .failed, .loaded:
                findButton
            case .loading:
                HStack {
                    ProgressView()
                    Text("Finding uploads…", comment: "Scanlator sheet: the source is being asked to list every upload of the series.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .cancel, action: onCancel) { Text("Cancel") }
                        .buttonStyle(.borderless)
                }
            case .unsupported:
                Text(
                    "This source can't list more uploads. The chapter list is unchanged.",
                    comment: "Scanlator sheet: the source does not offer a list of every upload, so nothing was added to the chapter list."
                )
                .foregroundStyle(.secondary)
            }
            if case .failed(let message) = state {
                Text(message).foregroundStyle(.orange)
            }
        } header: {
            Text("More uploads", comment: "Scanlator sheet section: asks the source to list every upload of the series, including other groups' translations.")
        } footer: {
            if state == .idle {
                Text(
                    "Asks the source to list every upload it has for this series. Nothing is downloaded until you choose uploads.",
                    comment: "Footer under Find All Uploads: it only lists uploads; the user picks which to download afterwards."
                )
            }
        }
    }

    private var findButton: some View {
        Button(action: onFind) {
            Text("Find All Uploads", comment: "Button on the scanlator sheet: ask the source to list every upload of this series, including other groups' translations.")
        }
        .disabled(isBusy)
    }

    // MARK: - Result

    private func disclosureSection(_ result: EditionEnumerationResult) -> some View {
        Section {
            if result.additionalCount == 0 {
                Text(
                    "No other uploads found.",
                    comment: "Scanlator sheet: the source's full list holds nothing the chapter list does not already show."
                )
            } else {
                Text(
                    "\(result.additionalCount) more uploads found",
                    comment: "Scanlator sheet: how many uploads the source listed that the chapter list does not show. The placeholder is a number, which needs plural forms."
                )
            }
            ForEach(Array(result.disclosure.lines.enumerated()), id: \.offset) { _, line in
                disclosureText(line)
            }
        }
    }

    @ViewBuilder
    private func disclosureText(_ line: EditionEnumerationDisclosure.Line) -> some View {
        switch line {
        case .coversEveryUploadOffered:
            Text(
                "The source says this covers every upload it offers for your account and settings.",
                comment: "Scanlator sheet: the list of uploads is complete within what the source offers this account."
            )
            .foregroundStyle(.secondary)
        case .visibleUploadsOnly:
            Text(
                "Only the uploads the source shows by default are listed. Others may exist.",
                comment: "Scanlator sheet: the source lists only its visible uploads, so other uploads may exist even when this list is complete."
            )
            .foregroundStyle(.orange)
        case .scopeNotStated:
            Text(
                "The source didn't say which uploads this covers.",
                comment: "Scanlator sheet: the source did not say whether this list holds all uploads or only the visible ones."
            )
            .foregroundStyle(.orange)
        case .someUploadsMayBeMissing:
            Text(
                "Some uploads may not be listed.",
                comment: "Scanlator sheet: the source reports its list of uploads is incomplete."
            )
            .foregroundStyle(.orange)
        case .completenessNotStated:
            Text(
                "The source didn't say whether this list is complete.",
                comment: "Scanlator sheet: the source did not say whether its list of uploads holds everything."
            )
            .foregroundStyle(.orange)
        case .stoppedAtUploadLimit(let count):
            Text(
                "Stopped at the upload limit after \(count) uploads. More may exist.",
                comment: "Scanlator sheet: listing ended at Ito's cap on uploads. The placeholder is how many uploads were listed, a number, which needs plural forms."
            )
            .foregroundStyle(.orange)
        case .stoppedAtPageLimit(let limit):
            Text(
                "Stopped after \(limit) pages, the most listed at once. More may exist.",
                comment: "Scanlator sheet: listing ended at Ito's cap on pages of results. The placeholder is that cap, a number, which needs plural forms."
            )
            .foregroundStyle(.orange)
        case .stoppedAtSizeLimit:
            Text(
                "Stopped at the size limit for one listing. More may exist.",
                comment: "Scanlator sheet: listing ended because the results reached Ito's size cap."
            )
            .foregroundStyle(.orange)
        }
    }

    private func groupSection(_ group: EnumeratedEditionGroup) -> some View {
        Section {
            ForEach(group.rows) { row in
                uploadRow(row, groupTitle: group.title)
            }
        } header: {
            Text(verbatim: group.title)
        }
    }

    private func uploadRow(_ row: EnumeratedEditionRow, groupTitle: String) -> some View {
        let isTicked = ticked.contains(row.key)
        return Button {
            if isTicked { ticked.remove(row.key) } else { ticked.insert(row.key) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let scanlator = row.scanlator, !scanlator.isEmpty {
                        Text(verbatim: scanlator).foregroundColor(.primary)
                    } else {
                        Text("No group listed", comment: "Scanlator choice: the chapters whose source names no scanlator.")
                            .foregroundColor(.primary)
                    }
                    if row.title != groupTitle {
                        Text(verbatim: row.title).font(.caption).foregroundStyle(.secondary)
                    }
                    if let status = status(of: row) {
                        status.font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if row.isSelectable {
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isTicked ? .accentColor : .secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!row.isSelectable)
        .accessibilityAddTraits(isTicked ? .isSelected : [])
    }

    private func status(of row: EnumeratedEditionRow) -> Text? {
        if row.isLocked {
            return Text("Locked", comment: "Upload row: the source marks this upload locked for the account, so it cannot be downloaded.")
        }
        if row.isFailed {
            return Text("Download failed · retry in Downloads", comment: "Upload row: a download of this upload failed. The Downloads queue, named Downloads, has a Retry for it.")
        }
        switch row.stored {
        case .verified: return Text("Already saved", comment: "Upload row: this upload is already saved on this device.")
        case .queued: return Text("Already queued", comment: "Upload row: this upload is already queued for download.")
        case .damaged: return Text("Damaged download", comment: "Upload row: the saved copy of this upload failed verification and must be deleted before downloading again.")
        case .none: return nil
        }
    }

    /// The ticked uploads that can still be queued; a ticked row that has since been saved or queued is not one.
    private func tickedSelectable(_ result: EditionEnumerationResult) -> Set<String> {
        let selectable = result.groups.flatMap(\.rows).filter(\.isSelectable).map(\.key)
        return ticked.intersection(selectable)
    }

    private func downloadSection(_ result: EditionEnumerationResult) -> some View {
        let chosen = tickedSelectable(result)
        return Section {
            Button {
                onDownload(chosen)
            } label: {
                Text(
                    "Download \(chosen.count) Uploads",
                    comment: "Button on the scanlator sheet: queue the ticked uploads exactly as listed. The placeholder is the number ticked, which needs plural forms."
                )
            }
            .disabled(chosen.isEmpty || isBusy)
        } footer: {
            Text(
                "Locked uploads can't be downloaded. Your remembered scanlator choice doesn't change.",
                comment: "Footer under the Download uploads button: locked uploads stay blocked and downloading chosen uploads does not remember a group choice."
            )
        }
    }
}
