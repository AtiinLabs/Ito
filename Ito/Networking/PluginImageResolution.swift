import Foundation
import ito_runner

/// An `ito://<plugin_id>/<real_url>` image request, split into the plugin that owns it and the
/// URL the plugin is asked about.
nonisolated struct PluginImageLocator: Equatable, Sendable {
    let pluginID: String
    let realURLString: String

    static func parse(_ url: URL) throws -> Self {
        guard let host = url.host else {
            throw URLError(.badURL)
        }
        // url format: ito://<plugin_id>/<real_url>
        var realURLString = url.path
        if realURLString.hasPrefix("/") {
            realURLString.removeFirst()
        }
        if let query = url.query {
            realURLString += "?" + query
        }
        // Handle case where realURLString has scheme like https:/ instead of https://
        realURLString = realURLString.replacingOccurrences(of: "https:/", with: "https://")
        realURLString = realURLString.replacingOccurrences(of: "http:/", with: "http://")
        realURLString = realURLString.replacingOccurrences(of: "https:///", with: "https://")
        return Self(pluginID: host, realURLString: realURLString)
    }
}

/// How a plugin wants an image request satisfied.
nonisolated enum PluginImageResolution: Equatable, Sendable {
    /// Fetch `URL` natively with the plugin's headers, limited to the plugin's image origins.
    case fetch(URL, headers: [String: String]?, allowedOrigins: [String])
    /// The plugin returned the image bytes itself.
    case bytes(Data)
    /// The plugin doesn't handle this image: fetch the real URL directly.
    case direct(URL)

    static func resolve(_ locator: PluginImageLocator, runner: any PluginImageRunner) async throws -> Self {
        if let resolved = try await pluginCall({ try await runner.getImageRequest(locator.realURLString) }) {
            let origins = try await pluginCall { try await runner.getImageOrigins() } ?? []
            guard let target = URL(string: resolved.url) else { throw URLError(.badURL) }
            return .fetch(target, headers: resolved.headers, allowedOrigins: origins)
        }

        let handledData = try await pluginCall { try await runner.handleImage(locator.realURLString) }
        try Task.checkCancellation()
        if let data = handledData {
            return .bytes(data)
        }
        // A plugin that handles images but refused this one throws instead, and nothing is fetched.
        if let realURL = URL(string: locator.realURLString),
           let scheme = realURL.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return .direct(realURL)
        }
        throw URLError(.badURL)
    }
}
