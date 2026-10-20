import SwiftUI

struct DiscoverErrorView: View {
    let errorMessage: String?
    let isOutage: Bool
    let onRetry: () -> Void

    private let discordURL = URL(string: "https://discord.com/invite/TF428cr")!

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            VStack(spacing: 16) {
                Image(systemName: isOutage ? "antenna.radiowaves.left.and.right.slash" : "wifi.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(isOutage ? .orange : .secondary)
                    .opacity(isOutage ? 0.8 : 1.0)
                    .animation(isOutage ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: isOutage)

                Text(isOutage ? "AniList Service Unavailable" : "Unable to Load Content")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
            }

            // Description
            VStack(spacing: 8) {
                Text(isOutage
                     ? "The AniList API has been temporarily disabled due to stability issues. This is an external factor and not a bug in the app."
                     : "Check your internet connection or try again later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = errorMessage, !isOutage {
                    Text(error)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .padding(.horizontal, 32)
                        .lineLimit(3)
                }
            }

            // Actions
            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Try Again")
                        .font(.headline)
                        .foregroundColor(.itoOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                if isOutage {
                    Link(destination: discordURL) {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Check AniList Discord Status")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiscoverErrorView_Previews: PreviewProvider {
    static var previews: some View {
        DiscoverErrorView(
            errorMessage: "403 Forbidden: API Disabled",
            isOutage: true,
            onRetry: {}
        )
    }
}
