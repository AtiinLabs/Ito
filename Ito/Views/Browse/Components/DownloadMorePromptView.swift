import SwiftUI

/// "Download More…": asks how many chapters to download. It sits in the download sheet, and Continue hands the
/// count to the batch model, which replaces the sheet with the chooser or the preview.
struct DownloadMorePromptView: View {
    let prompt: DownloadMorePrompt
    let onContinue: (Int) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(prompt: DownloadMorePrompt, onContinue: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onContinue = onContinue
        self.onCancel = onCancel
        _text = State(initialValue: String(prompt.initialCount))
    }

    private var count: DownloadPositionCount? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap(DownloadPositionCount.init)
    }

    /// The stepper follows the field. Stepping replaces the field's text with the new count.
    private var stepperValue: Binding<Int> {
        Binding(
            get: { Int(text.trimmingCharacters(in: .whitespaces)) ?? prompt.initialCount },
            set: { text = String($0) }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        TextField(
                            "Chapters",
                            text: $text,
                            prompt: Text("Chapters", comment: "Download More prompt: the field for the number of chapters.")
                        )
                        .keyboardType(.numberPad)
                        Stepper(
                            "",
                            value: stepperValue,
                            in: DownloadPositionCount.range
                        )
                        .labelsHidden()
                    }
                } header: {
                    Text("Chapters", comment: "Download More prompt: section header for the number of chapters.")
                } footer: {
                    if count == nil {
                        Text(
                            "Enter a number from \(DownloadPositionCount.range.lowerBound) to \(DownloadPositionCount.range.upperBound).",
                            comment: "Download More prompt: the count must be a whole number in the range. The placeholders are the bounds."
                        )
                        .foregroundStyle(.red)
                    } else {
                        Text(
                            "Downloads chapters after your last read one that aren't saved or queued yet. Saved and queued chapters don't count.",
                            comment: "Download More prompt footer: what counts toward the number."
                        )
                    }
                }
            }
            .navigationTitle(String(
                localized: "Download More",
                comment: "Download More prompt: title of the count prompt."
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: onCancel) { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let count { onContinue(count.value) }
                    } label: {
                        Text("Continue", comment: "Download More prompt: continue to the preview with the entered count.")
                    }
                    .disabled(count == nil)
                }
            }
        }
    }
}
