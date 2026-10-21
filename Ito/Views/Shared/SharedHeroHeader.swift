import SwiftUI
import Nuke
import NukeUI
import Combine

public struct SharedHeroHeader: View {
    public let title: String
    public let backdropURL: String?
    public let coverURL: String?
    public let authorOrStudio: String?
    public let statusLabel: String?
    /// Shown as given next to the status badge: the plugin's name, or a Discover label.
    public let sourceLabel: String
    public var onImageLoaded: ((UIImage) -> Void)?

    public init(title: String, backdropURL: String? = nil, coverURL: String?, authorOrStudio: String?, statusLabel: String?, sourceLabel: String, onImageLoaded: ((UIImage) -> Void)? = nil) {
        self.title = title
        self.backdropURL = backdropURL
        self.coverURL = coverURL
        self.authorOrStudio = authorOrStudio
        self.statusLabel = statusLabel
        self.sourceLabel = sourceLabel
        self.onImageLoaded = onImageLoaded
    }

    private let heroHeight: CGFloat = 340

    public var body: some View {
        ZStack(alignment: .bottom) {
            coverBackground

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.4),
                    .init(color: .black.opacity(0.72), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)

            HStack(alignment: .bottom, spacing: 14) {
                sharpCoverView
                heroMetadata.padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: UIScreen.main.bounds.width)
        .frame(height: heroHeight)
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var coverBackground: some View {
        let backgroundURL = backdropURL ?? coverURL
        if let bgURL = backgroundURL, let url = URL(string: bgURL) {
            LazyImage(url: url) { state in
                if let image = state.image {
                    Color.clear
                        .overlay(image.resizable().scaledToFill())
                        .clipped()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .processors([.resize(width: 400)])
            .frame(maxWidth: UIScreen.main.bounds.width, maxHeight: heroHeight)
            .blur(radius: 28, opaque: true)
            .padding(-28)
            .frame(maxWidth: UIScreen.main.bounds.width, maxHeight: heroHeight)
            .clipped()
            .ignoresSafeArea(edges: .top)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color(.secondarySystemBackground)
                .frame(height: heroHeight)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var sharpCoverView: some View {
        Group {
            if let coverURL = coverURL, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        Color.clear
                            .overlay(image.resizable().scaledToFill())
                            .clipped()
                            .onAppear {
                                if let uiImage = state.imageContainer?.image {
                                    onImageLoaded?(uiImage)
                                }
                            }
                    } else if state.error != nil {
                        Color.itoCardBackground
                    } else {
                        Color.itoCardBackground.overlay(ProgressView().tint(.white))
                    }
                }
                .processors([.resize(width: 400)])
            } else {
                ZStack {
                    Color.itoCardBackground
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 130, height: 195)
        .cornerRadius(10)
        .clipped()
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 6)
    }

    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.title2).fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)

            if let authorOrStudio = authorOrStudio, !authorOrStudio.isEmpty {
                Text(authorOrStudio)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if let label = statusLabel {
                    HeroBadge(label: label)
                }
                HeroBadge(label: sourceLabel)
            }
        }
    }
}

private struct HeroBadge: View {
    let label: String
    var body: some View {
        Text(label).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.2)).foregroundColor(.white).cornerRadius(5)
    }
}
