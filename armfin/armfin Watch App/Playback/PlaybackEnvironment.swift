import SwiftUI

private struct PlaybackEngineKey: EnvironmentKey {
    static let defaultValue = PlaybackEngine()
}

private struct NowPlayingManagerKey: EnvironmentKey {
    static let defaultValue = NowPlayingManager(playbackEngine: PlaybackEngineKey.defaultValue)
}

private struct ShowNowPlayingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NetworkStatusServiceKey: EnvironmentKey {
    static let defaultValue = NetworkStatusService()
}

private struct ShowDownloadsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var playbackEngine: PlaybackEngine {
        get { self[PlaybackEngineKey.self] }
        set { self[PlaybackEngineKey.self] = newValue }
    }

    var nowPlayingManager: NowPlayingManager {
        get { self[NowPlayingManagerKey.self] }
        set { self[NowPlayingManagerKey.self] = newValue }
    }

    var showNowPlaying: () -> Void {
        get { self[ShowNowPlayingKey.self] }
        set { self[ShowNowPlayingKey.self] = newValue }
    }

    var networkStatusService: NetworkStatusService {
        get { self[NetworkStatusServiceKey.self] }
        set { self[NetworkStatusServiceKey.self] = newValue }
    }

    /// Switches the active `HomeView` tab to Downloads. Mirrors
    /// `showNowPlaying`'s pattern — a closure injected by `HomeView` so
    /// nested browse views can trigger a tab switch without holding a
    /// reference to `HomeView`'s own `@State` selection.
    var showDownloads: () -> Void {
        get { self[ShowDownloadsKey.self] }
        set { self[ShowDownloadsKey.self] = newValue }
    }
}
