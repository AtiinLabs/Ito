import Nuke
import SwiftUI
import Foundation
import ito_runner

/// Why a reader page image is requested. The reader marks each request in memory; `PluginDataLoader`
/// reads the mark, and an unmarked request counts as a cover image.
///
/// The mark is a URLProtocol property. Foundation does not serialize such properties into the HTTP
/// message, and `unmarked(_:)` removes it from every request handed to a network loader, so the
/// transport never receives it.
///
/// Network task coalescing is disabled in the shared pipeline: equal URLs are not equal authority.
/// Cache hits remain local; source-owned requests use source/epoch-partitioned caches.
nonisolated enum ImageRequestPurpose: String, Sendable {
    case foregroundReading
    case prefetch

    private static let propertyKey = "ito.imageRequestPurpose"

    var networkPurpose: NetworkOperationContext.Purpose {
        switch self {
        case .foregroundReading: .foregroundReading
        case .prefetch: .prefetch
        }
    }

    /// `request` carrying this purpose mark. The mark lives on a mutable copy, the only form URLProtocol takes.
    func applied(to request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return request }
        URLProtocol.setProperty(rawValue, forKey: Self.propertyKey, in: mutable)
        return mutable as URLRequest
    }

    /// The purpose marked on `request`, or nil when it carries no mark.
    static func marked(on request: URLRequest) -> ImageRequestPurpose? {
        (URLProtocol.property(forKey: propertyKey, in: request) as? String).flatMap(Self.init(rawValue:))
    }

    /// `request` without any purpose mark. Foundation removes the URLProtocol property from a mutable copy,
    /// so every other field is kept as it is. An unmarked request is returned unchanged.
    static func unmarked(_ request: URLRequest) -> URLRequest {
        guard URLProtocol.property(forKey: propertyKey, in: request) != nil,
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.removeProperty(forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }
}

/// Host-only source binding. Neither plugin headers nor an HTTP URL can create this authority.
nonisolated enum ImageRequestSourceAuthority {
    private static let propertyKey = "ito.imageRequestSourceAuthority"

    private final class Box: NSObject, @unchecked Sendable {
        let authority: NetworkRequestAuthority
        /// The request fields the partition was computed from. A request edited after binding (a header
        /// added, a body changed) no longer matches them, and its partition is computed again.
        private let fields: RequestFields
        let cachePartition: String

        init(_ authority: NetworkRequestAuthority, request: URLRequest) {
            self.authority = authority
            fields = RequestFields(request)
            cachePartition = Self.partition(authority, fields)
        }

        func partition(for request: URLRequest) -> String {
            let current = RequestFields(request)
            return current == fields ? cachePartition : Self.partition(authority, current)
        }

        private static func partition(_ authority: NetworkRequestAuthority, _ fields: RequestFields) -> String {
            let headers: [[String]] = fields.headers
                .map { [$0.key.lowercased(), $0.value] }
                .sorted { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
            let values: [String] = [
                authority.context.sourceID, authority.context.authorizationScope.uuidString,
                fields.scheme, fields.method, String(fields.cachePolicy), fields.body?.base64EncodedString() ?? ""
            ]
            guard let encoded = try? JSONEncoder().encode(values + headers.flatMap { $0 }) else {
                preconditionFailure("Unable to encode source image cache partition")
            }
            return OfflineDigest.sha256Hex(encoded)
        }
    }

    private struct RequestFields: Equatable {
        let scheme: String
        let method: String
        let cachePolicy: UInt
        let body: Data?
        let headers: [String: String]

        init(_ request: URLRequest) {
            scheme = request.url?.scheme?.lowercased() ?? ""
            method = request.httpMethod ?? "GET"
            cachePolicy = request.cachePolicy.rawValue
            body = request.httpBody
            headers = request.allHTTPHeaderFields ?? [:]
        }
    }

    static func applied(_ authority: NetworkRequestAuthority, to request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            preconditionFailure("Unable to bind image request authority")
        }
        URLProtocol.setProperty(Box(authority, request: request), forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }

    static func marked(on request: URLRequest) -> NetworkRequestAuthority? {
        (URLProtocol.property(forKey: propertyKey, in: request) as? Box)?.authority
    }

    /// Reuses the partition computed when host authority was attached while the request is unchanged, so a
    /// cache lookup does not hash headers; a request edited since then gets the partition of its own fields.
    static func cachePartition(on request: URLRequest) -> String? {
        (URLProtocol.property(forKey: propertyKey, in: request) as? Box)?.partition(for: request)
    }

    static func unmarked(_ request: URLRequest) -> URLRequest {
        guard marked(on: request) != nil else { return request }
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            preconditionFailure("Unable to remove image request authority")
        }
        URLProtocol.removeProperty(forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }

    static func capture(pluginID: String, contexts: PluginNetworkContexts) -> NetworkRequestAuthority {
        NetworkRequestAuthority(
            contexts: contexts,
            context: contexts.context(pluginID: pluginID, PluginNetworkOperation(purpose: .coverImage, operationID: UUID()))
        )
    }

    /// Change purpose without borrowing a replacement source epoch, operation or policy revision.
    static func withPurpose(_ purpose: ImageRequestPurpose, authority: NetworkRequestAuthority) -> NetworkRequestAuthority {
        let context = authority.context
        return NetworkRequestAuthority(contexts: authority.contexts, context: NetworkOperationContext(
            purpose: purpose.networkPurpose,
            sourceID: context.sourceID,
            authorizationScope: context.authorizationScope,
            operationID: context.operationID,
            batchID: context.batchID,
            policyRevision: context.policyRevision,
            generation: context.generation,
            scopedGrant: context.scopedGrant
        ))
    }
}

/// Prepared by host composition, with the source identity supplied by the initiating screen.
/// A missing factory cannot silently turn plugin content into app-owned traffic.
nonisolated struct SourceCoverRequests: Sendable {
    let contexts: PluginNetworkContexts?

    func request(_ url: URL?, pluginID: String?) -> ImageRequest? {
        guard let url, let pluginID, let contexts else { return nil }
        let authority = ImageRequestSourceAuthority.capture(pluginID: pluginID, contexts: contexts)
        return ImageRequest(urlRequest: ImageRequestSourceAuthority.applied(authority, to: URLRequest(url: url)))
    }
}

private nonisolated struct SourceCoverRequestsKey: EnvironmentKey {
    static let defaultValue = SourceCoverRequests(contexts: nil)
}

private nonisolated struct ImageSourceIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sourceCoverRequests: SourceCoverRequests {
        get { self[SourceCoverRequestsKey.self] }
        set { self[SourceCoverRequestsKey.self] = newValue }
    }

    var imageSourceID: String? {
        get { self[ImageSourceIDKey.self] }
        set { self[ImageSourceIDKey.self] = newValue }
    }
}
