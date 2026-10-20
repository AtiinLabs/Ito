import AVKit
import SwiftUI
import ito_runner

struct VideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel

    @State private var showQualitySelector = false
    @State private var showAudioSelector = false
    @State private var showSubtitleSelector = false

    @Environment(\.dismiss) private var dismiss

    init(viewModel: VideoPlayerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.loadPhase {
            case .idle, .loading:
                loadingView
            case .failure(let error):
                errorView(error)
            case .content:
                contentView
            }
        }
        .confirmationDialog("Select Quality", isPresented: $showQualitySelector) {
            ForEach(Array(viewModel.videos.enumerated()), id: \.offset) { _, video in
                Button(video.quality) {
                    viewModel.selectVideo(video)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Select Audio Track", isPresented: $showAudioSelector) {
            if let tracks = viewModel.selectedVideo?.audioTracks {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    Button(track.language) {
                        viewModel.selectAudioTrack(track)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Select Subtitles", isPresented: $showSubtitleSelector) {
            Button("Off") {
                viewModel.selectSubtitle(nil)
            }
            if let subtitles = viewModel.selectedVideo?.subtitles {
                ForEach(Array(subtitles.enumerated()), id: \.offset) { _, subtitle in
                    let type = subtitle.isHardsub ? "(Hardsub)" : "(Softsub)"
                    Button("\(subtitle.language) \(type)") {
                        viewModel.selectSubtitle(subtitle)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Continue Watching?",
            isPresented: Binding(
                get: { viewModel.resumeOffer != nil },
                set: { _ in }
            )
        ) {
            Button("Continue from \(Self.formattedTime(viewModel.resumeOffer ?? 0))") {
                viewModel.resolveResumeOffer(continueWatching: true)
            }
            Button("Start Over") {
                viewModel.resolveResumeOffer(continueWatching: false)
            }
        } message: {
            Text("You stopped this episode at \(Self.formattedTime(viewModel.resumeOffer ?? 0)).")
        }
        .task {
            viewModel.start()
        }
        .onAppear {
            viewModel.appear()
        }
        .onChange(of: viewModel.episode.key) { _ in
            viewModel.episodeDidChange()
        }
        .onDisappear {
            viewModel.disappear()
        }
    }

    /// "12:34", or "1:02:03" past an hour.
    static func formattedTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            Text("Extracting Video Streams...")
                .foregroundColor(.white)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)
            Text("Error Loading Video")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(error)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Close") {
                close()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.2))
            .foregroundColor(.white)
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let surface = viewModel.playbackSurface as? AVPlayerVideoPlaybackSurface,
           let video = viewModel.selectedVideo {
            VideoPlayer(player: surface.player)
                .ignoresSafeArea()
                .overlay(subtitleOverlay)
                .overlay(controlsOverlay(video: video))
        } else {
            Text("No playable streams found.")
                .foregroundColor(.white)
        }
    }

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            if let subtitleText = viewModel.currentSubtitleText {
                Text(subtitleText)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(8)
                    .padding(.bottom, 60)
            }
        }
    }

    private func controlsOverlay(video: Anime.Video) -> some View {
        VStack {
            HStack {
                // The custom back button is required because native AVPlayer fullscreen dismissal
                // does not reliably drive SwiftUI dismissal for this presentation route.
                Button(action: close) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                        .padding()
                        .background(Circle().fill(Color.black.opacity(0.01)))
                }

                Spacer()

                if let tracks = video.audioTracks, tracks.count > 1 {
                    Button(action: { showAudioSelector = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2")
                            Text(viewModel.selectedAudioTrack?.language ?? "Audio")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                }

                if let subtitles = video.subtitles, !subtitles.isEmpty {
                    Button(action: { showSubtitleSelector = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "captions.bubble")
                            Text(viewModel.selectedSubtitle?.language ?? "Subtitles")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(viewModel.selectedSubtitle != nil ? .accentColor : .white)
                        .cornerRadius(6)
                    }
                }

                if viewModel.videos.count > 1 {
                    Button(action: { showQualitySelector = true }) {
                        Text(video.quality)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                }
            }
            .padding()
            Spacer()
        }
    }

    private func close() {
        viewModel.close()
        dismiss()
    }
}
