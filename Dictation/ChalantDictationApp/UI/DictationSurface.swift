import CoreGraphics
import Foundation

/// What dictation needs from whatever shows that it is listening.
///
/// Dictation used to draw its own floating `ListeningPanel`. It now lights up
/// Chalant's island instead, but `Dictation/` must not import the app's view
/// model, so this is the seam: three calls, matching the three the panel had.
/// Ungated, because there is nothing macOS-26 about it.
@MainActor
protocol DictationSurface: AnyObject {
    /// The key went down. `display` is where the target app is showing, or
    /// nil to let the surface choose.
    func show(into appName: String, mic: String?, on display: CGDirectDisplayID?)
    /// On the meter timer while the key is held. `level` is raw peak.
    func update(level: CGFloat, mic: String?)
    /// The key came up, or the session stood down.
    func hide()
}

/// How the controller asks which display a pid is showing on, without the
/// package knowing how the app answers. Set once at launch by the app.
@MainActor
protocol DictationDisplayLookup: AnyObject {
    func displayShowing(pid: pid_t) -> CGDirectDisplayID?
}

extension DictationDisplayLookup {
    /// The app installs its implementation here. Nil in tests and before
    /// launch finishes, in which case the surface picks a display itself.
    ///
    /// A computed property over a private `@MainActor` global, not the
    /// `nonisolated(unsafe) static var` this started as: Swift 6 rejects a
    /// stored static property in a protocol extension outright ("static
    /// stored properties not supported in protocol extensions"), so there
    /// was never a live choice here between that and a safer alternative.
    /// Every caller is already on the main actor (the controller is
    /// `@MainActor`, and Task 6's assignment happens at app launch on the
    /// main actor too), so the isolation costs nothing.
    @MainActor static var shared: (any DictationDisplayLookup)? {
        get { _dictationDisplayLookup }
        set { _dictationDisplayLookup = newValue }
    }
}
@MainActor private var _dictationDisplayLookup: (any DictationDisplayLookup)?

/// `DictationController` only ever holds `any DictationDisplayLookup`, and
/// Swift refuses to resolve a protocol extension's static member through the
/// bare existential type: `DictationDisplayLookup.shared` does not compile
/// ("static member 'shared' cannot be used on protocol metatype"), for any
/// shape of `shared`, stored or computed, extension default or protocol
/// requirement. Only a concrete conforming type can reach it, which is
/// exactly how Task 6 writes it (`IslandDictationSurface.shared = surface`).
/// This reads the same backing variable for the one caller that cannot get
/// there that way.
@MainActor var installedDictationDisplayLookup: (any DictationDisplayLookup)? { _dictationDisplayLookup }
