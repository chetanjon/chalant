import AppKit
import Foundation
import os

/// What the island looks like on one particular screen.
///
/// `@AppStorage` cannot hold this: it needs a literal key written at the
/// declaration, and there is one value per display attached to the Mac.
/// So the whole map is a single JSON blob under one key and every
/// surface reads through this store instead.
@MainActor
final class DisplayConfigStore: ObservableObject {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "displays")

    /// The shape the island takes on a screen.
    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Follow the hardware: wrap a real notch, and give a screen
        /// that has none a pill instead. The default, and the reason
        /// nothing needs configuring to look right.
        case auto
        /// Wrap a notch, real or emulated. Chosen explicitly this keeps
        /// the notch cutout on a screen that has no hardware notch,
        /// which is what a matching external panel wants.
        case notch
        /// A free-floating rounded bar. Nothing to clear, so content
        /// runs edge to edge and the eaves flatten out.
        case pill
        /// No island on this screen at all.
        case off

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .notch: return "Notch"
            case .pill: return "Pill"
            case .off: return "Off"
            }
        }
    }

    /// Everything tunable per screen. Defaults reproduce exactly what
    /// the island did before this existed, so an untouched install and
    /// an unknown display look the same as they always have.
    struct Config: Equatable, Codable {
        var style: Style = .auto
        /// Emulated notch size. Ignored where the hardware reports its
        /// own — a real notch's dimensions are not ours to invent.
        var width: CGFloat = 196
        var height: CGFloat = 34
        /// The island's bottom corners when collapsed.
        var cornerRadius: CGFloat = 16
        /// Breathing room down each side of the expanded island.
        var contentPadding: CGFloat = 16

        /// Bounds that keep a slider (or a hand-edited defaults blob)
        /// from producing a shape that cannot be seen or dismissed.
        static let widthRange: ClosedRange<CGFloat> = 120...420
        static let heightRange: ClosedRange<CGFloat> = 20...60
        static let cornerRange: ClosedRange<CGFloat> = 0...32
        static let paddingRange: ClosedRange<CGFloat> = 8...36

        /// Applied on read as well as on write: a value that arrived
        /// from disk has not been through the UI and cannot be trusted
        /// to be in range.
        var clamped: Config {
            var copy = self
            copy.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            copy.height = min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
            copy.cornerRadius = min(
                max(cornerRadius, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
            copy.contentPadding = min(
                max(contentPadding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
            return copy
        }
    }

    private static let defaultsKey = "displayConfigs"

    @Published private(set) var configs: [String: Config] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Identity

    /// Settings are filed under the display's UUID, not its
    /// `CGDirectDisplayID`.
    ///
    /// The id is a live handle: it changes across a reboot and across
    /// unplugging and replugging the same monitor, so anything stored
    /// against it silently attaches itself to a different screen later.
    /// The UUID survives both. The id stays the way to find a screen
    /// right now, and nothing more.
    static func key(for screen: NSScreen) -> String? {
        guard let id = screen.displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Set by the window controller so a slider moving in settings
    /// re-lays the island out immediately. Without it a change would
    /// sit in the store until the next display event and read as the
    /// control doing nothing.
    var onChange: (() -> Void)?

    // MARK: Reading

    func config(for screen: NSScreen) -> Config {
        config(forKey: Self.key(for: screen))
    }

    /// Key-based access, because settings UI must not hold `NSScreen`:
    /// AppKit recreates those objects at will, and a held one goes
    /// stale silently.
    func config(forKey key: String?) -> Config {
        (key.flatMap { configs[$0] } ?? Config()).clamped
    }

    /// Turns `.auto` into the concrete shape a screen should wear. This
    /// is the whole of "detect the display and pick the right notch":
    /// hardware that reports a safe-area inset has a real notch to wrap,
    /// and everything else gets a pill.
    static func resolve(_ style: Style, hasHardwareNotch: Bool) -> Style {
        guard style == .auto else { return style }
        return hasHardwareNotch ? .notch : .pill
    }

    func resolvedStyle(for screen: NSScreen) -> Style {
        Self.resolve(config(for: screen).style, hasHardwareNotch: screen.safeAreaInsets.top > 0)
    }

    // MARK: Writing

    func set(_ config: Config, for screen: NSScreen) {
        set(config, forKey: Self.key(for: screen))
    }

    func set(_ config: Config, forKey key: String?) {
        guard let key else {
            Self.log.error("display has no stable UUID; settings for it cannot be kept")
            return
        }
        configs[key] = config.clamped
        save()
        onChange?()
    }

    /// Forgets one screen's settings, so it goes back to following the
    /// hardware.
    func reset(for screen: NSScreen) {
        reset(forKey: Self.key(for: screen))
    }

    func reset(forKey key: String?) {
        guard let key else { return }
        configs[key] = nil
        save()
        onChange?()
    }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            configs = try JSONDecoder().decode([String: Config].self, from: data)
        } catch {
            // A blob that will not decode is a blob that would keep
            // failing every launch. Dropping it costs the user their
            // per-display tweaks once; keeping it would mean the island
            // never reads its settings again.
            Self.log.error(
                "display settings could not be read, starting fresh: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(configs), forKey: Self.defaultsKey)
        } catch {
            Self.log.error(
                "display settings could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
