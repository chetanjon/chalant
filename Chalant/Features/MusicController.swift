import AppKit
import Combine
import SwiftUI

@MainActor
final class MusicController: ObservableObject {
    /// Where the media is coming from. Spotify and Apple Music are
    /// scriptable (per-app volume, shuffle); anything else, a browser
    /// playing YouTube Music, a video player, arrives through the
    /// MediaRemote bridge and gets transport plus system volume.
    enum Source: Equatable {
        case spotify
        case appleMusic
        case system(bundleID: String, name: String)

        var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .appleMusic: return "Music"
            case .system(_, let name): return name
            }
        }

        var scriptable: MusicApp? {
            switch self {
            case .spotify: return .spotify
            case .appleMusic: return .appleMusic
            case .system: return nil
            }
        }
    }

    struct NowPlaying: Equatable {
        var source: Source
        var track: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var duration: Double
        /// App volume for scriptable sources, system volume otherwise.
        var volume: Double
        var shuffling: Bool
        var supportsShuffle: Bool
    }

    /// Playback position measured once per update; views project it
    /// forward locally so the scrubber glides instead of stepping.
    struct PositionAnchor {
        var position: Double
        var date: Date
    }

    enum MusicApp: String {
        case spotify = "Spotify"
        case appleMusic = "Music"

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }
    }

    /// The collapsed pill's playing signal. Quiet by default since
    /// 1.0.87: the breathing rim is the signal (R75's ruling), and a
    /// permanent animation is the loudest claim the closed pill can
    /// make on a stranger's attention; the wave is one switch away.
    /// Both @AppStorage sites share these so they can never diverge.
    static let playingSignalKey = "playingSignal"
    static let playingSignalDefault = "quiet"

    /// Published only when something meaningful changes (track, play
    /// state, volume, shuffle); position lives in the anchor so
    /// updates don't rebuild the whole row every tick.
    @Published var nowPlaying: NowPlaying?
    @Published var artwork: NSImage?
    /// Artwork-derived accent for the whole island; neutral when idle.
    @Published private(set) var accent: Color = Theme.accentFallback

    private(set) var positionAnchor: PositionAnchor?

    let bridge = MediaRemoteBridge()
    private var subscriptions = Set<AnyCancellable>()

    private var timer: Timer?
    private let separator = "|||"
    /// Track identity the current artwork belongs to, so art is only
    /// fetched when the song changes.
    private var artworkKey: String?
    /// After an optimistic command, updates started before it are
    /// stale; skip publishing them for a beat instead of flickering.
    private var suppressPollUntil = Date.distantPast

    /// Whether the expanded island is on screen. Volume and shuffle
    /// are only visible there, so the per-second AppleScript poll
    /// idles down to a slow heartbeat while the island is closed;
    /// the bridge still delivers track changes instantly either way.
    var expandedVisible = false {
        didSet {
            guard expandedVisible, !oldValue else { return }
            // Open with fresh numbers, not five-second-old ones.
            refreshTick(force: true)
        }
    }
    private var tick = 0

    /// One serial background lane for every AppleScript. Running them
    /// on the main thread stalls the UI for 50-200ms per call.
    private static let scriptQueue = DispatchQueue(label: "chalant.music.script", qos: .userInitiated)

    func start() {
        bridge.start()
        bridge.$state
            .sink { [weak self] state in
                Task { @MainActor in self?.applyBridge(state) }
            }
            .store(in: &subscriptions)
        refreshTick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTick() }
        }
    }

    /// App is quitting: stop the stream so no perl child outlives us.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        bridge.stop()
    }

    /// Where playback is right now, projected from the last update.
    func position(at date: Date = Date()) -> Double {
        guard let anchor = positionAnchor, let playing = nowPlaying else { return 0 }
        guard playing.isPlaying else { return anchor.position }
        let projected = anchor.position + date.timeIntervalSince(anchor.date)
        return playing.duration > 0 ? min(projected, playing.duration) : projected
    }

    // MARK: - Transport (optimistic: the UI flips now, updates confirm)

    func play() { setPlayback(true) }
    func pause() { setPlayback(false) }

    func playPause() {
        setPlayback(!(nowPlaying?.isPlaying ?? false))
    }

    private func setPlayback(_ playing: Bool) {
        guard let current = nowPlaying else { return }
        let position = position()
        nowPlaying?.isPlaying = playing
        positionAnchor = PositionAnchor(position: position, date: Date())
        holdPolls()
        if let app = current.source.scriptable {
            run("tell application \"\(app.rawValue)\" to \(playing ? "play" : "pause")") { [weak self] _ in
                self?.refreshTick(force: true)
            }
        } else {
            bridge.send(playing ? .play : .pause)
        }
    }

    func next() { skipTrack(forward: true) }
    func previous() { skipTrack(forward: false) }

    private func skipTrack(forward: Bool) {
        guard let current = nowPlaying else { return }
        positionAnchor = PositionAnchor(position: 0, date: Date())
        holdPolls()
        if let app = current.source.scriptable {
            let verb = forward ? "next track" : "previous track"
            run("tell application \"\(app.rawValue)\" to \(verb)") { [weak self] _ in
                self?.refreshTick(force: true)
            }
        } else {
            bridge.send(forward ? .next : .previous)
        }
    }

    func toggleShuffle() {
        guard let app = nowPlaying?.source.scriptable else { return }
        nowPlaying?.shuffling.toggle()
        holdPolls()
        let script = app == .spotify
            ? "tell application \"Spotify\" to set shuffling to not shuffling"
            : "tell application \"Music\" to set shuffle enabled to not shuffle enabled"
        run(script) { [weak self] _ in
            self?.refreshTick(force: true)
        }
    }

    func seek(to seconds: Double) {
        guard let current = nowPlaying else { return }
        positionAnchor = PositionAnchor(position: seconds, date: Date())
        holdPolls()
        if let app = current.source.scriptable {
            run("tell application \"\(app.rawValue)\" to set player position to \(Int(seconds))") { [weak self] _ in
                self?.refreshTick(force: true)
            }
        } else {
            bridge.seek(to: seconds)
        }
    }

    // MARK: - Volume (debounced: at most one script in flight per beat)

    private var pendingVolume: Double?
    private var volumeFlush: DispatchWorkItem?

    /// Live volume while the slider drags: sent at most every 120ms,
    /// always ending on the latest value.
    func previewVolume(_ volume: Double) {
        pendingVolume = volume
        guard volumeFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.volumeFlush = nil
            if let target = self.pendingVolume {
                self.pendingVolume = nil
                self.sendVolume(target)
            }
        }
        volumeFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The slider was released: land on this value exactly.
    func commitVolume(_ volume: Double) {
        volumeFlush?.cancel()
        volumeFlush = nil
        pendingVolume = nil
        sendVolume(volume)
    }

    func setVolume(_ volume: Double) {
        commitVolume(volume)
    }

    private func sendVolume(_ volume: Double) {
        guard let current = nowPlaying else { return }
        let clamped = max(0, min(100, volume))
        nowPlaying?.volume = clamped
        holdPolls()
        if let app = current.source.scriptable {
            run("tell application \"\(app.rawValue)\" to set sound volume to \(Int(clamped))")
        } else {
            SystemVolume.set(clamped)
        }
    }

    // MARK: - Quick access

    private let lastAppKey = "chalant.lastMusicApp"

    /// The app the quick-access chip would open right now: whatever is
    /// running, else whatever this Mac was actually seen playing.
    /// Mere installation is not evidence of use, so it names nothing;
    /// the chip hides instead of guessing someone's player.
    var preferredApp: MusicApp? {
        if let app = activeApp() { return app }
        if let raw = UserDefaults.standard.string(forKey: lastAppKey),
           let app = MusicApp(rawValue: raw), isInstalled(app) {
            return app
        }
        return nil
    }

    /// Open whatever is playing; idle, open the known player; with no
    /// evidence at all, the system's own player is the one safe guess.
    func openMusicApp() {
        if case .system(let bundleID, _) = nowPlaying?.source,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            return
        }
        let target = preferredApp ?? .appleMusic
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func isInstalled(_ app: MusicApp) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    /// Only talk to players that are already running. An AppleScript
    /// `tell` would otherwise launch the app, which nobody wants.
    private func activeApp() -> MusicApp? {
        let running = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
        if running.contains(MusicApp.spotify.bundleID) { return .spotify }
        if running.contains(MusicApp.appleMusic.bundleID) { return .appleMusic }
        return nil
    }

    // MARK: - Bridge updates (the truth when the adapter works)

    /// Trace of the last applyBridge decision, for `debug music`.
    private(set) var bridgeTrace = "never"
    /// AppleScript enrichments actually run, for `debug music`.
    private(set) var enrichCount = 0
    /// "bundleID|title" of the applied bridge state: an update naming
    /// a different song must never wait out the optimistic-command
    /// suppress window, that window exists for play-state flicker.
    private var appliedIdentity = ""

    private func applyBridge(_ state: MediaRemoteBridge.State?) {
        guard bridge.adapterAvailable else { bridgeTrace = "gate:adapter"; return }
        guard let state else {
            guard Date() >= suppressPollUntil else { bridgeTrace = "gate:suppress"; return }
            bridgeTrace = "cleared"
            clearNowPlaying()
            return
        }
        let identity = state.bundleIdentifier + "|" + state.title
        guard identity != appliedIdentity || Date() >= suppressPollUntil else {
            bridgeTrace = "gate:suppress"
            return
        }
        appliedIdentity = identity
        bridgeTrace = "applied:\(state.bundleIdentifier)"
        let source = resolveSource(state.bundleIdentifier, parent: state.parentBundleIdentifier)
        let sameSource = nowPlaying?.source == source
        let fresh = NowPlaying(
            source: source,
            track: state.title,
            artist: state.artist,
            album: state.album,
            isPlaying: state.playing,
            duration: state.duration,
            volume: sameSource ? (nowPlaying?.volume ?? 50) : seedVolume(for: source),
            shuffling: sameSource ? (nowPlaying?.shuffling ?? false) : false,
            supportsShuffle: source.scriptable != nil
        )
        positionAnchor = PositionAnchor(position: state.elapsed, date: state.timestamp)
        if fresh != nowPlaying {
            nowPlaying = fresh
            if let app = source.scriptable {
                UserDefaults.standard.set(app.rawValue, forKey: lastAppKey)
            }
        }
        applyBridgeArtwork(state)
    }

    /// Safari media arrives under its GPU helper's identifier with the
    /// real app in `parent`, so both are candidates. A user-facing app
    /// wins over a faceless helper ("Safari", never "Safari Graphics
    /// and Media"), and the winner is also what a tap opens.
    private func resolveSource(_ bundleID: String, parent: String?) -> Source {
        let candidates = [bundleID, parent].compactMap { $0 }
        for candidate in candidates {
            if candidate == MusicApp.spotify.bundleID { return .spotify }
            if candidate == MusicApp.appleMusic.bundleID { return .appleMusic }
        }
        let running = candidates.compactMap { candidate -> (String, NSRunningApplication)? in
            NSRunningApplication.runningApplications(withBundleIdentifier: candidate)
                .first.map { (candidate, $0) }
        }
        // Safari's GPU helper is an accessory named "Safari Graphics
        // and Media"; only a Dock-visible app outranks the raw sender.
        let best = running.first { $0.1.activationPolicy == .regular } ?? running.first
        if let (candidate, app) = best, let name = app.localizedName {
            return .system(bundleID: candidate, name: name)
        }
        let name = bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? "Media"
        return .system(bundleID: bundleID, name: name)
    }

    private func seedVolume(for source: Source) -> Double {
        switch source {
        case .system: return SystemVolume.level() ?? 50
        case .spotify, .appleMusic: return 50
        }
    }

    private func applyBridgeArtwork(_ state: MediaRemoteBridge.State) {
        let key = state.title + "|" + state.artist
        guard key != artworkKey else { return }
        if let data = state.artworkData, let image = NSImage(data: data) {
            artworkKey = key
            artwork = image
            updateAccent(from: image)
            return
        }
        // The diff named a new track but carried no art. The old
        // chalantr holds the frame (no placeholder flash) while a
        // snapshot races for the new one; the per-app script and the
        // catalog stay behind it as the slow road.
        artworkKey = key
        let scriptable = nowPlaying?.source.scriptable
        bridge.fetchArtworkSnapshot { [weak self] snapshotKey, data in
            guard let self, self.artworkKey == key else { return }
            if snapshotKey == key, let data, let image = NSImage(data: data) {
                self.artwork = image
                self.updateAccent(from: image)
            } else if let app = scriptable {
                self.fetchScriptedArtwork(app: app, key: key, title: state.title, artist: state.artist)
            } else {
                self.artwork = nil
                self.updateAccent(from: nil)
            }
        }
    }

    // MARK: - Poll (enrichment beside the bridge, full when it is gone)

    /// How many polls are still waiting on the script lane.
    ///
    /// The lane is serial and the tick is every second, but an
    /// AppleScript to a beachballing player, or one sitting behind an
    /// automation dialog, blocks for far longer than that. Every tick
    /// meanwhile queued another, so the backlog grew without limit and
    /// then drained all at once as a burst of answers about a track
    /// that had long since changed. Commands are never gated this way,
    /// only the poll: a dropped poll is corrected a second later, and a
    /// dropped "pause" is a bug.
    private var pollInFlight = false
    private var pollStartedAt = Date.distantPast

    private func refreshTick(force: Bool = false) {
        // A script that never comes back must only slow the polling,
        // never end it: without this the gate below would be a permanent
        // stop the first time a player wedged, which trades one bug for
        // a quieter one.
        if pollInFlight, Date().timeIntervalSince(pollStartedAt) > 10 {
            pollInFlight = false
        }
        guard force || !pollInFlight else { return }
        if bridge.adapterAvailable {
            enrichmentPoll(force: force)
        } else {
            legacyFullPoll(force: force)
        }
    }

    /// Wraps a poll's script so the gate above can see it finish.
    private func poll(_ source: String, then completion: @escaping @MainActor @Sendable (String?) -> Void) {
        pollInFlight = true
        pollStartedAt = Date()
        run(source) { [weak self] output in
            self?.pollInFlight = false
            completion(output)
        }
    }

    /// The bridge chalantrs what is playing; this only tops up what it
    /// cannot see: per-app volume and shuffle for scriptable players,
    /// the system volume for everything else.
    private func enrichmentPoll(force: Bool = false) {
        guard let current = nowPlaying else { return }
        tick += 1
        if let app = current.source.scriptable {
            // Nobody can see these numbers while the island is
            // closed; one AppleScript every five seconds keeps them
            // roughly honest without burning a script per second.
            guard force || expandedVisible || tick % 5 == 0 else { return }
            enrichCount += 1
            let shuffleExpr = app == .spotify ? "shuffling" : "shuffle enabled"
            let source = """
            tell application "\(app.rawValue)"
                try
                    set shuf to \(shuffleExpr)
                on error
                    set shuf to false
                end try
                return (sound volume as string) & "\(separator)" & (shuf as string)
            end tell
            """
            poll(source) { [weak self] output in
                guard let self, let output else { return }
                guard force || Date() >= self.suppressPollUntil else { return }
                let parts = output.components(separatedBy: self.separator)
                guard parts.count >= 2 else { return }
                var updated = self.nowPlaying
                updated?.volume = Self.number(parts[0])
                updated?.shuffling = parts[1] == "true"
                if let updated, updated != self.nowPlaying {
                    self.nowPlaying = updated
                }
            }
        } else {
            guard force || Date() >= suppressPollUntil else { return }
            if let level = SystemVolume.level(), var updated = nowPlaying,
               abs(level - updated.volume) >= 1 {
                updated.volume = level
                nowPlaying = updated
            }
        }
    }

    /// One reset path for every "there is nothing playing" branch.
    private func clearNowPlaying() {
        if nowPlaying != nil { nowPlaying = nil }
        positionAnchor = nil
        artwork = nil
        artworkKey = nil
        appliedIdentity = ""
        updateAccent(from: nil)
    }

    private func holdPolls() {
        suppressPollUntil = Date().addingTimeInterval(0.8)
    }

    /// The pre-bridge poller, kept whole as the fallback for a macOS
    /// that breaks the adapter: Spotify and Apple Music by AppleScript.
    private func legacyFullPoll(force: Bool = false) {
        guard let app = activeApp() else {
            clearNowPlaying()
            return
        }
        // Spotify reports duration in milliseconds, Music in seconds.
        let durationExpr = app == .spotify
            ? "(duration of current track) / 1000"
            : "duration of current track"
        let artExpr = app == .spotify
            ? "artwork url of current track"
            : "\"\""
        let shuffleExpr = app == .spotify
            ? "shuffling"
            : "shuffle enabled"
        let source = """
        tell application "\(app.rawValue)"
            if player state is playing then
                set s to "playing"
            else
                set s to "paused"
            end if
            try
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set dur to \(durationExpr)
                set art to \(artExpr)
            on error
                set t to ""
                set a to ""
                set al to ""
                set dur to 0
                set art to ""
            end try
            set pos to player position
            set vol to sound volume
            try
                set shuf to \(shuffleExpr)
            on error
                set shuf to false
            end try
            return s & "\(separator)" & t & "\(separator)" & a & "\(separator)" & al & "\(separator)" & pos & "\(separator)" & dur & "\(separator)" & vol & "\(separator)" & shuf & "\(separator)" & art
        end tell
        """
        poll(source) { [weak self] output in
            self?.applyLegacy(output, from: app, force: force)
        }
    }

    private func applyLegacy(_ output: String?, from app: MusicApp, force: Bool) {
        // A poll that started before the bridge came up can complete
        // after it; the bridge is the truth once available, so late
        // AppleScript results must not stomp it.
        guard !bridge.adapterAvailable else { return }
        guard force || Date() >= suppressPollUntil else { return }
        guard let output else {
            clearNowPlaying()
            return
        }
        let parts = output.components(separatedBy: separator)
        guard parts.count >= 9, !parts[1].isEmpty else {
            clearNowPlaying()
            return
        }
        let source: Source = app == .spotify ? .spotify : .appleMusic
        let fresh = NowPlaying(
            source: source,
            track: parts[1],
            artist: parts[2],
            album: parts[3],
            isPlaying: parts[0] == "playing",
            duration: Self.number(parts[5]),
            volume: Self.number(parts[6]),
            shuffling: parts[7] == "true",
            supportsShuffle: true
        )
        positionAnchor = PositionAnchor(position: Self.number(parts[4]), date: Date())
        if fresh != nowPlaying {
            nowPlaying = fresh
            UserDefaults.standard.set(app.rawValue, forKey: lastAppKey)
        }
        let key = parts[1] + "|" + parts[2]
        guard key != artworkKey else { return }
        if app == .spotify, let url = URL(string: parts[8]) {
            artworkKey = key
            downloadArtwork(from: url, key: key)
        } else {
            fetchScriptedArtwork(app: app, key: key, title: parts[1], artist: parts[2])
        }
    }

    // MARK: - Artwork

    /// Per-app artwork fetch, used when the bridge has no art or as
    /// part of the legacy poll.
    private func fetchScriptedArtwork(app: MusicApp, key: String, title: String, artist: String) {
        artworkKey = key
        switch app {
        case .spotify:
            run("tell application \"Spotify\" to artwork url of current track") { [weak self] output in
                guard let self, self.artworkKey == key else { return }
                guard let output, let url = URL(string: output) else {
                    self.artwork = nil
                    self.updateAccent(from: nil)
                    return
                }
                self.downloadArtwork(from: url, key: key)
            }
        case .appleMusic:
            let source = """
            tell application "Music"
                try
                    return data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
            """
            Self.scriptQueue.async { [weak self] in
                var error: NSDictionary?
                let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
                let data = (error == nil ? descriptor?.data : nil) ?? Data()
                let image = data.isEmpty ? nil : NSImage(data: data)
                Task { @MainActor in
                    guard let self, self.artworkKey == key else { return }
                    if let image {
                        self.artwork = image
                        self.updateAccent(from: image)
                    } else {
                        // Streaming tracks expose no artwork over
                        // AppleScript; the catalog usually has it.
                        self.fetchCatalogArtwork(title: title, artist: artist, key: key)
                    }
                }
            }
        }
    }

    /// Last resort for Apple Music: look the track up in the public
    /// iTunes catalog and take the album art from the match.
    private func fetchCatalogArtwork(title: String, artist: String, key: String) {
        let term = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { return }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (object["results"] as? [[String: Any]])?.first,
                  let raw = first["artworkUrl100"] as? String,
                  let artURL = URL(string: raw.replacingOccurrences(of: "100x100", with: "600x600"))
            else { return }
            await MainActor.run {
                guard let self, self.artworkKey == key, self.artwork == nil else { return }
                self.downloadArtwork(from: artURL, key: key)
            }
        }
    }

    private func downloadArtwork(from url: URL, key: String) {
        Task { [weak self] in
            let image = (try? await URLSession.shared.data(from: url))
                .flatMap { NSImage(data: $0.0) }
            await MainActor.run {
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
                self.updateAccent(from: image)
            }
        }
    }

    /// Extraction runs on a 24×24 downsample, once per track change,
    /// cheap enough to do inline where the artwork lands.
    private func updateAccent(from image: NSImage?) {
        let newValue = image.flatMap(AccentExtractor.accent(from:)) ?? Theme.accentFallback
        withAnimation(Theme.Motion.accent) {
            accent = newValue
        }
    }

    /// AppleScript renders reals with the locale's decimal separator.
    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Run a script on the background lane; the completion hops back
    /// to the main actor with the string result (nil on any error).
    private func run(_ source: String, then completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
        Self.scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let output = error == nil ? result?.stringValue : nil
            if let completion {
                Task { @MainActor in completion(output) }
            }
        }
    }
}
