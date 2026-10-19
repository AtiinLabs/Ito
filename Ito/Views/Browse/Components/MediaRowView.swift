import SwiftUI
import Nuke
import NukeUI
import ito_runner

public struct MediaRowView<M: MediaDisplayable, Destination: View>: View {
    let media: M
    let destination: () -> Destination

    public init(media: M, @ViewBuilder destination: @escaping () -> Destination) {
        self.media = media
        self.destination = destination
    }

    public var body: some View {
        NavigationLink(destination: destination()) {
            HStack(alignment: .top, spacing: 12) {
                if let coverURL = media.cover, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                                .clipped()
                        } else if state.error != nil {
                            Color.red.opacity(0.3)
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                        } else {
                            Color.gray.opacity(0.3)
                                .frame(width: 60, height: 90)
                                .cornerRadius(6)
                        }
                    }
                    .processors([.resize(width: 120)])
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 60, height: 90)
                        .cornerRadius(6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(media.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let authors = media.authors, !authors.isEmpty {
                        Text(authors.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let studios = media.studios, !studios.isEmpty {
                        Text(studios.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal)
    }
}
