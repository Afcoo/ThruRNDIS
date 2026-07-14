/*
Copyright (C) 2026 Afcoo.
*/

import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlaybackStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isReplayAvailable = false

    private var loadGeneration = 0
    private var replayAppearanceDelay: Duration = .zero
    private var replayAppearanceTask: Task<Void, Never>?
    private var playerItemStatusObservation: AnyCancellable?
    private var playbackEndObservation: AnyCancellable?
    private var playbackFailureObservation: AnyCancellable?

    func start(
        url: URL?,
        isMuted: Bool = true,
        replayAppearanceDelay: Duration = .zero
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        tearDownPlayer()
        phase = .loading
        isReplayAvailable = false
        self.replayAppearanceDelay = replayAppearanceDelay

        guard let url else {
            phase = .failed
            return
        }

        do {
            let asset = AVURLAsset(url: url)
            let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
            try Task.checkCancellation()

            guard generation == loadGeneration else {
                return
            }
            guard isPlayable, duration.seconds.isFinite, duration.seconds > 0 else {
                phase = .failed
                return
            }

            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = isMuted
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .pause

            self.player = player
            observeStatus(of: playerItem, generation: generation)
            observePlaybackEnd(of: playerItem)
            observePlaybackFailure(of: playerItem)
        } catch is CancellationError {
            guard generation == loadGeneration else {
                return
            }
            phase = .idle
        } catch {
            guard generation == loadGeneration else {
                return
            }
            phase = .failed
        }
    }

    func replay() {
        guard player != nil else {
            return
        }

        replayAppearanceTask?.cancel()
        replayAppearanceTask = nil
        isReplayAvailable = false
        phase = .ready
        playFromBeginning()
    }

    func stop() {
        loadGeneration &+= 1
        tearDownPlayer()
        phase = .idle
        isReplayAvailable = false
    }

    private func observeStatus(of playerItem: AVPlayerItem, generation: Int) {
        playerItemStatusObservation = playerItem.publisher(
            for: \.status,
            options: [.initial, .new]
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak playerItem] status in
            guard let self,
                  let playerItem,
                  generation == self.loadGeneration,
                  self.player?.currentItem === playerItem else {
                return
            }

            switch status {
            case .readyToPlay:
                self.phase = .ready
                self.playFromBeginning()
            case .failed:
                self.failPlayback()
            case .unknown:
                break
            @unknown default:
                self.failPlayback()
            }
        }
    }

    private func observePlaybackEnd(of playerItem: AVPlayerItem) {
        playbackEndObservation = NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.scheduleReplayAppearance()
        }
    }

    private func observePlaybackFailure(of playerItem: AVPlayerItem) {
        playbackFailureObservation = NotificationCenter.default.publisher(
            for: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.failPlayback()
        }
    }

    private func playFromBeginning() {
        guard let player else {
            return
        }

        player.pause()
        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            guard finished else {
                return
            }

            Task { @MainActor in
                guard let self,
                      let player,
                      self.player === player,
                      self.phase == .ready else {
                    return
                }

                player.play()
            }
        }
    }

    private func scheduleReplayAppearance() {
        replayAppearanceTask?.cancel()
        replayAppearanceTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: self.replayAppearanceDelay)
            } catch {
                return
            }

            guard self.player != nil else {
                return
            }

            self.isReplayAvailable = true
            self.replayAppearanceTask = nil
        }
    }

    private func tearDownPlayer() {
        replayAppearanceTask?.cancel()
        replayAppearanceTask = nil
        playerItemStatusObservation?.cancel()
        playerItemStatusObservation = nil
        playbackEndObservation?.cancel()
        playbackEndObservation = nil
        playbackFailureObservation?.cancel()
        playbackFailureObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func failPlayback() {
        tearDownPlayer()
        isReplayAvailable = false
        phase = .failed
    }
}
