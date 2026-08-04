import AVFoundation
import Foundation
import SwiftData
import os

private let log = Logger(subsystem: "com.armfin", category: "Playback")

/// What the player is doing, as far as the UI needs to care.
///
/// Deliberately small. The previous version had eight cases — `readyToPlay`,
/// `buffering` and `loadingItem` were separate — which the UI then had to
/// re-collapse into "spinner or not". More cases meant more ways for a stored
/// value to be wrong.
enum PlaybackState: Equatable {
    case idle
    /// Preparing: activating the audio session, resolving a URL, loading the
    /// asset, or waiting for the player to have enough to start.
    case loading
    case playing
    case paused
    case failed(message: String)
}

struct QueueItem: Equatable, Sendable {
    let trackId: String
    let title: String
    let artistName: String
    let albumName: String
    let albumId: String?
    let durationSeconds: Double
    let serverURL: String
    let accessToken: String
    let artworkURL: URL?
    let indexNumber: Int?
    let discNumber: Int?

    init(trackId: String, title: String, artistName: String, albumName: String,
         albumId: String? = nil, durationSeconds: Double, serverURL: String,
         accessToken: String, artworkURL: URL? = nil,
         indexNumber: Int? = nil, discNumber: Int? = nil) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.durationSeconds = durationSeconds
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.artworkURL = artworkURL
        self.indexNumber = indexNumber
        self.discNumber = discNumber
    }
}

/// Plays a queue of tracks, preferring a completed download over streaming.
///
/// ## Design
///
/// **State is derived, never stored.** `currentState` is computed from the
/// player every time it is read. AVFoundation types are `Observable` in the 26
/// releases, so reading `player.timeControlStatus` here registers a dependency
/// and SwiftUI updates on its own. The previous engine kept `currentState` as
/// a stored variable mutated from two KVO observers, two notification handlers
/// and five entry points, each guarded by a generation token — so the value
/// could, and did, disagree with the player. It cannot now, because it *is*
/// the player.
///
/// **One load path.** `load(index:)` is the only function that touches the
/// player's item. Every public entry point routes through it.
///
/// **One supersession check.** A single `loadID`, compared in exactly one
/// place (`isCurrent`), decides whether an in-flight load still owns the
/// engine. There are no per-item observers, so there is nothing else to guard.
///
/// **Nothing is abandoned on a timer.** No watchdogs. Activating a
/// `.longFormAudio` session on watchOS returns only once an output route
/// exists, and giving up on it early cannot make audio arrive sooner.
@Observable
@MainActor
final class PlaybackEngine {

    // MARK: - Player

    @ObservationIgnored
    private let player: AVPlayer

    // MARK: - Queue

    private(set) var queue: [QueueItem] = []
    private(set) var isShuffleEnabled = false
    private(set) var currentIndex: Int?

    @ObservationIgnored
    private var originalQueue: [QueueItem] = []

    var currentQueueItem: QueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Called whenever the engine moves to a different track, so Now Playing
    /// metadata can follow it.
    @ObservationIgnored
    var onQueueItemChanged: ((QueueItem) -> Void)?

    // MARK: - Engine-owned state
    //
    // Only the two things the player genuinely cannot report: that we are
    // between "user tapped" and "item handed to the player", and that a load
    // failed before an item ever existed.

    private var isPreparing = false
    private var failureMessage: String?

    /// Derived from the player on every read — see the type-level note.
    var currentState: PlaybackState {
        if let failureMessage { return .failed(message: failureMessage) }
        if isPreparing { return .loading }
        guard let item = player.currentItem else { return .idle }
        if item.status == .failed {
            return .failed(message: item.error?.localizedDescription ?? "Playback failed.")
        }
        switch player.timeControlStatus {
        case .playing: return .playing
        case .waitingToPlayAtSpecifiedRate: return .loading
        case .paused: return .paused
        @unknown default: return .paused
        }
    }

    // MARK: - Load bookkeeping

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    /// Incremented per load attempt. `isCurrent(_:)` is the single place it is
    /// compared, and every step of a load re-checks it after an `await`.
    @ObservationIgnored
    private var loadID = 0

    // MARK: - Audio session

    @ObservationIgnored
    private var isSessionActive = false

    /// The in-flight activation, shared by every caller that arrives while it
    /// runs. Without this, two taps in quick succession each start their own
    /// activation and race.
    @ObservationIgnored
    private var activationTask: Task<Bool, Never>?

    // MARK: - Dependencies

    @ObservationIgnored
    private nonisolated(unsafe) var modelContext: ModelContext?

    @ObservationIgnored
    private nonisolated(unsafe) var didPlayToEndToken: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionToken: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var routeChangeToken: NSObjectProtocol?

    private var wasPlayingBeforeInterruption = false

    // MARK: - Init

    init() {
        // Opt AVFoundation into Swift Observation. This is what lets
        // `currentState` be derived rather than mirrored. It is a type-level
        // switch, so it must be set before any player is created.
        AVPlayer.isObservationEnabled = true
        player = AVPlayer()

        // Leave this on. It makes `play()` mean "start as soon as the item is
        // ready" rather than "set the rate right now". `replaceCurrentItem`
        // does not make an item ready synchronously — not even for a local
        // file — so turning it off makes `play()` set a rate the player
        // immediately drops, which reads as play-then-pause with no audio.
        player.automaticallyWaitsToMinimizeStalling = true

        registerObservers()
    }

    deinit {
        for token in [didPlayToEndToken, interruptionToken, routeChangeToken] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    // MARK: - Queue management

    func setQueue(_ items: [QueueItem], startingAt startTrackId: String? = nil) {
        originalQueue = items
        queue = isShuffleEnabled
            ? shuffled(items, pinning: startTrackId ?? items.first?.trackId)
            : items
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        let playing = currentQueueItem?.trackId
        queue = isShuffleEnabled ? shuffled(originalQueue, pinning: playing) : originalQueue
        // The current track keeps playing; only its position changed.
        currentIndex = playing.flatMap { id in queue.firstIndex { $0.trackId == id } }
    }

    private func shuffled(_ items: [QueueItem], pinning trackId: String?) -> [QueueItem] {
        guard items.count > 1 else { return items }
        var result = items.shuffled()
        if let trackId, let at = result.firstIndex(where: { $0.trackId == trackId }), at != 0 {
            result.swapAt(0, at)
        }
        return result
    }

    // MARK: - Public playback control

    /// Starts the queued track with this id. `serverURL`/`accessToken` are
    /// accepted for call-site convenience; the queue entry's own credentials
    /// are what actually get used.
    func play(trackId: String, serverURL: String = "", accessToken: String = "", preferDirectPlay: Bool = false) {
        guard let index = queue.firstIndex(where: { $0.trackId == trackId }) else {
            log.error("play(trackId:) for a track that is not in the queue")
            failureMessage = "That track isn't in the current queue."
            return
        }
        load(index: index, reason: "play(trackId:)")
    }

    /// Kept for call sites that already resolved a downloaded file. `load`
    /// re-resolves the URL anyway, so this is just "play this queued track".
    func playLocalFile(url: URL, trackId: String) {
        play(trackId: trackId)
    }

    func play() {
        guard player.currentItem != nil else {
            // Nothing loaded — restart the current queue entry rather than
            // silently doing nothing.
            if let currentIndex { load(index: currentIndex, reason: "play() with no item") }
            return
        }
        failureMessage = nil
        withActiveSession { [weak self] in self?.player.play() }
    }

    func pause() {
        wasPlayingBeforeInterruption = false
        player.pause()
    }

    func togglePlayPause() {
        switch currentState {
        case .playing:
            pause()
        case .failed:
            // Retry the track rather than toggling into a state it can't reach.
            if let currentIndex { load(index: currentIndex, reason: "retry after failure") }
        case .idle, .loading, .paused:
            play()
        }
    }

    func advanceToNext() {
        guard !queue.isEmpty else { return }
        let next = (currentIndex ?? -1) + 1
        if next < queue.count {
            load(index: next, reason: "advanceToNext")
        } else {
            if isShuffleEnabled { queue = shuffled(originalQueue, pinning: nil) }
            load(index: 0, reason: "advanceToNext wrap")
        }
    }

    func returnToPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let previous = (currentIndex ?? 0) - 1
        if previous >= 0 {
            load(index: previous, reason: "returnToPrevious")
        } else if !isShuffleEnabled {
            load(index: queue.count - 1, reason: "returnToPrevious wrap")
        }
    }

    func stop() {
        loadID += 1
        loadTask?.cancel()
        loadTask = nil

        player.pause()
        player.replaceCurrentItem(with: nil)

        queue = []
        originalQueue = []
        currentIndex = nil
        isShuffleEnabled = false
        isPreparing = false
        failureMessage = nil
        wasPlayingBeforeInterruption = false
    }

    // MARK: - Time

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
    }

    func addPeriodicTimeObserver(forInterval interval: CMTime, using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: block)
    }

    func removeTimeObserver(_ observer: Any) {
        player.removeTimeObserver(observer)
    }

    // MARK: - The one load path

    /// Everything that starts a track goes through here.
    private func load(index: Int, reason: String) {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]

        loadID += 1
        let id = loadID
        loadTask?.cancel()

        currentIndex = index
        failureMessage = nil
        isPreparing = true

        onQueueItemChanged?(item)
        log.notice("Loading queue index \(index) reason=\(reason, privacy: .public)")

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            guard await self.activateSession() else {
                self.finish(id, failure: "Connect headphones to play audio.")
                return
            }
            guard self.isCurrent(id) else { return }

            guard let url = self.resolveURL(for: item) else {
                self.finish(id, failure: "This track isn't available offline.")
                return
            }

            let asset = AVURLAsset(url: url)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard self.isCurrent(id) else { return }
            guard isPlayable else {
                self.finish(id, failure: "This track can't be played.")
                return
            }

            let playerItem = AVPlayerItem(asset: asset)
            self.player.replaceCurrentItem(with: playerItem)

            // Wait for the item to actually be ready before asking it to play.
            // `play()` against a `.unknown` item is a request the player is
            // free to drop, which is what produced "spinner, then play button,
            // no audio" — the manual tap afterwards only worked because by
            // then the item had become ready on its own.
            let ready = await self.waitUntilReadyToPlay(playerItem)
            guard self.isCurrent(id) else { return }
            guard ready else {
                self.finish(id, failure: playerItem.error?.localizedDescription ?? "This track can't be played.")
                return
            }

            self.player.play()
            self.finish(id, failure: nil)
            self.logPlaybackAttempt(index: index)
        }
    }

    /// Bounded wait for `AVPlayerItem.status` to leave `.unknown`.
    ///
    /// This is a local readiness wait during an explicit, user-initiated load
    /// — not a background poll (soul.md §2.1) — and it is capped so a wedged
    /// item surfaces as a failure instead of an endless spinner.
    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<Self.readinessPollAttempts {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            case .unknown: break
            @unknown default: break
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        log.error("Item never became ready to play")
        return false
    }

    /// 50 ms x 200 = a 10 second ceiling.
    private static let readinessPollAttempts = 200

    /// One line describing why the player is or isn't playing.
    /// `reasonForWaitingToPlay` is the property that actually explains a
    /// player that accepted `play()` and then sat still.
    private func logPlaybackAttempt(index: Int) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        log.notice("""
            play() index=\(index) \
            timeControl=\(self.player.timeControlStatus.rawValue) \
            waitingReason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "none", privacy: .public) \
            itemStatus=\(self.player.currentItem?.status.rawValue ?? -1) \
            rate=\(self.player.rate) \
            route=\(route.isEmpty ? "none" : route, privacy: .public)
            """)
    }

    /// The single supersession check. A load that is no longer current must
    /// not touch engine state.
    private func isCurrent(_ id: Int) -> Bool {
        !Task.isCancelled && loadID == id
    }

    /// Clears the preparing flag for `id` only. Guarding on the id matters: a
    /// superseded load unwinds *after* its replacement has already set
    /// `isPreparing`, and clearing it unguarded would hide the new load's
    /// spinner while it was still working.
    private func finish(_ id: Int, failure: String?) {
        guard loadID == id else { return }
        isPreparing = false
        failureMessage = failure
        if let failure {
            log.error("Load failed: \(failure, privacy: .public)")
        }
    }

    /// A completed download wins over the network; a track with no local file
    /// and no credentials has nowhere to play from.
    private func resolveURL(for item: QueueItem) -> URL? {
        if let local = localFileURL(trackId: item.trackId) { return local }
        guard !item.serverURL.isEmpty, !item.accessToken.isEmpty else { return nil }
        return JellyfinAPIClient.streamingURL(
            serverURL: item.serverURL,
            accessToken: item.accessToken,
            trackId: item.trackId
        )
    }

    private func localFileURL(trackId: String) -> URL? {
        guard let modelContext else { return nil }
        let completed = BetaDownloadStatus.completed.rawValue
        let predicate = #Predicate<BetaDownloadItem> {
            $0.jellyfinId == trackId && $0.statusRaw == completed
        }
        guard let row = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first,
              let fileName = row.localFileName else { return nil }

        let url = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            row.statusRaw = BetaDownloadStatus.failed.rawValue
            row.lastError = "File missing from disk"
            try? modelContext.save()
            return nil
        }
        return url
    }

    // MARK: - Audio session

    /// `.longFormAudio` on watchOS must be activated with `activate()` —
    /// `setActive(_:)` is not supported for that policy and throws — and
    /// activation completes only once an output route exists, which on a cold
    /// launch genuinely takes a moment.
    private func activateSession() async -> Bool {
        if isSessionActive { return true }
        if let activationTask { return await activationTask.value }

        let task = Task { @MainActor () -> Bool in
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playback, mode: .default, policy: .longFormAudio, options: []
                )
                try await AVAudioSession.sharedInstance().activate()
                return true
            } catch {
                log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        activationTask = task
        let activated = await task.value
        activationTask = nil
        isSessionActive = activated
        return activated
    }

    /// Runs `work` with a live audio session, activating first if needed.
    private func withActiveSession(_ work: @escaping @MainActor () -> Void) {
        if isSessionActive {
            work()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.activateSession() {
                work()
            } else {
                self.failureMessage = "Connect headphones to play audio."
            }
        }
    }

    // MARK: - Observers
    //
    // Registered once, for the lifetime of the engine. Nothing is attached per
    // item, so nothing needs tearing down between tracks — which is what the
    // old generation guards existed to make safe.

    private func registerObservers() {
        didPlayToEndToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            // Read off the notification before hopping isolation: `Notification`
            // is not `Sendable`, so it must not cross into the closure below.
            let finished = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let finished,
                      finished === self.player.currentItem else { return }
                log.notice("AVPlayerItemDidPlayToEndTime fired at time=\(self.currentTime)")
                self.advanceToNext()
            }
        }

        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }

        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor [weak self] in
                guard reason == .oldDeviceUnavailable else { return }
                self?.pause()
            }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = (currentState == .playing)
            player.pause()
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            // The system tore the session down; it has to come back up before
            // the player has anywhere to output.
            isSessionActive = false
            guard shouldResume else { return }
            withActiveSession { [weak self] in self?.player.play() }
        default:
            break
        }
    }
}
