import CoreGraphics
import Foundation
import ItoAVIF
import Nuke
import Testing
import UIKit
@testable import Ito

@Suite("AVIF decoding")
struct AVIFImageDecodingTests {
    @Test func decodesOpaqueSinglePixelToWhite() throws {
        let image = try AVIFDecoder.decode(fixture("white_1x1"))

        #expect(image.width == 1)
        #expect(image.height == 1)
        #expect(image.alphaInfo == .noneSkipLast)
        let pixel = try #require(firstPixel(of: image))
        #expect(pixel.allSatisfy { $0 >= 250 })
    }

    @Test func decodesOpaquePhoto() throws {
        let image = try AVIFDecoder.decode(fixture("colors_sdr_srgb"))

        #expect(image.width == 200)
        #expect(image.height == 200)
        #expect(image.alphaInfo == .noneSkipLast)
    }

    @Test func decodesGridColorWithPerTileAlpha() throws {
        let image = try AVIFDecoder.decode(fixture("color_grid_alpha_nogrid"))

        #expect(image.width == 80)
        #expect(image.height == 80)
        #expect(image.alphaInfo == .premultipliedLast)
    }

    @Test func nukeDecoderReturnsAVIFContainer() throws {
        let container = try LibAVIFImageDecoder().decode(fixture("colors_sdr_srgb"))

        #expect(container.type == .avif)
        #expect(container.image.size == CGSize(width: 200, height: 200))
    }

    @Test func recognizesAVIFBrandsOnly() throws {
        for name in ["white_1x1", "colors_sdr_srgb", "color_grid_alpha_nogrid"] {
            #expect(AVIFDecoder.isAVIF(try fixture(name)))
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1])
        let webp = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)
        let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8))
        for data in [png, jpeg, webp, heic, Data(), Data([0, 0, 0])] {
            #expect(!AVIFDecoder.isAVIF(data))
        }
    }

    @Test func rejectsTruncatedAndGarbageInputWithoutCrashing() throws {
        let photo = try fixture("colors_sdr_srgb")
        let truncated = photo.prefix(photo.count / 2)
        let garbage = Data(photo.prefix(32)) + Data(repeating: 0xA5, count: 4096)

        for data in [Data(truncated), garbage, Data()] {
            #expect(throws: AVIFDecodingError.self) { try AVIFDecoder.decode(data) }
        }
    }

    @Test func pipelineUsesLibAVIFOnlyBeforeIOS16() throws {
        let request = ImageRequest(url: URL(string: "https://example.invalid/page.avif"))
        let avifDecoder = ItoImageDecoders.make(for: ImageDecodingContext(request: request, data: try fixture("white_1x1")))
        let pngDecoder = ItoImageDecoders.make(for: ImageDecodingContext(request: request, data: Data([0x89, 0x50, 0x4E, 0x47])))

        if #available(iOS 16, *) {
            #expect(!(avifDecoder is LibAVIFImageDecoder))
        } else {
            #expect(avifDecoder is LibAVIFImageDecoder)
        }
        #expect(!(pngDecoder is LibAVIFImageDecoder))
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureBundleToken.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "avif")
                ?? bundle.url(forResource: name, withExtension: "avif", subdirectory: "Fixtures/AVIF")
        )
        return try Data(contentsOf: url)
    }

    private func firstPixel(of image: CGImage) -> [UInt8]? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? Array(pixel.prefix(3)) : nil
    }
}

@Suite("Nuke failure diagnostics")
struct NukeFailureSummaryTests {
    @Test func reportsURLErrorCodeWithoutURL() {
        let secretURL = "https://cdn.example.invalid/pages/secret.webp?token=abc123"
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL])

        let summary = NukeDiagnosticDelegate.failureSummary(for: .dataLoadingFailed(error: error))

        #expect(summary == "status=dataLoadingFailed cause=NSURLErrorDomain_-1001")
        #expect(!summary.contains("token"))
        #expect(!summary.contains("cdn.example"))
    }

    @Test func reportsRejectedHTTPStatus() {
        let summary = NukeDiagnosticDelegate.failureSummary(
            for: .dataLoadingFailed(error: DataLoader.Error.statusCodeUnacceptable(403))
        )

        #expect(summary == "status=dataLoadingFailed http=403")
    }

    @Test func reportsCaseWithoutUnderlyingError() {
        #expect(NukeDiagnosticDelegate.failureSummary(for: .dataIsEmpty) == "status=dataIsEmpty")
    }
}

private final class FixtureBundleToken {}
