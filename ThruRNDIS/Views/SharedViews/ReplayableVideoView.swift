/*
Copyright (C) 2026 Afcoo.
*/

import AVKit
import SwiftUI

struct ReplayableVideoView: View {
    private let url: URL?
    private let replayAppearanceDelay: Duration
    private let isMuted: Bool
    private let loadingText: String
    private let unavailableText: String
    private let replayButtonTitle: String
    private let replayAccessibilityLabel: String

    @StateObject private var playback = VideoPlaybackStore()

    init(
        url: URL?,
        replayAppearanceDelay: Duration = .zero,
        isMuted: Bool = true,
        loadingText: String = "Preparing video…",
        unavailableText: String = "Video unavailable",
        replayButtonTitle: String = "Replay",
        replayAccessibilityLabel: String = "Replay video"
    ) {
        self.url = url
        self.replayAppearanceDelay = replayAppearanceDelay
        self.isMuted = isMuted
        self.loadingText = loadingText
        self.unavailableText = unavailableText
        self.replayButtonTitle = replayButtonTitle
        self.replayAccessibilityLabel = replayAccessibilityLabel
    }

    var body: some View {
        ZStack {
            if playback.phase == .ready, let player = playback.player {
                VideoPlayerView(player: player)
                    .blur(radius: playback.isReplayAvailable ? 8 : 0)
            } else if playback.phase == .failed {
                Color.secondary.opacity(0.08)

                Label(unavailableText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Color.secondary.opacity(0.08)

                ProgressView(loadingText)
                    .foregroundStyle(.secondary)
            }

            if playback.player != nil, playback.isReplayAvailable {
                Color.black.opacity(0.12)
                    .allowsHitTesting(false)

                Button {
                    playback.replay()
                } label: {
                    Label(replayButtonTitle, systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(replayAccessibilityLabel)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.isReplayAvailable)
        .task(id: playbackRequest) {
            await playback.start(
                url: url,
                isMuted: isMuted,
                replayAppearanceDelay: replayAppearanceDelay
            )
        }
        .onDisappear {
            playback.stop()
        }
    }

    private var playbackRequest: ReplayableVideoRequest {
        ReplayableVideoRequest(
            url: url,
            isMuted: isMuted,
            replayAppearanceDelay: replayAppearanceDelay
        )
    }
}

private struct ReplayableVideoRequest: Equatable {
    let url: URL?
    let isMuted: Bool
    let replayAppearanceDelay: Duration
}

private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Void) {
        playerView.player = nil
    }
}
