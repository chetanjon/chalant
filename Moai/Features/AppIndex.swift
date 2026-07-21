import AppKit

/// Installed apps by name, so "open slack" launches the real thing
/// with zero configuration. A shallow scan of the usual folders,
/// cached and refreshed lazily; deterministic and offline like every
/// other verb.
@MainActor
final class AppIndex {
    static let shared = AppIndex()

    private struct Entry {
        let name: String
        let url: URL
    }

    private var apps: [Entry] = []
    private var scannedAt = Date.distantPast

    /// The app bundle best matching spoken words: exact name, then
    /// prefix, then contains. Shorter names win ties so "music" finds
    /// Music, not Amazon Music.
    func lookup(_ raw: String) -> URL? {
        refreshIfStale()
        let query = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        if let exact = apps.first(where: { $0.name == query }) { return exact.url }
        if let prefix = apps.first(where: { $0.name.hasPrefix(query) }) { return prefix.url }
        return apps.first { $0.name.contains(query) }?.url
    }

    private func refreshIfStale() {
        guard Date().timeIntervalSince(scannedAt) > 300 else { return }
        scannedAt = Date()
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            ("~/Applications" as NSString).expandingTildeInPath,
        ]
        var found: [Entry] = []
        for root in roots {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil
            )) ?? []
            for item in items where item.pathExtension == "app" {
                found.append(Entry(
                    name: item.deletingPathExtension().lastPathComponent.lowercased(),
                    url: item
                ))
            }
        }
        apps = found.sorted { $0.name.count < $1.name.count }
    }
}
