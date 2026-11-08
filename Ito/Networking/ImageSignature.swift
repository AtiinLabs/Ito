import Foundation

/// The image formats Ito reads, recognised from their leading bytes. Plugins and offline storage
/// hand over raw bytes, so their type would otherwise have to be guessed; an HTML error page
/// served as an image is not recognised.
nonisolated enum ImageSignature {
    struct Detection: Equatable, Sendable {
        let fileExtension: String
        let mediaType: String
    }

    static func detect(_ data: Data) -> Detection? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        if starts([0xFF, 0xD8, 0xFF]) { return Detection(fileExtension: "jpg", mediaType: "image/jpeg") }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Detection(fileExtension: "png", mediaType: "image/png")
        }
        if starts(Array("GIF8".utf8)) { return Detection(fileExtension: "gif", mediaType: "image/gif") }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) {
            return Detection(fileExtension: "webp", mediaType: "image/webp")
        }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = bytes.count >= 12 ? String(bytes: bytes[8..<12], encoding: .ascii) ?? "" : ""
            if brand.hasPrefix("avi") { return Detection(fileExtension: "avif", mediaType: "image/avif") }
            if ["heic", "heix", "mif1", "msf1"].contains(brand) {
                return Detection(fileExtension: "heic", mediaType: "image/heic")
            }
        }
        return nil
    }
}
