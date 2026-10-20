import Combine
import Foundation

enum DebugLogAlert: Identifiable, Equatable {
    case fetchFailed
    case copyFailed

    var id: Self { self }

    var title: String {
        switch self {
        case .fetchFailed:
            return "Unable to Fetch Logs"
        case .copyFailed:
            return "Unable to Copy Logs"
        }
    }

    var message: String {
        switch self {
        case .fetchFailed:
            return "Debug logs could not be loaded. Please try again."
        case .copyFailed:
            return "Debug logs could not be copied. Please try again."
        }
    }
}

@MainActor
final class DebugLogViewModel: ObservableObject {
    @Published private(set) var logs: [DebugLogEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var alert: DebugLogAlert?
    @Published var searchText = ""

    private let logReader: any DebugLogReading
    private let clipboardWriter: any ClipboardWriting
    private let messagePresenter: any DebugLogMessagePresenting
    private var fetchGeneration = 0

    init(
        logReader: any DebugLogReading,
        clipboardWriter: any ClipboardWriting,
        messagePresenter: any DebugLogMessagePresenting
    ) {
        self.logReader = logReader
        self.clipboardWriter = clipboardWriter
        self.messagePresenter = messagePresenter
    }

    var filteredLogs: [DebugLogEntry] {
        guard !searchText.isEmpty else { return logs }
        return logs.filter {
            $0.message.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    func fetchLogs() async {
        fetchGeneration += 1
        let generation = fetchGeneration
        isLoading = true

        do {
            let entries = try await logReader.readEntries(
                lookback: 86_400,
                allowedSubsystems: ["moe.itoapp.ito", "moe.itoapp.runner"]
            )
            guard generation == fetchGeneration else { return }
            logs = Array(entries.reversed())
            isLoading = false
            alert = nil
        } catch {
            guard generation == fetchGeneration else { return }
            isLoading = false
            alert = .fetchFailed
        }
    }

    /// Copies the logs currently shown, so an active search narrows what is copied.
    func copyLogs() {
        let text = filteredLogs.map {
            "[\($0.date)] [\($0.category)] \($0.message)"
        }.joined(separator: "\n")

        do {
            try clipboardWriter.write(text)
            messagePresenter.present(.copied)
            alert = nil
        } catch {
            alert = .copyFailed
        }
    }

    func dismissAlert() {
        alert = nil
    }
}
