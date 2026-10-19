import SwiftUI
import Nuke
import NukeUI
import ito_runner

public struct MediaBigCardView<M: MediaDisplayable, Destination: View>: View {
    let media: M
    let destination: () -> Destination

    public init(media: M, @ViewBuilder destination: @escaping () -> Destination) {
        self.media = media
        self.destination = destination
    }

    public var body: some View {
        NavigationLink(destination: destination()) {
            VStack(alignment: .leading, spacing: 8) {
                if let coverURL = media.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 96)
                                .cornerRadius(12)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 240, height: 96)
                                .cornerRadius(12)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 240, height: 96)
                                .cornerRadius(12)
                        }
                    }
                    .processors([.resize(width: 480)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 240, height: 96)
                        .cornerRadius(12)
                }

                Text(media.title)
                    .font(.body)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .frame(width: 240, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
