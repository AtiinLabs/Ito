import SwiftUI

/// One sheet for the rule of a series: turn it on, edit it, review it to turn it on again, pause it and turn it off.
/// Nothing here checks a source. The status, the limits and every refusal come from the database and the store.
struct SubscriptionRuleSheet: View {
    @ObservedObject var model: SubscriptionRuleModel
    @State private var confirmingTurnOff = false

    var body: some View {
        NavigationView {
            Form {
                if let row = model.row, row.state != .disabled {
                    Section {
                        SubscriptionRuleStatusView(row: row)
                        if model.canReviewAttention {
                            Button {
                                model.presentAttentionReview()
                            } label: {
                                Text("Review New Chapters", comment: "Rule sheet: opens the chapters that wait for the person's decision")
                            }
                            .accessibilityIdentifier("reviewAttentionButton")
                        }
                    }
                }
                if let message = model.message {
                    Section {
                        Text(message.text)
                            .foregroundColor(.orange)
                            .accessibilityIdentifier("ruleMessage")
                    }
                }
                modeSection
                limitSection
                groupsSection
                replacementSection
                limitsSection
                if model.canReviewUnread {
                    Section {
                        Button {
                            model.presentBackfill()
                        } label: {
                            Text("Review Unread Chapters to Download", comment: "Rule sheet: opens the list of unread chapters the person may download now")
                        }
                        .accessibilityIdentifier("reviewUnreadButton")
                    }
                }
                Section {
                    Text(SubscriptionRuleFooter.text(intervalHours: intervalHours))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                actionsSection
            }
            .disabled(model.isWorking)
            .navigationTitle(Text("Automatic Downloads", comment: "Title of the sheet that sets up automatic downloads for a series"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { model.dismiss() } label: {
                        Text("Close", comment: "Rule sheet: close without changing anything")
                    }
                    .accessibilityIdentifier("closeRuleSheet")
                }
            }
            .confirmationDialog(
                Text("Turn Off Automatic Downloads?", comment: "Rule sheet: title of the confirmation for turning a rule off"),
                isPresented: $confirmingTurnOff,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) { model.turnOff() } label: {
                    Text("Turn Off", comment: "Rule sheet: confirms turning the rule off")
                }
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: {
                Text("Downloaded chapters stay. Queued automatic downloads are removed.", comment: "Rule sheet: what turning a rule off does")
            }
            .sheet(item: $model.groupChoice) { choice in
                EditionChooserSheet(
                    presentation: choice.presentation,
                    isApplying: false,
                    onConfirm: { selection, _ in model.chooseGroups(selection) },
                    onCancel: { model.groupChoice = nil }
                )
            }
            .sheet(item: $model.backfill) { backfill in
                SubscriptionBackfillSheet(model: backfill, onClose: { model.backfill = nil })
            }
            .sheet(item: $model.review) { review in
                SubscriptionEventReviewSheet(model: review, onClose: { model.review = nil })
            }
        }
        .navigationViewStyle(.stack)
    }

    private var intervalHours: Int { model.service.checkIntervalHours }

    // MARK: - Sections

    private var modeSection: some View {
        Section {
            Picker(selection: $model.draft.mode) {
                Text("New releases", comment: "Rule mode: download chapters released after the rule was turned on").tag(SubscriptionMode.newReleases)
                Text("New releases and unread chapters", comment: "Rule mode: also download unread chapters the person approves").tag(SubscriptionMode.newAndFillUnread)
                Text("Keep next unread chapters", comment: "Rule mode: keep the chapters after the last one read downloaded").tag(SubscriptionMode.maintainNextUnread)
            } label: {
                Text("Download", comment: "Rule sheet: which chapters the rule downloads")
            }
            .pickerStyle(.inline)
            .disabled(!model.canEditDraft)
            .accessibilityIdentifier("ruleModePicker")
            if model.draft.mode == .maintainNextUnread {
                Stepper(value: $model.draft.windowSize, in: SubscriptionConfiguration.windowSizeRange) {
                    Text("Keep the next \(model.draft.windowSize) unread chapters", comment: "Rule sheet: how many unread chapters after the last one read stay downloaded. The placeholder is a count.")
                }
                .disabled(!model.canEditDraft)
            }
        } header: {
            Text("Download", comment: "Rule sheet: section for which chapters the rule downloads")
        } footer: {
            Text(modeExplanation)
        }
    }

    private var modeExplanation: String {
        switch model.draft.mode {
        case .newReleases:
            String(localized: "Downloads chapters the source adds after the first check. Chapters already listed are not downloaded.", comment: "Rule sheet: explains the new releases mode")
        case .newAndFillUnread:
            String(localized: "Also lets you review the unread chapters already listed and choose which to download. Nothing is downloaded until you approve it.", comment: "Rule sheet: explains the mode that also fills unread chapters")
        case .maintainNextUnread:
            String(localized: "Keeps the chapters after the last one you read downloaded as you read.", comment: "Rule sheet: explains the mode that keeps the next unread chapters downloaded")
        }
    }

    private var limitSection: some View {
        Section {
            Stepper(value: $model.draft.perRunPositionCap, in: SubscriptionConfiguration.perRunPositionCapRange) {
                Text("Up to \(model.draft.perRunPositionCap) new chapters per check", comment: "Rule sheet: the most new chapters one check queues. The placeholder is a count.")
            }
            .disabled(!model.canEditDraft)
        } footer: {
            Text("More new chapters are held back and queued at the next check.", comment: "Rule sheet: what happens to chapters beyond the per-check limit")
        }
    }

    private var groupsSection: some View {
        Section {
            Text(SubscriptionSelectionSummary.text(model.draft.selection))
            if model.canChooseGroups {
                Button {
                    model.presentGroupChoice()
                } label: {
                    Text("Choose Groups…", comment: "Rule sheet: opens the choice of scanlation groups")
                }
            }
        } header: {
            Text("Groups", comment: "Rule sheet: section for the scanlation groups the rule follows")
        } footer: {
            if model.canChooseGroups {
                Text("This choice belongs to the rule. It does not change the groups this series remembers for downloads.", comment: "Rule sheet: the rule's group choice is its own copy")
            } else if model.canEditDraft {
                Text("Open the series to change the groups.", comment: "Rule sheet: groups can only be changed from the series screen")
            }
        }
    }

    private var replacementSection: some View {
        Section {
            Toggle(isOn: $model.draft.replacesChangedChapters) {
                Text("Replace Changed Chapters", comment: "Rule sheet: replace a saved chapter when the source changes it")
            }
            .disabled(!model.canEditDraft)
        } footer: {
            Text("Replaces a saved chapter only when the source reports a changed revision of the same chapter.", comment: "Rule sheet: when a saved chapter is replaced")
        }
    }

    private var limitsSection: some View {
        let limits = model.service.limits
        return Section {
            Text("Up to \(limits.queueLimit) downloads in the queue", comment: "Rule sheet: the queue limit automatic downloads obey. The placeholder is a count.")
            Text("Up to \(Self.bytes(limits.quotaBytes)) of space for automatic downloads", comment: "Rule sheet: the space automatic downloads may fill. The placeholder is a size such as 5 GB.")
            if let usage = model.usage {
                if let stored = usage.storedBytes {
                    Text("\(Self.bytes(stored)) of downloads stored", comment: "Rule sheet: how much space stored downloads use. The placeholder is a size such as 1.2 GB.")
                }
                if let jobs = usage.queuedJobs {
                    Text("\(jobs) downloads in the queue now", comment: "Rule sheet: how many downloads are in the queue now. The placeholder is a count.")
                }
                if let available = usage.availableBytes {
                    Text("\(Self.bytes(available)) free on this device", comment: "Rule sheet: free space on the device. The placeholder is a size such as 20 GB.")
                }
            }
        } header: {
            Text("Limits", comment: "Rule sheet: section that shows the limits of automatic downloads")
        } footer: {
            Text("Change these limits under Downloads, Automatic Downloads.", comment: "Rule sheet: where the limits are changed")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                model.performPrimaryAction()
            } label: {
                Text(primaryTitle).fontWeight(.semibold)
            }
            .accessibilityIdentifier("ruleSaveButton")
            if model.canPause {
                Button {
                    model.pause()
                } label: {
                    Text("Pause", comment: "Rule sheet: pause the rule")
                }
                .accessibilityIdentifier("rulePauseButton")
            }
            if model.canTurnOff {
                Button(role: .destructive) {
                    confirmingTurnOff = true
                } label: {
                    Text("Turn Off…", comment: "Rule sheet: turn the rule off, after a confirmation")
                }
                .accessibilityIdentifier("ruleTurnOffButton")
            }
        }
    }

    private var primaryTitle: String {
        switch model.primaryAction {
        case .turnOn:
            String(localized: "Turn On", comment: "Rule sheet: create the rule and start checking")
        case .save:
            String(localized: "Save Changes", comment: "Rule sheet: save the edited rule")
        case .resume:
            String(localized: "Resume", comment: "Rule sheet: enable a rule the person paused")
        case .reviewAndTurnOn:
            String(localized: "Review and Turn On", comment: "Rule sheet: enable a rule that came back from a backup or a source change, as shown")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
