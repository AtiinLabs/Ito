import SwiftUI
import NukeUI
import Nuke

public struct PluginResultRow: View {
    public let result: PluginSearchResult

    public init(result: PluginSearchResult) {
        self.result = result
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let coverURL = result.cover, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.itoCardBackground
                    }
                }
                .processors([.resize(width: 100)])
                .frame(width: 50, height: 72)
                .cornerRadius(8)
                .clipped()
            } else {
                Color.itoCardBackground
                    .frame(width: 50, height: 72)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let pluginName = result.pluginName, !pluginName.isEmpty {
                    Text(pluginName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                        .padding(.top, 4)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
