import SwiftUI
import Nuke
import NukeUI
import ito_runner

public struct MediaCardView<M: MediaDisplayable, Destination: View>: View {
    let media: M
    let destination: () -> Destination

    public init(media: M, @ViewBuilder destination: @escaping () -> Destination) {
        self.media = media
        self.destination = destination
    }

    public var body: some View {
        NavigationLink(destination: destination()) {
            VStack(alignment: .leading, spacing: 4) {
                if let coverURL = media.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 110, height: 160)
                                .cornerRadius(8)
                        }
                    }
                    .processors([.resize(width: 220)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 110, height: 160)
                        .cornerRadius(8)
                }

                Text(media.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
