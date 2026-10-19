import SwiftUI
import Nuke
import NukeUI

struct SearchCardView: View {
    let result: PluginSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let coverURL = result.cover, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 110, height: 160)
                            .cornerRadius(10)
                            .clipped()
                    } else if state.error != nil {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.15))
                            .frame(width: 110, height: 160)
                            .overlay(
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 110, height: 160)
                            .overlay(ProgressView())
                    }
                }
                .processors([.resize(width: 220)])
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 110, height: 160)
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
                .frame(width: 110, alignment: .leading)
        }
    }
}
