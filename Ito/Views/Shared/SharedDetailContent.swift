import SwiftUI

public struct SharedDetailContent: View {
    public let isSaved: Bool
    public let isTracked: Bool
    public let tags: [String]?
    public let cleanDescription: String?
    public var themeSecondary: Color?
    public let onSaveToggle: () -> Void
    public let onTrackToggle: (() -> Void)?

    @State private var isDescriptionExpanded = false

    public init(isSaved: Bool, isTracked: Bool, tags: [String]?, cleanDescription: String?, themeSecondary: Color? = nil, onSaveToggle: @escaping () -> Void, onTrackToggle: (() -> Void)? = nil) {
        self.isSaved = isSaved
        self.isTracked = isTracked
        self.tags = tags
        self.cleanDescription = cleanDescription
        self.themeSecondary = themeSecondary
        self.onSaveToggle = onSaveToggle
        self.onTrackToggle = onTrackToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionButtons.padding(.horizontal, 16).padding(.top, 16)

            if let tags = tags, !tags.isEmpty { tagsRow(tags: tags) }
            if let desc = cleanDescription, !desc.isEmpty { descriptionSection(desc) }

            Divider().padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .background(Color.clear)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if isSaved {
                Button(action: onSaveToggle) {
                    Label("Saved", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(themeSecondary ?? .accentColor)
                .foregroundStyle(themeSecondary == nil ? Color.itoOnAccent : .white)
                .controlSize(.regular)
            } else {
                Button(action: onSaveToggle) {
                    Label("Save", systemImage: "bookmark")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.regular)
            }

            if let onTrackToggle = onTrackToggle {
                if isTracked {
                    Button(action: onTrackToggle) {
                        Label("Tracking", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeSecondary ?? .purple)
                    .controlSize(.regular)
                } else {
                    Button(action: onTrackToggle) {
                        Label("Track", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .controlSize(.regular)
                }
            }
        }
    }

    private func tagsRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill)).cornerRadius(12)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "Show more")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
    }
}
