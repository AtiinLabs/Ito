import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import Vision

/// One word read on a page. `bounds` is in the page's unit square with the origin at the top
/// left, so it lines up with the page as it is laid out on screen.
nonisolated struct RecognizedWord: Equatable, Sendable {
    let text: String
    let bounds: CGRect
}

nonisolated protocol PageTextRecognizing: Sendable {
    /// The English words in `image`, roughly in reading order. Throws `CancellationError` when
    /// the calling task is cancelled.
    func words(in image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [RecognizedWord]
}

/// Reads English text on device with Vision. Vision recognizes English on every supported iOS
/// version (request revision 2 on iOS 15, 3 from iOS 16).
nonisolated struct VisionPageTextRecognizer: PageTextRecognizing {
    func words(in image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [RecognizedWord] {
        let cancellation = VisionRequestCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.recognize(image, orientation: orientation, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        cancellation: VisionRequestCancellation
    ) throws -> [RecognizedWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        guard cancellation.begin(request) else { throw CancellationError() }
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        } catch {
            if cancellation.isCancelled { throw CancellationError() }
            throw error
        }
        if cancellation.isCancelled { throw CancellationError() }
        return (request.results ?? []).flatMap(words(in:))
    }

    /// Splits one recognized line into words, each with its own box.
    private static func words(in observation: VNRecognizedTextObservation) -> [RecognizedWord] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        let text = candidate.string
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var words: [RecognizedWord] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            guard word.unicodeScalars.contains(where: CharacterSet.letters.contains),
                  let box = try? candidate.boundingBox(for: range)?.boundingBox else {
                return true
            }
            // Vision's unit square has its origin at the bottom left.
            words.append(RecognizedWord(
                text: word,
                bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            ))
            return true
        }
        return words
    }
}

/// Lets the caller's cancellation stop a Vision request running on another thread.
private nonisolated final class VisionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Registers `request`; false when cancellation already happened.
    func begin(_ request: VNRequest) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.request = request
            return true
        }
    }

    func cancel() {
        let request = lock.withLock { () -> VNRequest? in
            cancelled = true
            return self.request
        }
        request?.cancel()
    }
}
