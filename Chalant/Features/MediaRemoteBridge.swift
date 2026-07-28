import AppKit
import Foundation

/// System-wide now-playing via the vendored mediaremote-adapter
/// (BSD 3-Clause, github.com/ungive/mediaremote-adapter). Apple locked
/// MediaRemote behind an entitlement in macOS 15.4; the adapter has
/// /usr/bin/perl, an Apple-signed binary that still holds it, load a
/// helper framework and stream JSON updates for whatever is playing,
/// browsers included.
@MainActor
final class MediaRemoteBridge: ObservableObject {
    struct State: Equatable {
        var bundleIdentifier: String
        /// Safari publishes media from its GPU helper
        /// (com.apple.WebKit.GPU); this carries the app that actually
        /// owns the page so the UI can name and open the right thing.
        var parentBundleIdentifier: String?
        var title: String
        var artist: String
        var album: String
        var playing: Bool
        var duration: Double
        /// Seconds into the track, sampled at `timestamp`.
        var elapsed: Double
        var timestamp: Date
        var artworkData: Data?
    }

    /// Send-command ids, from the adapter's documented table.
    enum Command: Int {
        case play = 0
        case pause = 1
        case toggle = 2
        case next = 4
        case previous = 5
        case toggleShuffle = 6
    }

    @Published private(set) var state: State?
    @Published private(set) var adapterAvailable = false
    /// Last artwork-snapshot outcome, for `debug music`.
    var snapshotTrace = "never"

    private var stream: Process?
    /// Held so stop() can take the readability handler off the pipe;
    /// the termination handler cannot, because stop() removes it first.
    private var streamOutput: Pipe?
    private var stopped = false
    private var restartDelay: TimeInterval = 2
    private var lastSpawn = Date.distantPast
    private var buffer = Data()
    /// The merged payload across diff updates.
    private var merged: [String: Any] = [:]
    /// One-shot command processes held until reaped.
    private var oneShots: Set<Process> = []

    private static let isoParser: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    private var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("MediaRemoteAdapter.framework")
    }

    private var testClientURL: URL? {
        Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)
    }

    func start() {
        guard let script = scriptURL else { return }
        stopped = false
        // A previous instance killed without a graceful quit leaves its
        // stream orphaned until the next pipe write. Reap anything
        // still running our bundled script, and only probe once the
        // reaper has finished so it can never catch our own processes.
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reaper.arguments = ["-f", script.path]
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        reaper.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.runProbe() }
        }
        do {
            try reaper.run()
        } catch {
            runProbe()
        }
    }

    /// Gate on the adapter's own self-test: exit 0 means the perl
    /// route works on this macOS. Anything else leaves the bridge
    /// off and the AppleScript path carries on alone.
    private func runProbe() {
        guard !stopped, let script = scriptURL, let framework = frameworkURL else { return }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        var arguments = [script.path, framework.path]
        if let client = testClientURL {
            arguments.append(client.path)
        }
        arguments.append("test")
        probe.arguments = arguments
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        probe.terminationHandler = { [weak self] process in
            let ok = process.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                self.adapterAvailable = ok
                if ok { self.spawnStream() }
            }
        }
        do {
            try probe.run()
        } catch {
            adapterAvailable = false
        }
    }

    func stop() {
        stopped = true
        stream?.terminationHandler = nil
        // That handler was the only place the readability handler ever
        // came off, and it has just been removed. Left installed, the
        // handle hits EOF and the readability source fires again and
        // again on empty data: the classic FileHandle spin.
        streamOutput?.fileHandleForReading.readabilityHandler = nil
        streamOutput = nil
        stream?.terminate()
        stream = nil
    }

    func send(_ command: Command) {
        oneShot(["send", String(command.rawValue)])
    }

    func seek(to seconds: Double) {
        oneShot(["seek", String(Int(seconds * 1_000_000))])
    }

    // MARK: - Stream

    private func spawnStream() {
        guard !stopped, stream == nil,
              let script = scriptURL, let framework = frameworkURL else { return }
        lastSpawn = Date()
        buffer.removeAll()
        merged.removeAll()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // 80ms batches the artwork bursts without making a track
        // change feel like the island heard it second-hand.
        process.arguments = [script.path, framework.path, "stream", "--debounce=80"]

        let out = Pipe()
        process.standardOutput = out
        streamOutput = out
        // Drained so perl can never block on a full stderr buffer.
        process.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.consume(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                self.streamOutput = nil
                self.stream = nil
                self.state = nil
                guard !self.stopped else { return }
                // Healthy uptime resets the backoff.
                if Date().timeIntervalSince(self.lastSpawn) > 60 {
                    self.restartDelay = 2
                }
                let delay = self.restartDelay
                self.restartDelay = min(self.restartDelay * 2, 30)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.spawnStream()
                }
            }
        }

        do {
            try process.run()
            stream = process
        } catch {
            adapterAvailable = false
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let update = object as? [String: Any] else { continue }
            apply(update)
        }
    }

    private func apply(_ update: [String: Any]) {
        guard update["type"] as? String == "data" || update["payload"] != nil else { return }
        let isDiff = update["diff"] as? Bool ?? false
        guard let payload = update["payload"] as? [String: Any] else {
            // A null payload means the session is gone.
            merged.removeAll()
            if state != nil { state = nil }
            return
        }
        if isDiff {
            for (key, value) in payload {
                if value is NSNull {
                    merged.removeValue(forKey: key)
                } else {
                    merged[key] = value
                }
            }
        } else {
            merged = payload.filter { !($0.value is NSNull) }
        }
        publish()
    }

    private func publish() {
        guard let bundleID = merged["bundleIdentifier"] as? String,
              let title = merged["title"] as? String, !title.isEmpty else {
            if state != nil { state = nil }
            return
        }
        let timestamp = (merged["timestamp"] as? String)
            .flatMap { Self.isoParser.date(from: $0) } ?? Date()
        let artwork = (merged["artworkData"] as? String)
            .flatMap { Data(base64Encoded: $0) }
        let fresh = State(
            bundleIdentifier: bundleID,
            parentBundleIdentifier: merged["parentApplicationBundleIdentifier"] as? String,
            title: title,
            artist: merged["artist"] as? String ?? "",
            album: merged["album"] as? String ?? "",
            playing: merged["playing"] as? Bool ?? false,
            duration: Self.number(merged["duration"]),
            elapsed: Self.number(merged["elapsedTime"]),
            timestamp: timestamp,
            artworkData: artwork
        )
        if fresh != state { state = fresh }
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    /// The stream's initial dump has no artwork (only change events
    /// carry it), so a launch mid-track needs one `get` to see the
    /// current chalantr. Calls back with "title|artist" and the data.
    func fetchArtworkSnapshot(completion: @escaping @MainActor @Sendable (String, Data?) -> Void) {
        guard adapterAvailable,
              let script = scriptURL, let framework = frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "get"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.oneShots.remove(finished)
            }
        }
        // Launched before the pipe is read, never after. Nothing but a
        // spawned child ever closes the write end, so a run() that
        // threw left the reader below waiting on an EOF that could not
        // come: one global-queue thread parked for the life of the app,
        // every time a launch failed.
        do {
            try process.run()
            oneShots.insert(process)
        } catch {
            // No snapshot, no harm; the next track change brings art.
            return
        }
        // And a perl that starts but never exits would park that thread
        // just as well. This runs on every track change that arrives
        // without artwork, which for browser media is most of them, so
        // the ceiling matters: take the EOF by force if it is late.
        // Nothing cancels this: it asks whether the child is still
        // running before acting, so arriving after a clean exit costs
        // one no-op. A cancellable work item would have to be captured
        // by the reader below, and DispatchWorkItem is not Sendable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        // Drained off-pipe before termination: the payload can far
        // exceed the 64KB pipe buffer, and a blocked writer never exits.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor in self?.snapshotTrace = "parse-fail:\(data.count)b" }
                return
            }
            let key = (object["title"] as? String ?? "") + "|" + (object["artist"] as? String ?? "")
            let art = (object["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
            Task { @MainActor in
                self?.snapshotTrace = "got:\(key):art=\(art?.count ?? 0)"
                completion(key, art)
            }
        }
    }

    // MARK: - One-shot commands

    private func oneShot(_ tail: [String]) {
        guard adapterAvailable,
              let script = scriptURL, let framework = frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + tail
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.oneShots.remove(finished)
            }
        }
        do {
            try process.run()
            oneShots.insert(process)
        } catch {
            // A missed command is harmless; the next poll re-syncs.
        }
    }
}
