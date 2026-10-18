import Foundation
import ItoAVIF
import Nuke
import UIKit

/// Decoder selection for Ito's image pipelines. Nuke calls it on its decoding queue.
nonisolated enum ItoImageDecoders {
    /// `ImagePipeline.Configuration.makeImageDecoder`.
    ///
    /// ImageIO decodes AVIF from iOS 16. Earlier, AVIF data (for example
    /// Atsumaru chapter pages) goes to libavif; everything else, and every
    /// format on iOS 16+, uses Nuke's default registry.
    @Sendable
    static func make(for context: ImageDecodingContext) -> (any ImageDecoding)? {
        if #unavailable(iOS 16) {
            if AVIFDecoder.isAVIF(context.data) {
                return LibAVIFImageDecoder()
            }
        }
        return ImageDecoderRegistry.shared.decoder(for: context)
    }
}

/// Nuke decoder backed by libavif and dav1d.
nonisolated struct LibAVIFImageDecoder: ImageDecoding {
    func decode(_ data: Data) throws -> ImageContainer {
        let image = try AVIFDecoder.decode(data)
        return ImageContainer(image: UIImage(cgImage: image), type: .avif)
    }
}

nonisolated extension AssetType {
    static let avif: AssetType = "public.avif"
}
