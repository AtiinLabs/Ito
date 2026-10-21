import OSLog
import Foundation
import Combine
import SwiftUI

public enum DiscordRPCState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
public class DiscordRPCManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published public var state: DiscordRPCState = .disconnected

    public var isEnabled: Bool {
        settingsStore?.discordRPCEnabled ?? false
    }

    public var wsUrl: String {
        settingsStore?.discordRPCURL ?? AppPreferenceCatalog.discordRPCURL.defaultValue
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var isIntentionalDisconnect = false
    private let clientId = "1488209929721352252"
    private var cancellables = Set<AnyCancellable>()
    private var settingsStore: AppSettingsStore?
    private let libraryManager: LibraryManager

    // Current Activity Cache
    private var currentActivityDetails: String = "Ito"
    private var currentActivityState: String = "Browsing Library"
    private var currentActivityType: Int = 0
    private var currentActivityDetailsUrl: String?
    private var currentActivityStateUrl: String?
    private var currentActivityLargeImageText: String?
    private var currentActivityImageUrl: String?
    private var activityStartTimestamp: Int?

    // tracks if we are currently in lib so we can re-push stats when they load
    private var isLibraryActive: Bool = false
    private var lastLibraryCategoryName: String?

    public init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)

        // Observe library changes to update stats if browsing
        Publishers.CombineLatest(libraryManager.$items, libraryManager.$categories)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self = self, self.isLibraryActive else { return }
                self.refreshLibraryStatus()
            }
            .store(in: &cancellables)

        // Observe scene phase / lifecycle changes
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.disconnect(intentional: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isEnabled {
                    self.connect()
                }
            }
            .store(in: &cancellables)

    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        settingsStore.$discordRPCEnabled
            .combineLatest(settingsStore.$discordRPCURL)
            .dropFirst()
            .sink { [weak self] enabled, _ in
                guard let self else { return }
                self.objectWillChange.send()
                if enabled {
                    self.reconnect()
                } else {
                    self.disconnect(intentional: true)
                }
            }
            .store(in: &cancellables)

        if settingsStore.discordRPCEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.connect()
            }
        }
    }

    private func reconnect() {
        disconnect(intentional: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.connect()
        }
    }

    public func connect() {
        guard isEnabled else { return }
        guard webSocketTask == nil else { return }

        guard let url = URL(string: wsUrl) else {
            state = .error("Invalid URL")
            return
        }

        state = .connecting
        isIntentionalDisconnect = false

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    public func disconnect(intentional: Bool = false) {
        isIntentionalDisconnect = intentional
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    // MARK: - Delegate Callbacks

    public nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.state = .connected
            self.sendHandshake()

            // On reconnect, immediately restore previous context
            self.sendActivityPayload(
                details: self.currentActivityDetails,
                state: self.currentActivityState,
                activityType: self.currentActivityType,
                detailsUrl: self.currentActivityDetailsUrl,
                stateUrl: self.currentActivityStateUrl,
                largeImageText: self.currentActivityLargeImageText,
                imageUrl: self.currentActivityImageUrl,
                startTimestamp: self.activityStartTimestamp
            )
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            self.webSocketTask = nil
            if self.isIntentionalDisconnect {
                self.state = .disconnected
            } else {
                let msg = error?.localizedDescription ?? "Connection unexpectedly closed"
                self.state = .error(msg)

                // Silent reconnect strategy with backoff
                if self.isEnabled && !self.isIntentionalDisconnect {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        if self?.isEnabled == true {
                            self?.connect()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Networking

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                AppLogger.general.error("DiscordRPC WebSocket error: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    AppLogger.general.debug("DiscordRPC Received: \(text)")
                case .data:
                    break
                @unknown default:
                    break
                }
                Task { @MainActor in
                    self.receiveMessage()
                }
            }
        }
    }

    private func sendHandshake() {
        let payload: [String: Any] = [
            "type": "handshake",
            "client_id": clientId
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            if let jsonString = String(data: data, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error = error {
                        AppLogger.general.error("DiscordRPC failed to send handshake: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            AppLogger.general.error("DiscordRPC serialization error: \(error)")
        }
    }

    // MARK: - Core Broadcasting Hooks

    public func setActivity(
        details: String,
        state: String,
        activityType: Int = 0,
        detailsUrl: String? = nil,
        stateUrl: String? = nil,
        largeImageText: String? = nil,
        imageUrl: String? = nil,
        resetTimer: Bool = false
    ) {
        self.isLibraryActive = false
        self.lastLibraryCategoryName = nil
        self.currentActivityDetails = details
        self.currentActivityState = state
        self.currentActivityType = activityType
        self.currentActivityDetailsUrl = detailsUrl
        self.currentActivityStateUrl = stateUrl
        self.currentActivityLargeImageText = largeImageText
        self.currentActivityImageUrl = imageUrl

        if resetTimer {
            self.activityStartTimestamp = Int(Date().timeIntervalSince1970)
        } else if self.activityStartTimestamp == nil {
            self.activityStartTimestamp = Int(Date().timeIntervalSince1970)
        }

        if self.state == .connected {
            sendActivityPayload(
                details: details,
                state: state,
                activityType: activityType,
                detailsUrl: detailsUrl,
                stateUrl: stateUrl,
                largeImageText: largeImageText,
                imageUrl: imageUrl,
                startTimestamp: self.activityStartTimestamp
            )
        }
    }

    public func updateLibraryStatus(categoryName: String? = nil) {
        self.isLibraryActive = true
        self.lastLibraryCategoryName = categoryName
        refreshLibraryStatus()
    }

    internal func refreshLibraryStatus() {
        guard isLibraryActive else { return }

        let itemCount = libraryManager.items.count
        let categoryCount = libraryManager.categories.count

        let details = lastLibraryCategoryName.flatMap { "Browsing \($0)" } ?? "Browsing Collection"
        let state = "\(itemCount) Series in \(categoryCount) Categories"

        setActivity(
            details: details,
            state: state,
            activityType: 3, // "Watching Ito"
            largeImageText: "Managing Library",
            imageUrl: nil // Falls back to ito_logo
        )
    }

    public func clearActivity() {
        updateLibraryStatus()
    }

    private func sendActivityPayload(
        details: String,
        state: String,
        activityType: Int,
        detailsUrl: String?,
        stateUrl: String?,
        largeImageText: String?,
        imageUrl: String?,
        startTimestamp: Int?
    ) {
        var dataPayload: [String: Any] = [
            "details": details,
            "state": state,
            "type": activityType
        ]

        if let dUrl = Self.shareableURL(detailsUrl) { dataPayload["detailsUrl"] = dUrl }
        if let sUrl = Self.shareableURL(stateUrl) { dataPayload["stateUrl"] = sUrl }

        if let start = startTimestamp {
            dataPayload["timestamps"] = ["start": start]
        }

        var assets: [String: String] = [:]

        if let imgUrl = Self.shareableURL(imageUrl) {
            assets["large_image"] = imgUrl
            assets["large_text"] = largeImageText ?? details
        } else {
            assets["large_image"] = "ito_logo"
            assets["large_text"] = largeImageText ?? "Ito App"
        }

        dataPayload["assets"] = assets

        var buttons: [[String: String]] = []

        // Match user requested button layout
        buttons.append([
            "label": "View App On GitHub",
            "url": "https://github.com/itoapp/Ito"
        ])

        dataPayload["buttons"] = buttons

        let fullPayload: [String: Any] = [
            "type": "activity",
            "data": dataPayload
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: fullPayload)
            if let jsonString = String(data: data, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                self.webSocketTask?.send(message) { error in
                    if let err = error {
                        AppLogger.general.error("DiscordRPC failed to send activity: \(err.localizedDescription)")
                    }
                }
            }
        } catch {
            AppLogger.general.error("DiscordRPC activity serialization error: \(error)")
        }
    }

    /// `string` when it is safe to hand to Discord: an https URL with a host and nothing that
    /// could carry a credential (user info, a query or a fragment). Plugin covers can be signed
    /// or tokenized URLs, and `ito://` covers only resolve inside the app.
    nonisolated static func shareableURL(_ string: String?) -> String? {
        guard let string, let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return nil
        }
        return string
    }
}
