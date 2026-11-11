import Foundation
import ito_runner
import Testing
@testable import Ito

/// Builds the smallest WebAssembly modules a completion can run: they export what the runner
/// needs (`memory`, `alloc`, `dealloc` and the ABI constants) and whichever completion export, failure report and
/// host imports a test wants. Every module is built for the host's ABI, so the runner accepts it here.
enum TestWasm {
    struct Import {
        let module: String
        let name: String
        /// Index into `types`.
        let type: Int
    }

    struct Fixture {
        /// The body of `mark_completed(i32, i32, i32, i32, i32) -> i32`, or nil to leave it unexported.
        var completed: [UInt8]? = [0x41, 0x01]
        /// What `ito_last_error` returns: a pointer and length into `data`.
        var lastError: (pointer: Int, length: Int)?
        var imports: [Import] = []
        var data: [(offset: Int, bytes: [UInt8])] = []
        /// The `ito_abi_version` the module exports. It defaults to the host's ABI, so the module runs here.
        var abiVersion: Int = ItoRunner.supportedABIVersions.upperBound
    }

    static let i32: UInt8 = 0x7F
    static let i64: UInt8 = 0x7E

    /// The function types every fixture declares.
    static let types: [([UInt8], [UInt8])] = [
        ([i32], [i32]),                    // 0: alloc
        ([i32, i32], []),                  // 1: dealloc
        ([], [i64]),                       // 2: ito_last_error
        ([i32, i32], [i32]),               // 3: net fetch, webview load
        ([i32], []),                       // 4: net fetch_read
        ([], [i32]),                       // 5: ito_abi_version, ito_supported_kinds, ito_error_version
        ([i32, i32, i32, i32, i32], [i32]) // 6: mark_completed
    ]

    /// A source whose completion reports a failure of `category` through `ito_last_error`.
    static func failing(with category: String) throws -> Fixture {
        let raw = try rawValue(of: category)
        let report = try JSONDecoder().decode(
            PluginErrorPayload.self,
            from: Data(#"{"category":\#(raw),"message":"SENTINEL"}"#.utf8)
        )
        let payload = try ItoPostcardEncoder(abiVersion: ItoRunner.supportedABIVersions.upperBound).encode(report)
        return Fixture(completed: [0x41, 0x00], lastError: (1_024, payload.count), data: [(1_024, payload)])
    }

    /// A source that sends `request` through the host's network module `times` times in one export, then acknowledges.
    static func sending(_ request: NetRequest, times: Int = 1) throws -> Fixture {
        precondition(times > 0, "An export must make at least one call")
        let payload = try ItoPostcardEncoder(abiVersion: ItoRunner.supportedABIVersions.upperBound).encode(request)
        let call = callingHost(import: 0, pointer: 256, length: payload.count)
        return Fixture(
            completed: Array(Array(repeating: call, count: times).joined(separator: [0x1A])),
            imports: [Import(module: "ito:core/net", name: "fetch", type: 3)],
            data: [(256, payload)]
        )
    }

    /// A source that asks the host to load a page, then acknowledges.
    static func openingWebView(_ request: WebviewRequest) throws -> Fixture {
        let payload = try ItoPostcardEncoder(abiVersion: ItoRunner.supportedABIVersions.upperBound).encode(request)
        return Fixture(
            completed: callingHost(import: 0, pointer: 256, length: payload.count),
            imports: [Import(module: "ito:core/webview", name: "webview_load_url", type: 3)],
            data: [(256, payload)]
        )
    }

    /// `import(pointer, length)`, its result discarded, then `i32.const 1`.
    private static func callingHost(import index: Int, pointer: Int, length: Int) -> [UInt8] {
        var body: [UInt8] = [0x41]
        body += signed(Int64(pointer))
        body += [0x41]
        body += signed(Int64(length))
        body += [0x10]
        body += unsigned(UInt64(index))
        body += [0x1A, 0x41, 0x01]
        return body
    }

    private static func rawValue(of category: String) throws -> Int {
        let categories: [String: PluginErrorCategory] = [
            "needsSetup": .needsSetup, "unauthorized": .unauthorized, "network": .network, "server": .server,
            "notFound": .notFound, "other": .other, "unsupported": .unsupported, "needsLogin": .needsLogin
        ]
        return Int(try #require(categories[category]).rawValue)
    }

    static func build(_ fixture: Fixture) -> [UInt8] {
        var defined: [(name: String, type: Int, body: [UInt8])] = [
            ("alloc", 0, [0x41] + signed(4_096)),
            ("dealloc", 1, [])
        ]
        if let completed = fixture.completed { defined.append(("mark_completed", 6, completed)) }
        if let error = fixture.lastError {
            let packed = (Int64(error.pointer) << 32) | Int64(error.length)
            defined.append(("ito_last_error", 2, [0x42] + signed(packed)))
        }
        defined.append(("ito_abi_version", 5, [0x41] + signed(Int64(fixture.abiVersion))))
        defined.append(("ito_supported_kinds", 5, [0x41] + signed(7)))
        defined.append(("ito_error_version", 5, [0x41] + signed(2)))

        var exports: [[UInt8]] = [name("memory") + [0x02, 0x00]]
        for (index, function) in defined.enumerated() {
            exports.append(name(function.name) + [0x00] + unsigned(UInt64(fixture.imports.count + index)))
        }

        var module: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        module += section(1, vector(types.map { [0x60] + vector($0.0.map { [$0] }) + vector($0.1.map { [$0] }) }))
        if !fixture.imports.isEmpty {
            module += section(2, vector(fixture.imports.map {
                name($0.module) + name($0.name) + [0x00] + unsigned(UInt64($0.type))
            }))
        }
        module += section(3, vector(defined.map { unsigned(UInt64($0.type)) }))
        module += section(5, vector([[0x00, 0x01]]))
        module += section(7, vector(exports))
        module += section(10, vector(defined.map { function in
            let body = [0x00] + function.body + [0x0B]
            return unsigned(UInt64(body.count)) + body
        }))
        if !fixture.data.isEmpty {
            module += section(11, vector(fixture.data.map {
                [0x00, 0x41] + signed(Int64($0.offset)) + [0x0B] + unsigned(UInt64($0.bytes.count)) + $0.bytes
            }))
        }
        return module
    }

    private static func unsigned(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    private static func signed(_ value: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while true {
            var byte = UInt8(truncatingIfNeeded: remaining & 0x7F)
            remaining >>= 7
            let signBitSet: Bool = (byte & 0x40) != 0
            let finished: Bool = remaining == 0 ? !signBitSet : (remaining == -1 && signBitSet)
            if !finished { byte |= 0x80 }
            bytes.append(byte)
            if finished { return bytes }
        }
    }

    private static func name(_ text: String) -> [UInt8] {
        unsigned(UInt64(text.utf8.count)) + Array(text.utf8)
    }

    private static func vector(_ items: [[UInt8]]) -> [UInt8] {
        unsigned(UInt64(items.count)) + items.flatMap { $0 }
    }

    private static func section(_ id: UInt8, _ content: [UInt8]) -> [UInt8] {
        [id] + unsigned(UInt64(content.count)) + content
    }
}
