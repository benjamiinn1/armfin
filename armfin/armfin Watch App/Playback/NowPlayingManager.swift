import AVFoundation
import Foundation
import MediaPlayer
import UIKit

struct NowPlayingMetadata: Sendable {
    let title: String
    let artistName: String
    let albumName: String
    let durationSeconds: Double
    let albumId: String?
}

/// Carries elapsed time only — deliberately not playback state.
///
/// It used to carry `state` too, as a copy of `PlaybackEngine.currentState`
/// taken whenever this snapshot was republished. That copy was the source of
/// the "sometimes it plays, sometimes it doesn't" reports: it is written from
/// the 1 Hz periodic time observer, which **only fires while the player is
/// actually advancing time**, and from `setNowPlaying(track:)`. Starting a
/// track calls `setNowPlaying` *before* the load begins, so the snapshot got
/// stamped with the pre-load state and then nothing refreshed it until audio
/// was already running. A view reading it saw a pause button over silence, or
/// a spinner with nothing left to clear it.
///
/// Elapsed time is legitimately a sampled 1 Hz value. Playback state is not —
/// read it live from `PlaybackEngine`, which is `@Observable`.
struct NowPlayingSnapshot: Sendable, Equatable {
    let elapsedTime: TimeInterval
}

@Observable
@MainActor
final class NowPlayingManager {

    // MARK: - Dependencies

    @ObservationIgnored
    private let playbackEngine: PlaybackEngine

    // MARK: - Observable snapshot

    private(set) var nowPlayingSnapshot = NowPlayingSnapshot(elapsedTime: 0)

    private(set) var currentTrack: NowPlayingTrack?

    // MARK: - Stored metadata

    @ObservationIgnored
    private var currentMetadata: NowPlayingMetadata?

    // MARK: - Tokens

    @ObservationIgnored
    private nonisolated(unsafe) var playCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var pauseCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var togglePlayPauseCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var nextTrackCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var previousTrackCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var changePlaybackPositionCommandToken: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var periodicTimeObserverToken: Any?

    // MARK: - Init / deinit

    init(playbackEngine: PlaybackEngine) {
        self.playbackEngine = playbackEngine
        registerRemoteCommands()
        startPeriodicTimeObserver()
    }

    deinit {
        let center = MPRemoteCommandCenter.shared()

        if let playCommandToken {
            center.playCommand.removeTarget(playCommandToken)
        }
        if let pauseCommandToken {
            center.pauseCommand.removeTarget(pauseCommandToken)
        }
        if let togglePlayPauseCommandToken {
            center.togglePlayPauseCommand.removeTarget(togglePlayPauseCommandToken)
        }
        if let nextTrackCommandToken {
            center.nextTrackCommand.removeTarget(nextTrackCommandToken)
        }
        if let previousTrackCommandToken {
            center.previousTrackCommand.removeTarget(previousTrackCommandToken)
        }
        if let changePlaybackPositionCommandToken {
            center.changePlaybackPositionCommand.removeTarget(changePlaybackPositionCommandToken)
        }
        if let periodicTimeObserverToken {
            let engine = playbackEngine
            Task { @MainActor in
                engine.removeTimeObserver(periodicTimeObserverToken)
            }
        }
    }

    // MARK: - Now Playing metadata

    func clearNowPlaying() {
        currentMetadata = nil
        currentTrack = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlayingSnapshot = NowPlayingSnapshot(elapsedTime: 0)
    }

    func setNowPlaying(track: NowPlayingTrack) {
        currentTrack = track
        setNowPlayingMetadata(NowPlayingMetadata(
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            durationSeconds: track.durationSeconds,
            albumId: track.albumId
        ))
    }

    private func publishNowPlayingInfo(elapsedTime: TimeInterval) {
        let engineState = playbackEngine.currentState
        nowPlayingSnapshot = NowPlayingSnapshot(elapsedTime: elapsedTime)

        guard let currentMetadata else { return }

        let infoCenter = MPNowPlayingInfoCenter.default()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentMetadata.title,
            MPMediaItemPropertyArtist: currentMetadata.artistName,
            MPMediaItemPropertyAlbumTitle: currentMetadata.albumName,
            MPMediaItemPropertyPlaybackDuration: currentMetadata.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: engineState == .playing ? 1.0 : 0.0
        ]

        if let existing = infoCenter.nowPlayingInfo,
           let artwork = existing[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info
    }

    // MARK: - Artwork for system Now Playing

    @ObservationIgnored
    private var cachedArtwork: MPMediaItemArtwork?
    @ObservationIgnored
    private var cachedArtworkAlbumId: String?

    func setNowPlayingMetadata(_ metadata: NowPlayingMetadata) {
        currentMetadata = metadata
        loadArtworkIfNeeded(albumId: metadata.albumId)
        publishNowPlayingInfo(elapsedTime: playbackEngine.currentTime)
    }

    private func loadArtworkIfNeeded(albumId: String?) {
        guard albumId != cachedArtworkAlbumId else { return }
        cachedArtworkAlbumId = albumId
        cachedArtwork = nil
        clearSystemArtwork()
    }

    private func clearSystemArtwork() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        if var info = infoCenter.nowPlayingInfo {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            infoCenter.nowPlayingInfo = info
        }
    }

    // MARK: - Periodic time observer

    private func startPeriodicTimeObserver() {
        periodicTimeObserverToken = playbackEngine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1)
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                self?.publishNowPlayingInfo(elapsedTime: seconds.isFinite ? seconds : 0)
            }
        }
    }

    // MARK: - Remote command registration

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        playCommandToken = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEngine.play()
            }
            return .success
        }

        pauseCommandToken = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEngine.pause()
            }
            return .success
        }

        togglePlayPauseCommandToken = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEngine.togglePlayPause()
            }
            return .success
        }

        nextTrackCommandToken = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEngine.advanceToNext()
            }
            return .success
        }

        previousTrackCommandToken = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEngine.returnToPrevious()
            }
            return .success
        }

        changePlaybackPositionCommandToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.playbackEngine.seek(to: positionTime)
            }
            return .success
        }
    }
}
