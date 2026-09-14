import ChalantDictationCore
import Foundation

/// Where the hold key is remembered.
///
/// A thin store rather than a property on `DictationShortcut`, for the same
/// reason `Dictation.isEnabled(in:)` takes a seam: a test that reads
/// `UserDefaults.standard` edits the settings of the app the developer is
/// running. The decision itself is pure and lives in Core.
enum DictationShortcutStore {

    static let key = "dictationShortcut"

    static func current(in defaults: UserDefaults = .standard) -> DictationShortcut {
        guard let stored = defaults.string(forKey: key),
            let shortcut = DictationShortcut.from(storage: stored)
        else { return .default }
        return shortcut
    }

    static func set(_ shortcut: DictationShortcut, in defaults: UserDefaults = .standard) {
        defaults.set(shortcut.storage, forKey: key)
    }
}
