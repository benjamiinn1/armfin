import AVFoundation
import Foundation
import SwiftData

enum PlaybackState: Equatable {
    case idle
    case loadingItem(trackId: String)
    case readyToPlay
    case playing
    case paused
    case buffering
    case finishedTrack
    case failed(message: String)
}

enum PlaybackEngineError: Error, Equatable {
    case unresolvedStreamingURL
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

    init(trackId: String, title: String, artistName: String, albumName: String,
         albumId: String? = nil, durationSeconds: Double, serverURL: String,
         accessToken: String, artworkURL: URL? = nil) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.durationSeconds = durationSeconds
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.artworkURL = artworkURL
    }
}

@Observable
@MainActor
final class PlaybackEngine {

    // MARK: - Queue

    private(set) var queue: [QueueItem] = []
    private var originalQueue: [QueueItem] = []
    private(set) var currentQueueItem: QueueItem?
    private(set) var isShuffleEnabled: Bool = false

    // MARK: - Observable state

    private(set) var currentState: PlaybackState = .idle

    private var wasPlayingBeforeInterruption = false

    // MARK: - AVFoundation objects

    @ObservationIgnored
    private let player = AVPlayer()
    @ObservationIgnored
    private var currentItem: AVPlayerItem?

    // MARK: - Retained track identity

    private var currentTrackId: String?
    private var currentServerURL: String?
    private var currentAccessToken: String?
    private var currentPreferDirectPlay = false
    private var currentItemURL: URL?

    // MARK: - KVO tokens

    @ObservationIgnored
    private var timeControlStatusObservation: NSKeyValueObservation?
    @ObservationIgnored
    private var itemStatusObservation: NSKeyValueObservation?

    // MARK: - Play-attempt generation tracking

    /// Monotonically incrementing token. Every `play(trackId:...)`,
    /// `playLocalFile(url:trackId:)`, and the local-file-switch branch of the
    /// zero-argument `play()` bumps this and captures the new value as "its"
    /// generation. Every state-mutating step belonging to that attempt
    /// (continuation after an `await`, KVO callback, notification callback)
    /// must reconfirm the engine's generation still matches before touching
    /// `currentItem`, `currentItemURL`, or `currentState`. This is what
    /// actually prevents a superseded attempt from corrupting state — the
    /// stored `Task` below is only a best-effort optimization, not a
    /// correctness guarantee (see `activeLoadTask`).
    private var playAttemptGeneration = 0

    /// Handle to the in-flight load `Task` for the current play attempt.
    /// Cancelled (not awaited) whenever a new attempt begins, so wasted
    /// `asset.load`/audio-session work is abandoned promptly. Cooperative
    /// cancellation does not interrupt a KVO observer closure or guarantee
    /// `AVURLAsset.load` stops immediately, so `playAttemptGeneration` above
    /// remains the actual correctness mechanism even when this fires.
    @ObservationIgnored
    private var activeLoadTask: Task<Void, Never>?

    /// Artificial delay injected immediately before `asset.load(.isPlayable)`
    /// inside `loadAndPlayAsync`, for deterministic rapid-switch test repros
    /// (e.g. forcing track A's local-file load to outlast track B's so a
    /// test harness can assert A's stale resolution is a no-op). Has zero
    /// effect and is hard-coded to 0 outside DEBUG builds.
    #if DEBUG
    var debugLoadDelay: TimeInterval = 0
    #endif

    // MARK: - NotificationCenter tokens

    @ObservationIgnored
    private nonisolated(unsafe) var didPlayToEndTimeToken: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var failedToPlayToEndTimeToken: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionToken: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var routeChangeToken: NSObjectProtocol?

    // MARK: - Dependencies

    @ObservationIgnored
    private let apiClient: JellyfinAPIClient

    @ObservationIgnored
    private nonisolated(unsafe) var modelContext: ModelContext?

    /// Whether the audio session has been fully activated via the async
    /// `activate()` method (which handles Bluetooth route selection on watchOS).
    @ObservationIgnored
    private var isAudioSessionActivated = false

    init(apiClient: JellyfinAPIClient = JellyfinAPIClient()) {
        self.apiClient = apiClient
        player.automaticallyWaitsToMinimizeStalling = true
        registerInterruptionObserver()
        registerRouteChangeObserver()

        do {
            try configureAudioSessionCategory()
        } catch {
        }
    }

    deinit {
        timeControlStatusObservation?.invalidate()
        itemStatusObservation?.invalidate()

        if let didPlayToEndTimeToken {
            NotificationCenter.default.removeObserver(didPlayToEndTimeToken)
        }
        if let failedToPlayToEndTimeToken {
            NotificationCenter.default.removeObserver(failedToPlayToEndTimeToken)
        }
        if let interruptionToken {
            NotificationCenter.default.removeObserver(interruptionToken)
        }
        if let routeChangeToken {
            NotificationCenter.default.removeObserver(routeChangeToken)
        }
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    // MARK: - Audio session configuration (§3.4)

    /// Sets the audio session category and policy. Called once from init.
    /// Does NOT activate — activation must go through `activateAudioSession()`.
    func configureAudioSessionCategory() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    }

    /// Activates the audio session using the async watchOS `activate()` method
    /// which handles Bluetooth route selection. Must be called before first
    /// playback. Subsequent calls are no-ops if already activated.
    /// Returns `true` if a valid audio route is available.
    func activateAudioSession() async -> Bool {
        guard !isAudioSessionActivated else { return true }
        do {
            try configureAudioSessionCategory()
            try await AVAudioSession.sharedInstance().activate()
            isAudioSessionActivated = true
            return true
        } catch {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActivated = true
                return true
            } catch {
                isAudioSessionActivated = false
                return false
            }
        }
    }

    /// Synchronous fallback for re-activating the session after interruptions
    /// or route changes, when the async route picker isn't needed.
    private func ensureAudioSessionActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
        }
    }

    // MARK: - Streaming URL resolution

    func resolveStreamingURL(
        serverURL: String,
        accessToken: String,
        trackId: String,
        preferDirectPlay: Bool = false
    ) -> Result<URL, PlaybackEngineError> {
        guard let url = apiClient.streamingURL(
            serverURL: serverURL,
            accessToken: accessToken,
            trackId: trackId,
            preferDirectPlay: preferDirectPlay
        ) else {
            return .failure(.unresolvedStreamingURL)
        }
        return .success(url)
    }

    // MARK: - Local-file URL resolution

    private func resolveLocalFileURL(trackId: String) -> URL? {
        guard let modelContext else { return nil }

        let betaPredicate = #Predicate<BetaDownloadItem> {
            $0.jellyfinId == trackId && $0.statusRaw == "completed"
        }
        if let betaItem = try? modelContext.fetch(FetchDescriptor(predicate: betaPredicate)).first,
           let fileName = betaItem.localFileName {
            let fileURL = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            betaItem.statusRaw = BetaDownloadStatus.failed.rawValue
            betaItem.lastError = "File missing from disk"
            try? modelContext.save()
        }

        return nil
    }

    // MARK: - Playback control

    /// Begins a new play attempt: bumps `playAttemptGeneration` and cancels
    /// whatever `Task` was tracking the previous attempt. Returns the new
    /// generation, which the caller must thread through to every subsequent
    /// state-mutating step of this attempt. Every call site that starts a
    /// load (`play(trackId:...)`, `playLocalFile(url:trackId:)`, and the
    /// local-file-switch branch of `play()`) must route through this so the
    /// guard logic exists in exactly one place.
    private func beginNewPlayAttempt() -> Int {
        activeLoadTask?.cancel()
        playAttemptGeneration += 1
        return playAttemptGeneration
    }

    /// True if `generation` is still the engine's current play attempt.
    /// Every continuation after an `await`, and every KVO/notification
    /// callback, must check this before mutating `currentItem`,
    /// `currentItemURL`, or `currentState` — a `false` result means a newer
    /// `play()` call has superseded this attempt and it must be a no-op.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == playAttemptGeneration
    }

    func play(
        trackId: String,
        serverURL: String,
        accessToken: String,
        preferDirectPlay: Bool = false
    ) {
        let generation = beginNewPlayAttempt()

        currentState = .loadingItem(trackId: trackId)

        currentTrackId = trackId
        currentServerURL = serverURL
        currentAccessToken = accessToken
        currentPreferDirectPlay = preferDirectPlay

        if let item = queue.first(where: { $0.trackId == trackId }) {
            currentQueueItem = item
        }

        activeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isAudioSessionActivated {
                let activated = await self.activateAudioSession()
                guard self.isCurrent(generation) else { return }
                if !activated {
                    self.currentState = .failed(message: "Connect headphones to play audio.")
                    return
                }
            }
            guard self.isCurrent(generation) else { return }
            await self.startPlayback(
                generation: generation,
                trackId: trackId,
                serverURL: serverURL,
                accessToken: accessToken,
                preferDirectPlay: preferDirectPlay
            )
        }
    }

    private func startPlayback(
        generation: Int,
        trackId: String,
        serverURL: String,
        accessToken: String,
        preferDirectPlay: Bool
    ) async {
        guard isCurrent(generation) else { return }

        if let localURL = resolveLocalFileURL(trackId: trackId) {
            await loadAndPlayAsync(url: localURL, generation: generation)
            return
        }

        guard !serverURL.isEmpty, !accessToken.isEmpty else {
            handleOfflinePlaybackUnavailable()
            return
        }

        switch resolveStreamingURL(
            serverURL: serverURL,
            accessToken: accessToken,
            trackId: trackId,
            preferDirectPlay: preferDirectPlay
        ) {
        case .failure:
            currentState = .failed(message: "Could not resolve a streaming URL for this track.")
        case .success(let url):
            loadAndPlay(url: url, generation: generation)
        }
    }

    /// When a track can't be played offline and has no server credentials,
    /// skip to the next track in the queue instead of leaving the player in
    /// a failed state that can crash the UI. Only fails if no playable track
    /// remains.
    private func handleOfflinePlaybackUnavailable() {
        guard !queue.isEmpty, let currentTrackId else {
            currentState = .failed(message: "Track not available offline.")
            return
        }
        guard let currentIndex = queue.firstIndex(where: { $0.trackId == currentTrackId }) else {
            currentState = .failed(message: "Track not available offline.")
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            let nextItem = queue[nextIndex]
            if resolveLocalFileURL(trackId: nextItem.trackId) != nil
                || (!nextItem.serverURL.isEmpty && !nextItem.accessToken.isEmpty) {
                playQueueItem(at: nextIndex)
            } else {
                currentState = .failed(message: "No playable tracks available offline.")
            }
        } else {
            currentState = .failed(message: "Track not available offline.")
        }
    }

    /// Bounded watchdog for `loadAndPlayAsync`'s `asset.load(.isPlayable)`
    /// call. 6 seconds is a reasoned default for a local file's
    /// "is this playable" check — not an Apple-stated number — chosen to be
    /// comfortably longer than any real on-disk load while still bounding a
    /// genuinely stuck attempt to a user-noticeable but not indefinite wait.
    /// This is defense-in-depth only: it does not fix the race (the
    /// generation check does), it only prevents a single, non-superseded
    /// attempt from hanging forever for an unrelated reason (e.g. a stalled
    /// disk read).
    private static let loadWatchdogTimeout: TimeInterval = 6

    private enum LoadOutcome: Sendable {
        case playable(Bool)
        case timedOut
    }

    /// `@MainActor`-isolated mutable flag shared between the load task and
    /// the watchdog task in `raceAgainstWatchdog`, so exactly one of them
    /// resumes the race's continuation. A plain captured `var` can't cross
    /// into a `@Sendable` `Task` closure by reference; this box can, because
    /// its mutable state is actor-isolated rather than ad hoc shared memory.
    @MainActor
    private final class MainActorFlag {
        var value = false
    }

    private func loadAndPlay(url: URL, generation: Int) {
        guard isCurrent(generation) else { return }

        tearDownObservers()

        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            currentState = .failed(message: "Downloaded file is missing.")
            advanceToNextOnFailure()
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        currentItem = item
        currentItemURL = url
        player.replaceCurrentItem(with: item)

        attachObservers(to: item, generation: generation)

        player.play()
    }

    private func loadAndPlayAsync(url: URL, generation: Int) async {
        guard isCurrent(generation) else { return }

        tearDownObservers()

        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            currentState = .failed(message: "Downloaded file is missing.")
            advanceToNextOnFailure()
            return
        }

        let asset = AVURLAsset(url: url)

        if url.isFileURL {
            #if DEBUG
            let injectedDelay = debugLoadDelay
            #else
            let injectedDelay = 0.0
            #endif

            let outcome = await raceAgainstWatchdog(timeout: Self.loadWatchdogTimeout) {
                if injectedDelay > 0 {
                    try? await Task.sleep(for: .seconds(injectedDelay))
                }
                do {
                    return LoadOutcome.playable(try await asset.load(.isPlayable))
                } catch {
                    return LoadOutcome.playable(false)
                }
            }

            guard isCurrent(generation) else { return }

            switch outcome {
            case .timedOut:
                asset.cancelLoading()
                currentState = .failed(message: "Loading this track timed out.")
                advanceToNextOnFailure()
                return
            case .playable(false):
                currentState = .failed(message: "This audio format is not supported.")
                advanceToNextOnFailure()
                return
            case .playable(true):
                break
            }
        }

        guard isCurrent(generation) else { return }

        let item = AVPlayerItem(asset: asset)
        currentItem = item
        currentItemURL = url
        player.replaceCurrentItem(with: item)

        attachObservers(to: item, generation: generation)

        player.play()
    }

    /// Races a `@MainActor`-isolated load operation against a timeout.
    /// Returns the operation's result if it finishes first, or `.timedOut`
    /// if the watchdog fires first. Both the load and the watchdog run as
    /// child `Task`s of the calling `@MainActor` context (not a `Sendable`
    /// task group), so the non-Sendable `AVURLAsset` never needs to cross an
    /// isolation boundary. Whichever finishes first resumes the shared
    /// continuation (guarded so only the first resumption counts); the loser
    /// is cancelled cooperatively. Per the research notes this does not
    /// guarantee `asset.load` halts immediately on cancellation —
    /// `asset.cancelLoading()` at the call site is what actually stops the
    /// AVFoundation-side work.
    private func raceAgainstWatchdog(
        timeout: TimeInterval,
        operation: @escaping @MainActor () async -> LoadOutcome
    ) async -> LoadOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<LoadOutcome, Never>) in
            let hasResumed = MainActorFlag()

            let loadTask = Task { @MainActor in
                let result = await operation()
                guard !hasResumed.value else { return }
                hasResumed.value = true
                continuation.resume(returning: result)
            }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !hasResumed.value else { return }
                hasResumed.value = true
                loadTask.cancel()
                continuation.resume(returning: .timedOut)
            }
        }
    }

    /// When a track fails to load (missing file, decode error), try
    /// advancing to the next track in the queue rather than leaving
    /// the player in a permanent failed state.
    private func advanceToNextOnFailure() {
        guard !queue.isEmpty, let currentTrackId,
              let currentIndex = queue.firstIndex(where: { $0.trackId == currentTrackId }) else {
            return
        }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            Task { @MainActor [weak self] in
                self?.playQueueItem(at: nextIndex)
            }
        }
    }

    func play() {
        guard currentItem != nil else { return }

        ensureAudioSessionActive()

        if let trackId = currentTrackId,
           let localURL = resolveLocalFileURL(trackId: trackId),
           localURL != currentItemURL {
            let generation = beginNewPlayAttempt()
            loadAndPlay(url: localURL, generation: generation)
            return
        }

        player.play()
    }

    /// Resets the activation flag so the next play triggers the full async
    /// route-picker activation flow again. Called after audio session
    /// deactivation events.
    func invalidateAudioSession() {
        isAudioSessionActivated = false
    }

    func stop() {
        // Supersede any in-flight load attempt so its eventual resolution
        // (a stale `await` continuation or KVO callback that cooperative
        // cancellation didn't silence) cannot resurrect state after stop.
        _ = beginNewPlayAttempt()

        wasPlayingBeforeInterruption = false
        player.pause()
        tearDownObservers()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentItemURL = nil
        currentTrackId = nil
        currentServerURL = nil
        currentAccessToken = nil
        currentQueueItem = nil
        queue = []
        originalQueue = []
        isShuffleEnabled = false
        currentState = .idle
    }

    func pause() {
        wasPlayingBeforeInterruption = false
        player.pause()
    }

    func togglePlayPause() {
        if currentState == .playing {
            pause()
        } else if case .failed = currentState, currentItem == nil,
                  let trackId = currentTrackId,
                  let serverURL = currentServerURL,
                  let accessToken = currentAccessToken {
            isAudioSessionActivated = false
            play(trackId: trackId, serverURL: serverURL, accessToken: accessToken, preferDirectPlay: currentPreferDirectPlay)
        } else {
            play()
        }
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return seconds
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

    func advanceToNext() {
        guard !queue.isEmpty, let currentTrackId else { return }
        guard let currentIndex = queue.firstIndex(where: { $0.trackId == currentTrackId }) else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            playQueueItem(at: nextIndex)
        } else if !isShuffleEnabled {
            playQueueItem(at: 0)
        }
    }

    func returnToPrevious() {
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }

        guard !queue.isEmpty, let currentTrackId else { return }
        guard let currentIndex = queue.firstIndex(where: { $0.trackId == currentTrackId }) else { return }
        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            playQueueItem(at: previousIndex)
        } else if !isShuffleEnabled {
            playQueueItem(at: queue.count - 1)
        }
    }

    func setQueue(_ items: [QueueItem], startingAt startTrackId: String? = nil) {
        originalQueue = items
        if isShuffleEnabled {
            queue = shuffled(items, pinningTrackId: startTrackId ?? items.first?.trackId)
        } else {
            queue = items
        }
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            queue = shuffled(originalQueue, pinningTrackId: currentTrackId)
        } else {
            queue = originalQueue
        }
    }

    private func shuffled(_ items: [QueueItem], pinningTrackId: String?) -> [QueueItem] {
        guard items.count > 1 else { return items }
        var result = items.shuffled()
        if let pinId = pinningTrackId,
           let pinIndex = result.firstIndex(where: { $0.trackId == pinId }),
           pinIndex != 0 {
            result.swapAt(0, pinIndex)
        }
        return result
    }

    private func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]
        currentQueueItem = item
        play(
            trackId: item.trackId,
            serverURL: item.serverURL,
            accessToken: item.accessToken
        )
        onQueueItemChanged?(item)
    }

    @ObservationIgnored
    var onQueueItemChanged: ((QueueItem) -> Void)?

    func playLocalFile(url: URL, trackId: String) {
        let generation = beginNewPlayAttempt()

        currentState = .loadingItem(trackId: trackId)
        currentTrackId = trackId
        currentServerURL = ""
        currentAccessToken = ""
        currentPreferDirectPlay = false

        if let item = queue.first(where: { $0.trackId == trackId }) {
            currentQueueItem = item
        }

        activeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isAudioSessionActivated {
                let activated = await self.activateAudioSession()
                guard self.isCurrent(generation) else { return }
                if !activated {
                    self.currentState = .failed(message: "Connect headphones to play audio.")
                    return
                }
            }
            guard self.isCurrent(generation) else { return }
            await self.loadAndPlayAsync(url: url, generation: generation)
        }
    }

    // MARK: - Interruption-driven pause/resume

    private func pauseForInterruption() {
        wasPlayingBeforeInterruption = (currentState == .playing)
        player.pause()
    }

    private func resumeIfWasPlaying() {
        guard wasPlayingBeforeInterruption else { return }
        wasPlayingBeforeInterruption = false
        ensureAudioSessionActive()
        player.play()
    }

    // MARK: - KVO + NotificationCenter wiring

    /// Attaches KVO/notification observers for `item`, all scoped to
    /// `generation` — the play attempt that loaded this item. Every handler
    /// re-checks `isCurrent(generation)` before mutating shared state, so an
    /// observer left firing from an abandoned attempt (cooperative
    /// cancellation does not silence KVO callbacks) is a guaranteed no-op
    /// rather than a race on whichever attempt's callback happens to land
    /// last.
    private func attachObservers(to item: AVPlayerItem, generation: Int) {
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] playerRef, _ in
            let status = playerRef.timeControlStatus
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatusChange(status, generation: generation)
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] itemRef, _ in
            let status = itemRef.status
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(status, generation: generation)
            }
        }

        didPlayToEndTimeToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidPlayToEndTime(generation: generation)
            }
        }

        failedToPlayToEndTimeToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let errorDescription = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleFailedToPlayToEndTime(errorDescription: errorDescription, generation: generation)
            }
        }
    }

    private func tearDownObservers() {
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        if let didPlayToEndTimeToken {
            NotificationCenter.default.removeObserver(didPlayToEndTimeToken)
            self.didPlayToEndTimeToken = nil
        }

        if let failedToPlayToEndTimeToken {
            NotificationCenter.default.removeObserver(failedToPlayToEndTimeToken)
            self.failedToPlayToEndTimeToken = nil
        }
    }

    private func registerInterruptionObserver() {
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    private func registerRouteChangeObserver() {
        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
    }

    // MARK: - Callback handlers

    private func handleTimeControlStatusChange(_ status: AVPlayer.TimeControlStatus, generation: Int) {
        guard isCurrent(generation) else { return }
        switch status {
        case .playing:
            currentState = .playing
        case .waitingToPlayAtSpecifiedRate:
            if currentState != .loadingItem(trackId: currentTrackId ?? "") {
                currentState = .buffering
            }
        case .paused:
            if case .readyToPlay = itemReadyState {
                currentState = .paused
            } else if case .playing = currentState {
                currentState = .paused
            }
        @unknown default:
            break
        }
    }

    private var itemReadyState: AVPlayerItem.Status {
        currentItem?.status ?? .unknown
    }

    private func handleItemStatusChange(_ status: AVPlayerItem.Status, generation: Int) {
        guard isCurrent(generation) else { return }
        switch status {
        case .readyToPlay:
            if currentState != .playing {
                currentState = .readyToPlay
            }
        case .failed:
            let message = currentItem?.error?.localizedDescription ?? "Playback failed."
            currentState = .failed(message: message)
            advanceToNextOnFailure()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleDidPlayToEndTime(generation: Int) {
        guard isCurrent(generation) else { return }
        if !queue.isEmpty, let currentTrackId,
           let currentIndex = queue.firstIndex(where: { $0.trackId == currentTrackId }) {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                playQueueItem(at: nextIndex)
            } else if isShuffleEnabled {
                queue = shuffled(originalQueue, pinningTrackId: nil)
                if !queue.isEmpty {
                    playQueueItem(at: 0)
                } else {
                    currentState = .finishedTrack
                }
            } else {
                playQueueItem(at: 0)
            }
        } else {
            currentState = .finishedTrack
        }
    }

    private func handleFailedToPlayToEndTime(errorDescription: String?, generation: Int) {
        guard isCurrent(generation) else { return }
        let message = errorDescription ?? "Playback failed before reaching the end of the track."
        currentState = .failed(message: message)
        advanceToNextOnFailure()
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            pauseForInterruption()
        case .ended:
            if let optionsValue,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                resumeIfWasPlaying()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            if currentState == .playing {
                pause()
            }
        }
    }
}
