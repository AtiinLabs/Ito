import UIKit
import Foundation
import Nuke
import OSLog

/// Redacted error diagnostics for Nuke image loading pipeline.
/// In accordance with OMP privacy rules, NEVER logs:
/// - Full URL or query string
/// - Full Referer, Authorization, or cookie header values
/// - User data, media titles, or chapter names
public final class NukeDiagnosticDelegate: ImagePipelineDelegate, @unchecked Sendable {
    public static let shared = NukeDiagnosticDelegate()

    public init() {}

    public func imageTask(_ task: ImageTask, didReceiveEvent event: ImageTask.Event, pipeline: ImagePipeline) {
        if case .finished(let result) = event {
            switch result {
            case .success(let response):
                #if DEBUG
                let width = Int(response.image.size.width)
                let height = Int(response.image.size.height)
                let host = task.request.url?.host ?? "unknown-host"
                let scheme = task.request.url?.scheme ?? "unknown-scheme"
                AppLogger.network.debug("[Nuke] Image decoded successfully scheme=\(scheme) host=\(host) size=\(width)x\(height)")
                #endif
            case .failure(let error):
                let host = task.request.url?.host ?? "unknown-host"
                let scheme = task.request.url?.scheme ?? "unknown-scheme"
                let fileExtension = task.request.url?.pathExtension ?? "none"

                var statusInfo = "none"
                var underlyingInfo = "none"
                let nsError = error as NSError
                statusInfo = "\(nsError.domain)_\(nsError.code)"
                underlyingInfo = String(describing: type(of: error))

                AppLogger.network.error("[Nuke] Image load failed scheme=\(scheme) host=\(host) ext=\(fileExtension) status=\(statusInfo) cause=\(underlyingInfo)")
            }
        }
    }
}
