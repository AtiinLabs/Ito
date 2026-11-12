import SwiftUI

/// What a download would do, before it does it: the chapters it will queue, the ones it leaves out and why,
/// and other uploads in range that the user may add. Nothing is queued until Download is pressed.
struct DownloadPreviewSheet: View {
    let preview: DownloadPreview
    /// Free space where downloads are stored; nil when it is not known.
    let availableBytes: Int64?
    /// A batch is being queued; Download waits for it.
    let isEnqueuing: Bool
    /// Called with the keys of the other uploads the user ticked.
    let onConfirm: (Set<String>) -> Void
    let onCancel: () -> Void
    let onEditFallback: () -> Void

    @State private var ticked = Set<String>()

    private var queueCount: Int { preview.toQueue.count + ticked.count }

    var body: some View {
        NavigationView {
            List {
                if preview.listChanged {
                    Section {
                        Text(
                            "The chapter list changed; review again.",
                            comment: "Download preview: the series' chapter list changed while the preview was open, so it was made again."
                        )
                        .foregroundStyle(.orange)
                    }
                }
                if preview.missingPositionCount > 0 {
                    Section {
                        Text("Preferred edition unavailable", comment: "Some positions are not currently offered by the preferred group.")
                        Text(
                            "\(preview.missingPositionCount) selected positions need another edition or will be skipped.",
                            comment: "Aggregate unresolved download positions; count needs plural forms. Does not claim source deletion."
                        )
                        Button(action: onEditFallback) {
                            Text("Edit fallback order", comment: "Open the explicit ordered fallback policy editor, with optional Remember.")
                        }
                        Button {
                            onConfirm([])
                        } label: {
                            Text("Keep selection", comment: "Confirm only the permitted available chapters and leave missing positions unresolved.")
                        }
                        .disabled(preview.toQueue.isEmpty || isEnqueuing)
                    }
                }
                toDownloadSection
                warningsSection
                alreadyStoredSection
                skippedSection
                lockedSection
                damagedSection
                alternativesSection
                sizeSection
            }
            .navigationTitle(preview.preset.menuTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: onCancel) { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConfirm(ticked)
                    } label: {
                        if preview.selection.asksBeforeSwitching, preview.missingPositionCount > 0, !ticked.isEmpty {
                            Text("Use selected alternatives this time", comment: "Tick exact alternatives below for this batch only; does not remember fallback permission.")
                        } else {
                            Text(
                                "Download \(queueCount) Chapters",
                                comment: "Button on the download preview: queue the listed chapters. The placeholder is the number of chapters, which needs plural forms."
                            )
                        }
                    }
                    .disabled(queueCount == 0 || isEnqueuing)
                }
            }
            .onChange(of: preview.id) { _ in ticked = [] }
        }
    }

    private var toDownloadSection: some View {
        Section {
            if preview.toQueue.isEmpty {
                Text("Nothing to download.", comment: "Download preview: no chapter would be queued.")
                    .foregroundStyle(.secondary)
            }
            ForEach(preview.toQueue) { row in
                rowView(row)
            }
        } header: {
            Text(
                "To download · \(preview.toQueue.count)",
                comment: "Download preview section: the chapters that will be queued. The placeholder is their number."
            )
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        let messages = warningMessages
        if !messages.isEmpty {
            Section {
                ForEach(messages, id: \.self) { message in
                    Text(message).foregroundStyle(.orange)
                }
            }
        }
    }

    private var warningMessages: [String] {
        var messages: [String] = []
        if preview.issues.contains(.orderingAmbiguous) {
            messages.append(String(
                localized: "The reading order of this series isn't certain. Check the list before downloading.",
                comment: "Download preview warning: the order of the chapters could not be worked out confidently."
            ))
        }
        if preview.issues.contains(.anchorNotInSelection) {
            messages.append(String(
                localized: "The chapter you last read isn't in the selected scanlators, so this starts from the first unread chapter.",
                comment: "Download preview warning: the last-read chapter belongs to a scanlator that is not selected."
            ))
        }
        if preview.issues.contains(.alternativeUploads) {
            messages.append(String(
                localized: "Some chapters have uploads from more than one scanlator.",
                comment: "Download preview warning: several scanlators uploaded the same numbered chapter."
            ))
        }
        if preview.issues.contains(.multipleScanlators) {
            messages.append(String(
                localized: "This includes chapters from several scanlators.",
                comment: "Download preview warning: the chapters come from more than one scanlator."
            ))
        }
        if preview.issues.contains(.selectionExhausted) {
            messages.append(String(
                localized: "Fewer chapters match the selected scanlators than you asked for.",
                comment: "Download preview warning: the selected scanlators do not have enough chapters to fill the preset."
            ))
        }
        return messages
    }

    @ViewBuilder
    private var alreadyStoredSection: some View {
        if preview.savedCount > 0 || preview.queuedCount > 0 || preview.failedCount > 0 {
            Section {
                if preview.savedCount > 0 {
                    Text(
                        "\(preview.savedCount) already saved",
                        comment: "Download preview: how many chapters in range are already saved on this device. The placeholder is a number, which needs plural forms."
                    )
                }
                if preview.queuedCount > 0 {
                    Text(
                        "\(preview.queuedCount) already queued",
                        comment: "Download preview: how many chapters in range are already queued. The placeholder is a number, which needs plural forms."
                    )
                }
                if preview.failedCount > 0 {
                    Text(
                        "\(preview.failedCount) failed · retry from the chapter menu",
                        comment: "Download preview: how many chapters in range have a failed download, which is not queued again. The placeholder is a number, which needs plural forms. Retry is in each chapter's menu."
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var skippedSection: some View {
        if preview.skippedReadCount > 0 {
            Section {
                Text(
                    "\(preview.skippedReadCount) marked read, skipped",
                    comment: "Download preview: how many chapters in range are marked read and so are not downloaded. The placeholder is a number, which needs plural forms."
                )
            } footer: {
                Text("Chapters marked read are skipped, including other editions with the same chapter number.", comment: "Compatibility key-or-number read markers, not offline coverage.")
            }
        }
    }

    @ViewBuilder
    private var lockedSection: some View {
        if !preview.locked.isEmpty {
            Section {
                ForEach(preview.locked) { row in
                    rowView(row)
                }
            } header: {
                Text("Skipped, locked", comment: "Download preview section: chapters the source marks locked, which are not downloaded.")
            } footer: {
                Text(
                    "Locked chapters are skipped. Reading still stops at them.",
                    comment: "Download preview footer: locked chapters are not downloaded and the reader stops at them."
                )
            }
        }
    }

    @ViewBuilder
    private var damagedSection: some View {
        if !preview.damaged.isEmpty {
            Section {
                ForEach(preview.damaged) { row in
                    rowView(row)
                }
            } header: {
                Text("Damaged downloads", comment: "Download preview section: chapters whose saved copy failed verification.")
            } footer: {
                Text(
                    "Delete damaged downloads to download them again.",
                    comment: "Download preview footer: a damaged copy must be deleted before the chapter can be downloaded again."
                )
            }
        }
    }

    @ViewBuilder
    private var alternativesSection: some View {
        if !preview.alternatives.isEmpty {
            Section {
                ForEach(preview.alternatives) { row in
                    Button {
                        if ticked.contains(row.key) { ticked.remove(row.key) } else { ticked.insert(row.key) }
                    } label: {
                        HStack {
                            rowView(row)
                            Image(systemName: ticked.contains(row.key) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(ticked.contains(row.key) ? .accentColor : .secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(ticked.contains(row.key) ? .isSelected : [])
                }
            } header: {
                Text(
                    "Other uploads in this range",
                    comment: "Download preview section: uploads of chapters in the range that were not chosen for download, such as another group's upload of the same chapter or an extra upload from a selected group."
                )
            } footer: {
                Text(
                    "These aren't downloaded unless you tick them.",
                    comment: "Download preview footer: the uploads listed above are only downloaded when ticked."
                )
            }
        }
    }

    private var sizeSection: some View {
        Section {
            Text("Size is known after download.", comment: "Download preview: the size of the chapters cannot be known before they are downloaded.")
            if let availableBytes {
                let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
                Text(
                    "\(free) available",
                    comment: "Download preview: free space on this device. The placeholder is a size such as 4.2 GB."
                )
            }
        }
        .foregroundStyle(.secondary)
        .font(.footnote)
    }

    private func rowView(_ row: DownloadPreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).foregroundColor(.primary)
            if let scanlator = row.scanlator, !scanlator.isEmpty {
                Text(scanlator).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
