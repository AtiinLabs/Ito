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
                let reason = Self.failureSummary(for: error)

                AppLogger.network.error("[Nuke] Image load failed scheme=\(scheme) host=\(host) ext=\(fileExtension) \(reason)")
            }
        }
    }

    /// `status=<pipeline error case>`, then `http=<status>` for rejected HTTP
    /// responses or `cause=<domain>_<code>` for other underlying errors.
    /// Uses only names and codes: an underlying error's description or
    /// userInfo can carry the request URL.
    nonisolated static func failureSummary(for error: ImagePipeline.Error) -> String {
        let status: String
        let underlying: (any Error)?
        switch error {
        case .dataMissingInCache: (status, underlying) = ("dataMissingInCache", nil)
        case .dataLoadingFailed(let cause): (status, underlying) = ("dataLoadingFailed", cause)
        case .dataIsEmpty: (status, underlying) = ("dataIsEmpty", nil)
        case .decoderNotRegistered: (status, underlying) = ("decoderNotRegistered", nil)
        case .decodingFailed(_, _, let cause): (status, underlying) = ("decodingFailed", cause)
        case .processingFailed(_, _, let cause): (status, underlying) = ("processingFailed", cause)
        case .imageRequestMissing: (status, underlying) = ("imageRequestMissing", nil)
        case .pipelineInvalidated: (status, underlying) = ("pipelineInvalidated", nil)
        }

        guard let underlying else { return "status=\(status)" }
        if case DataLoader.Error.statusCodeUnacceptable(let code) = underlying {
            return "status=\(status) http=\(code)"
        }
        let nsError = underlying as NSError
        return "status=\(status) cause=\(nsError.domain)_\(nsError.code)"
    }
}
