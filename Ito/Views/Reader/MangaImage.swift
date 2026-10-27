import SwiftUI
import UIKit

struct MangaImage: View {
    let urlStr: String
    let headers: [String: String]?
    let session: ReaderPageImageSession
    let pageID: String
    var foreground: Color = .white
    var onImageTap: (() -> Void)?
    var imageLabel = "Illustration"

    @State private var imageState = ReaderPageImageState(phase: .idle, pixelSize: nil, revision: 0)
    @State private var lease: ReaderImageLease?
    @State private var observation: ReaderImageObservation?

    var body: some View {
        Group {
            if let image = readyImage {
                loadedImage(image)
            } else if case .failed = imageState.phase {
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
        .onAppear(perform: bindRequest)
        .onChange(of: urlStr) { _ in bindRequest() }
        .onChange(of: headers) { _ in bindRequest() }
        .onChange(of: pageID) { _ in bindRequest() }
        .onDisappear(perform: releaseRequest)
    }

    private var readyImage: Image? {
        guard case .ready(let image) = imageState.phase else { return nil }
        return Image(uiImage: image)
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
    private func loadedImage(_ image: Image) -> some View {
        if let onImageTap {
            ZoomablePage(onTap: onImageTap) {
                image.resizable().scaledToFit()
            }
            .accessibilityLabel(imageLabel)
        } else {
            image.resizable().scaledToFit().accessibilityLabel(imageLabel)
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
