import Foundation
import ZIPFoundation

/// The bytes of a minimal `.ito` plugin bundle: a manifest and nothing else.
func makeTestPluginArchiveData(id: String, version: String, minAppVersion: String = "1.0") throws -> Data {
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
          "type": "manga"
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
    return try Data(contentsOf: archiveURL)
}
