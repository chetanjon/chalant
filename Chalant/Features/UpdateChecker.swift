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

    /// `pretendCurrent` lets Debug builds rehearse the stale path.
    func check(pretendCurrent: String? = nil) async {
        guard Self.enabled else { return }
        guard let (remote, _) = await fetchLatestRelease() else { return }
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
