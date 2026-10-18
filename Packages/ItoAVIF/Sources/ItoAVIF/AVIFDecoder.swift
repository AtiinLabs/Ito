import CoreGraphics
import Foundation
import libavif

/// Decodes still AVIF images with libavif and dav1d.
///
/// For systems whose ImageIO can't decode AVIF (before iOS 16). Decodes the
/// first frame to 8-bit RGBA in the image's ICC color space, or sRGB when it
/// has none.
public enum AVIFDecoder {
    /// Images larger than this many pixels are rejected before decoding.
    /// 40 MP is about 160 MB of RGBA and still covers long webtoon strips.
    public static let maximumPixelCount: UInt32 = 40_000_000

    /// Whether `data` starts with an ISO-BMFF `ftyp` box that declares an AVIF brand.
    public static func isAVIF(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else {
            return false
        }
        let boxSize = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let boxEnd = min(boxSize, bytes.count)
        // Major brand at 8..<12, minor version at 12..<16, compatible brands after.
        var offsets = [8]
        offsets.append(contentsOf: stride(from: 16, to: boxEnd - 3, by: 4))
        return offsets.contains { offset in
            let brand = bytes[offset..<offset + 4]
            return brand.elementsEqual("avif".utf8) || brand.elementsEqual("avis".utf8)
        }
    }

    /// Decodes the first frame of `data`.
    public static func decode(_ data: Data) throws -> CGImage {
        guard let decoder = avifDecoderCreate() else {
            throw AVIFDecodingError(stage: .create, code: nil)
        }
        defer { avifDecoderDestroy(decoder) }

        decoder.pointee.codecChoice = AVIF_CODEC_CHOICE_DAV1D
        decoder.pointee.maxThreads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 4))
        decoder.pointee.strictFlags = avifStrictFlags(AVIF_STRICT_DISABLED.rawValue)
        decoder.pointee.ignoreExif = AVIF_TRUE
        decoder.pointee.ignoreXMP = AVIF_TRUE
        decoder.pointee.imageSizeLimit = maximumPixelCount

        return try data.withUnsafeBytes { buffer -> CGImage in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                throw AVIFDecodingError(stage: .parse, code: nil)
            }
            try check(avifDecoderSetIOMemory(decoder, base, buffer.count), .parse)
            try check(avifDecoderParse(decoder), .parse)
            try check(avifDecoderNextImage(decoder), .decode)
            guard let image = decoder.pointee.image else {
                throw AVIFDecodingError(stage: .decode, code: nil)
            }
            return try makeCGImage(from: image)
        }
    }

    private static func makeCGImage(from image: UnsafeMutablePointer<avifImage>) throws -> CGImage {
        let hasAlpha = image.pointee.alphaPlane != nil

        var rgb = avifRGBImage()
        avifRGBImageSetDefaults(&rgb, image)
        rgb.format = AVIF_RGB_FORMAT_RGBA
        rgb.depth = 8
        rgb.alphaPremultiplied = hasAlpha ? AVIF_TRUE : AVIF_FALSE
        try check(avifRGBImageAllocatePixels(&rgb), .convert)
        defer { avifRGBImageFreePixels(&rgb) }
        try check(avifImageYUVToRGB(image, &rgb), .convert)

        let width = Int(rgb.width)
        let height = Int(rgb.height)
        let bytesPerRow = Int(rgb.rowBytes)
        let pixels = Data(bytes: rgb.pixels, count: bytesPerRow * height)

        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        guard
            let provider = CGDataProvider(data: pixels as CFData),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace(of: image),
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw AVIFDecodingError(stage: .convert, code: nil)
        }
        return cgImage
    }

    private static func colorSpace(of image: UnsafeMutablePointer<avifImage>) -> CGColorSpace {
        let icc = image.pointee.icc
        if icc.size > 0, let bytes = icc.data,
           let space = CGColorSpace(iccData: Data(bytes: bytes, count: icc.size) as CFData),
           space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func check(_ result: avifResult, _ stage: AVIFDecodingError.Stage) throws {
        guard result == AVIF_RESULT_OK else {
            throw AVIFDecodingError(stage: stage, code: Int(result.rawValue))
        }
    }
}

/// A libavif failure. `code` is the libavif `avifResult` value when there is one.
public struct AVIFDecodingError: Error, Equatable {
    public enum Stage: String, Sendable {
        case create, parse, decode, convert
    }

    public let stage: Stage
    public let code: Int?
}
