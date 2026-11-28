import SwiftUI
import Nuke
import NukeUI
import ito_runner

public struct MediaCardView<M: MediaDisplayable, Destination: View>: View {
    @Environment(\.sourceCoverRequests) private var coverRequests
    @Environment(\.imageSourceID) private var imageSourceID
    let media: M
    /// The cover is 11:16 at any width, so shelves can scale their posters with the screen.
    let width: CGFloat
    let destination: () -> Destination

    public init(media: M, width: CGFloat = 110, @ViewBuilder destination: @escaping () -> Destination) {
        self.media = media
        self.width = width
        self.destination = destination
    }

    private var height: CGFloat { width * 16 / 11 }

    public var body: some View {
        NavigationLink(destination: destination()) {
            VStack(alignment: .leading, spacing: 4) {
                if let coverURL = media.cover, let url = URL(string: coverURL) {
                    LazyImage(request: coverRequests.request(url, pluginID: imageSourceID)) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height)
                                .cornerRadius(8)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: width, height: height)
                                .cornerRadius(8)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: width, height: height)
                                .cornerRadius(8)
                        }
                    }
                    .processors([.resize(width: 220)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: width, height: height)
                        .cornerRadius(8)
                }

                Text(media.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
