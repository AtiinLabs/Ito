import SwiftUI
import UIKit

/// The reader mode chooses zoom ownership independently of image loading and tap callbacks.
enum MangaImageInteraction {
    case passive
    case continuous(onTap: () -> Void)
    case pagedZoom(onTap: () -> Void)

    var tapAction: (() -> Void)? {
        switch self {
        case .passive: nil
        case .continuous(let action), .pagedZoom(let action): action
        }
    }
}

struct MangaImage: View {
    let urlStr: String
    let headers: [String: String]?
    let session: ReaderPageImageSession
    let pageID: String
    var foreground: Color = .white
    /// Draws the image exactly as wide as its row and as tall as that width makes it, top-aligned,
    /// with an explicit frame so every iOS version lays it out the same. The continuous reader
    /// sizes each row to the image rounded down to a whole pixel and clips the rest, so pages
    /// meet without a gap.
    var fillsRowWidth = false
    let interaction: MangaImageInteraction
    var imageLabel = String(localized: "Illustration", comment: "Accessibility label of a manga page image")

    @State private var imageState = ReaderPageImageState(phase: .idle, pixelSize: nil, revision: 0)
    @State private var lease: ReaderImageLease?
    @State private var observation: ReaderImageObservation?

    var body: some View {
        Group {
            if let image = readyImage {
                loadedImage(image)
            } else if let tapAction = interaction.tapAction {
                // Cover the whole row, including empty space below a short placeholder.
                // Try Again keeps its own button action.
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: tapAction)
            } else {
                placeholder
            }
        }
        .onAppear(perform: bindRequest)
        .onChange(of: urlStr) { _ in bindRequest() }
        .onChange(of: headers) { _ in bindRequest() }
        .onChange(of: pageID) { _ in bindRequest() }
        .onDisappear(perform: releaseRequest)
    }

    @ViewBuilder
    private var placeholder: some View {
        if case .failed = imageState.phase {
            failureView
        } else if URL(string: urlStr) == nil {
            invalidURLView
        } else {
            ProgressView()
                .tint(foreground)
                .frame(maxWidth: .infinity, minHeight: 400)
                .padding(40)
        }
    }

    private var readyImage: UIImage? {
        guard case .ready(let image) = imageState.phase else { return nil }
        return image
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(foreground.opacity(0.7))
                .font(.largeTitle)
            Text("Couldn't load this page")
                .font(.subheadline)
                .foregroundColor(foreground.opacity(0.8))
            Button("Try Again") { retry() }
                .buttonStyle(.bordered)
                .tint(foreground)
        }
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
        .padding(40)
    }

    private var invalidURLView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .foregroundColor(foreground.opacity(0.5))
                .font(.largeTitle)
            Text("This page has no valid image address")
                .font(.subheadline)
                .foregroundColor(foreground.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .padding(40)
    }

    @ViewBuilder
    private func loadedImage(_ image: UIImage) -> some View {
        switch interaction {
        case .passive:
            page(image).accessibilityLabel(imageLabel)
        case .continuous(let onTap):
            // The continuous viewport owns loaded-page taps and zoom; placeholders keep
            // their own fallback tap so the retry button can retain its button action.
            page(image)
                .accessibilityLabel(imageLabel)
                .accessibilityAction { onTap() }
        case .pagedZoom(let onTap):
            NativeReaderImageZoom(image: image, onTap: onTap, imageLabel: imageLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func page(_ image: UIImage) -> some View {
        if fillsRowWidth, image.size.width > 0, image.size.height > 0 {
            // Fixed sizes rather than fitting: how SwiftUI fits an image into an open-ended height
            // differs between iOS versions, and older ones left a band of background at the seams.
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.width * image.size.height / image.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        } else {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }

    private func bindRequest() {
        releaseRequest()
        guard let url = URL(string: urlStr) else {
            imageState = ReaderPageImageState(phase: .idle, pixelSize: nil, revision: 0)
            return
        }
        let request = NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: headers)
        let descriptor = ReaderPageImageDescriptor(pageID: pageID, request: request)
        let key = descriptor.key
        imageState = session.state(for: key)
        observation = session.observe(key) { state in
            imageState = state
        }
        lease = session.acquire(descriptor, consumer: .visible)
        imageState = session.state(for: key)
    }

    private func retry() {
        guard let url = URL(string: urlStr) else { return }
        let descriptor = ReaderPageImageDescriptor(
            pageID: pageID,
            request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: headers)
        )
        session.retry(descriptor)
        imageState = session.state(for: descriptor.key)
    }

    private func releaseRequest() {
        observation?.cancel()
        observation = nil
        if let lease { session.release(lease) }
        lease = nil
    }
}
