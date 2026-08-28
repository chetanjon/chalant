import AppKit

/// The island's only conversation with the internet that the user did
/// not start: once a day it asks GitHub whether a newer release
/// exists. Nothing is sent but the request itself, it can be switched
/// off in Settings, and each new version nudges exactly once.
@MainActor
final class UpdateChecker: ObservableObject {
    static let settingKey = "updateCheckOn"
    static let downloadPage = URL(string: "https://github.com/chetanjon/chalant/releases/latest")!

    private let releasesAPI = URL(
        string: "https://api.github.com/repos/chetanjon/chalant/releases/latest"
    )!
    private let nudgedKey = "chalant.lastUpdateNudge"

    /// A newer version's number, when one exists; Settings shows it.
    @Published private(set) var latest: String?

    /// True while a check is on the wire; the row says "looking".
    @Published private(set) var checking = false
    /// When the last check ANSWERED (success only); the row tells the
    /// truth about staleness with it. Session-scoped on purpose: the
    /// row's section checks on open, so this is fresh whenever seen.
    @Published private(set) var lastChecked: Date?

    /// Fires once per new version, for the glance.
    var onNewVersion: ((String) -> Void)?

    private var timer: Timer?

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    func start() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await self?.check()
        }
        self.timer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: 24 * 3600, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 3600
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    /// One fetch for both the daily check and the "what's new" verb:
    /// the release JSON and its version, tag prefix already shed.
    private func fetchLatestRelease() async -> (version: String, json: [String: Any])? {
        var request = URLRequest(url: releasesAPI, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return (version, json)
    }

    /// The section's own ask: opening General re-checks, throttled so a
    /// user flipping between sections does not hammer anyone. Born
    /// 2026-08-28 ("the update row that answers when you look"): the
    /// daily timer cannot see a release published after it fired, and
    /// twice in one night that blindness hid a fresh release from the
    /// founder. Opening the page IS the ask, so the page asks.
    func sectionOpened() {
        guard Self.shouldCheck(onOpenAt: Date(), lastChecked: lastChecked) else { return }
        Task { [weak self] in await self?.check() }
    }

    /// The throttle, pure so a test can pin it: check when never
    /// checked, or when the last answer is older than two minutes.
    static func shouldCheck(onOpenAt now: Date, lastChecked: Date?) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) > 120
    }

    /// The row's staleness, in words a person says. Mono digits ride
    /// beside it in the row; this stays plain.
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "not yet" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// `pretendCurrent` lets Debug builds rehearse the stale path.
    func check(pretendCurrent: String? = nil) async {
        guard Self.enabled else { return }
        checking = true
        defer { checking = false }
        guard let (remote, _) = await fetchLatestRelease() else { return }
        lastChecked = Date()
        let current = pretendCurrent
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        guard Self.isNewer(remote, than: current) else {
            latest = nil
            return
        }
        latest = remote
        if UserDefaults.standard.string(forKey: nudgedKey) != remote {
            UserDefaults.standard.set(remote, forKey: nudgedKey)
            onNewVersion?(remote)
        }
    }

    /// The latest release's story, for the "what's new" verb: title
    /// and bullet notes, fetched on ask. Same endpoint as the daily
    /// check, so the network learns nothing it didn't already hear.
    func latestNotes() async -> String? {
        // Bounded by the shared fetch's 8s timeout: the caller holds
        // isWorking while awaiting, and isWorking gates input and
        // hover-collapse; an unanswered fetch must never wedge the
        // island (review-caught).
        guard let (remote, json) = await fetchLatestRelease() else { return nil }
        let title = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? remote
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let header = Self.isNewer(remote, than: current)
            ? "\(title) · you run \(current), the door is in Settings"
            : "\(title) · you're current"
        let bullets = (json["body"] as? String ?? "")
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { "· " + $0.dropFirst(2) }
        guard !bullets.isEmpty else { return header }
        return ([header] + bullets.prefix(6)).joined(separator: "\n")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
