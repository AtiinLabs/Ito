import SwiftUI
import Nuke
import NukeUI

struct SearchCardView: View {
    @Environment(\.sourceCoverRequests) private var coverRequests
    let result: PluginSearchResult
    /// The card width comes from the shelf, which sizes it to the screen; the cover keeps the 11:16 poster ratio.
    let width: CGFloat

    private var coverHeight: CGFloat { width * 16 / 11 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let coverURL = result.cover, let url = URL(string: coverURL) {
                LazyImage(request: coverRequests.request(url, pluginID: result.destination.pluginID)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: coverHeight)
                            .cornerRadius(10)
                            .clipped()
                    } else if state.error != nil {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.15))
                            .frame(width: width, height: coverHeight)
                            .overlay(
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: width, height: coverHeight)
                            .overlay(ProgressView())
                    }
                }
                .processors([.resize(width: width * 2)])
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: width, height: coverHeight)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }

            Text(result.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
        }
    }
}
