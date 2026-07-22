import AppKit

/// Built-in one-tap actions, the genuinely useful ones. Each can live
/// on the Shortcuts grid next to apps and links.
enum SystemAction: String, CaseIterable, Codable {
    case screenshot
    case lockScreen
    case darkMode
    /// Legacy: still runs for grids that added it, no longer offered.
    /// Nobody wants to empty the trash from the notch (user call,
    /// 2026-07-21).
    case emptyTrash
    case keepAwake
    case muteToggle

    var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .lockScreen: return "Lock Screen"
        case .darkMode: return "Dark Mode"
        case .emptyTrash: return "Empty Trash"
        case .keepAwake: return "Keep Awake"
        case .muteToggle: return "Mute"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .lockScreen: return "lock.fill"
        case .darkMode: return "circle.lefthalf.filled"
        case .emptyTrash: return "trash"
        case .keepAwake: return "cup.and.saucer.fill"
        case .muteToggle: return "speaker.slash.fill"
        }
    }

    /// The caffeinate child while Keep Awake is on; nil when off.
    private static var caffeinate: Process?

    func run() {
        switch self {
        case .screenshot:
            // Interactive area capture straight to the clipboard; the
            // island has already slipped shut by the time this runs.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-ic"]
            try? capture.run()
        case .lockScreen:
            let sleep = Process()
            sleep.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            sleep.arguments = ["displaysleepnow"]
            try? sleep.run()
        case .darkMode:
            Self.runScript(
                "tell application \"System Events\" to tell appearance preferences"
                    + " to set dark mode to not dark mode"
            )
        case .emptyTrash:
            Self.runScript("tell application \"Finder\" to empty trash")
        case .keepAwake:
            // A tap holds the Mac awake, a second tap lets it rest.
            if let running = Self.caffeinate, running.isRunning {
                running.terminate()
                Self.caffeinate = nil
            } else {
                let awake = Process()
                awake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                awake.arguments = ["-di"]
                try? awake.run()
                Self.caffeinate = awake
            }
        case .muteToggle:
            Self.runScript(
                "set volume output muted not (output muted of (get volume settings))"
            )
        }
    }

    private static func runScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

/// User-defined quick links: websites, apps, folders, anything
/// NSWorkspace can open, plus built-in actions. Persisted as JSON
/// in UserDefaults.
@MainActor
final class ShortcutStore: ObservableObject {
    struct Shortcut: Identifiable, Codable, Equatable {
        var id = UUID()
        var title: String
        var link: String
        /// Set for built-in actions; `link` is empty then.
        var action: SystemAction?
    }

    @Published private(set) var shortcuts: [Shortcut] = [] {
        didSet { save() }
    }

    private let defaultsKey = "shortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Shortcut].self, from: data) {
            shortcuts = saved
        }
    }

    func add(title: String, link: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLink.isEmpty else { return }
        let name = cleanTitle.isEmpty ? Self.suggestedTitle(for: cleanLink) : cleanTitle
        shortcuts.append(Shortcut(title: name, link: cleanLink))
    }

    func add(action: SystemAction) {
        guard !shortcuts.contains(where: { $0.action == action }) else { return }
        shortcuts.append(Shortcut(title: action.title, link: "", action: action))
    }

    /// Actions not on the grid yet, offered by the add flow. Empty
    /// Trash stays runnable for grids that have it, but is no longer
    /// on the menu.
    var remainingActions: [SystemAction] {
        SystemAction.allCases.filter { action in
            action != .emptyTrash && !shortcuts.contains { $0.action == action }
        }
    }

    func remove(_ shortcut: Shortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
    }

    /// Bare app names ("notes", "figma") resolve like the spoken
    /// open verb does, so a shortcut a user types by name actually
    /// opens instead of failing as a non-URL.
    private let apps = AppIndex()

    @discardableResult
    func open(_ shortcut: Shortcut) -> Bool {
        if let action = shortcut.action {
            action.run()
            return true
        }
        if let url = Self.resolvedURL(for: shortcut.link),
           NSWorkspace.shared.open(url) {
            return true
        }
        let name = shortcut.link.isEmpty ? shortcut.title : shortcut.link
        if let appURL = apps.lookup(name) {
            return NSWorkspace.shared.open(appURL)
        }
        return false
    }

    /// First shortcut whose title matches the spoken/typed name.
    func match(_ name: String) -> Shortcut? {
        let query = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return shortcuts.first { $0.title.lowercased() == query }
            ?? shortcuts.first { $0.title.lowercased().contains(query) }
    }

    /// "github.com" → https URL; "/Applications/X.app" or "~/Docs" →
    /// file URL; full schemes pass through.
    static func resolvedURL(for raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        if let url = URL(string: text), url.scheme != nil {
            return url
        }
        guard text.contains(".") || text.contains(":") else { return nil }
        return URL(string: "https://" + text)
    }

    /// A real app/file icon for local links; nil for the web (the view
    /// draws a monogram instead).
    static func fileIcon(for link: String) -> NSImage? {
        guard let url = resolvedURL(for: link), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func suggestedTitle(for link: String) -> String {
        guard let url = resolvedURL(for: link) else { return link }
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        let host = url.host ?? link
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return stripped.split(separator: ".").first.map(String.init)?.capitalized ?? stripped
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
