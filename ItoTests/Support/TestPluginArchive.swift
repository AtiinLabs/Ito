import Foundation
import ZIPFoundation

/// The bytes of a minimal `.ito` plugin bundle: a manifest, and `wasm` as its module if given.
func makeTestPluginArchiveData(
    id: String,
    version: String,
    minAppVersion: String = "1.0",
    wasm: Data? = nil,
    archived: Bool = false
) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TestPluginArchive-\(UUID().uuidString)")
    let archiveURL = directory.appendingPathComponent("fixture.ito")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = try Archive(url: archiveURL, accessMode: .create)
    let manifest = Data(
        """
        {
          "id": "\(id)",
          "name": "Fixture",
          "version": "\(version)",
          "min_app_version": "\(minAppVersion)",
          "type": "manga"\(archived ? ",\n  \"archived\": true" : "")
        }
        """.utf8
    )
    try archive.addEntry(
        with: "manifest.json",
        type: .file,
        uncompressedSize: Int64(manifest.count)
    ) { position, size in
        let start = Int(position)
        return manifest.subdata(in: start..<min(start + size, manifest.count))
    }
    if let wasm {
        try archive.addEntry(with: "main.wasm", type: .file, uncompressedSize: Int64(wasm.count)) { position, size in
            let start = Int(position)
            return wasm.subdata(in: start..<min(start + size, wasm.count))
        }
    }
    return try Data(contentsOf: archiveURL)
}

/// A minimal module the host reads without running it: `ito_abi_version` returns `abi`,
/// `ito_supported_kinds` returns `kindsMask` (one bit per `MediaKind.wireValue`), and `memory` is
/// exported. It has no imports and no start section.
func makeTestPluginWasm(abi: Int, kindsMask: Int = 1) -> Data {
    var module: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
    // Type section: one `() -> i32`.
    module += [0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F]
    // Function section: two functions of that type.
    module += [0x03, 0x03, 0x02, 0x00, 0x00]
    // Memory section: one memory, one page minimum.
    module += [0x05, 0x03, 0x01, 0x00, 0x01]
    // Export section.
    let exports = [
        wasmExport("ito_abi_version", kind: 0x00, index: 0),
        wasmExport("ito_supported_kinds", kind: 0x00, index: 1),
        wasmExport("memory", kind: 0x02, index: 0)
    ]
    module += [0x07] + wasmSized(wasmVector(exports))
    // Code section: each function returns its constant.
    let bodies = [abi, kindsMask].map { value -> [UInt8] in
        wasmSized([0x00, 0x41] + wasmSignedLEB(Int64(value)) + [0x0B])
    }
    module += [0x0A] + wasmSized(wasmVector(bodies))
    return Data(module)
}

private func wasmExport(_ name: String, kind: UInt8, index: UInt8) -> [UInt8] {
    wasmSized(Array(name.utf8)) + [kind, index]
}

private func wasmVector(_ items: [[UInt8]]) -> [UInt8] {
    wasmUnsignedLEB(items.count) + items.flatMap { $0 }
}

private func wasmSized(_ bytes: [UInt8]) -> [UInt8] {
    wasmUnsignedLEB(bytes.count) + bytes
}

private func wasmUnsignedLEB(_ value: Int) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while remaining != 0
    return bytes
}

private func wasmSignedLEB(_ value: Int64) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []
    while true {
        let byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        let signBitSet = byte & 0x40 != 0
        if (remaining == 0 && !signBitSet) || (remaining == -1 && signBitSet) {
            bytes.append(byte)
            return bytes
        }
        bytes.append(byte | 0x80)
    }
}
