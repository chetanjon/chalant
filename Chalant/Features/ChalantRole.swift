import Foundation

/// What Chalant is on this Mac: the founder's answer (2026-08-20, after
/// twice weighing a split into two apps) to "should dictation be its own
/// app". One binary, two faces. `both` is the app as it has always been;
/// `island` keeps the island and leaves hold-to-dictate off; `dictation`
/// hides the island entirely and keeps only dictation's own moments: the
/// strip while you talk, the sent light on release, a glance with something
/// to say, and nothing else to hover, press, or discover.
enum ChalantRole: String, CaseIterable {
    case dictation
    case island
    case both

    static let defaultsKey = "chalant.role"

    static var current: ChalantRole {
        current(in: .standard)
    }

    static func current(in defaults: UserDefaults) -> ChalantRole {
        defaults.string(forKey: defaultsKey).flatMap(ChalantRole.init(rawValue:)) ?? .both
    }

    static func set(_ role: ChalantRole, in defaults: UserDefaults = .standard) {
        defaults.set(role.rawValue, forKey: defaultsKey)
    }

    /// Whether a dictation-only island keeps itself hidden right now.
    ///
    /// Hidden is the rule; the exceptions are dictation's own moments and
    /// the things a hidden app still owes its user: the strip is up (not
    /// collapsed), the sent light is finishing, a glance line is speaking
    /// (the nowhere-to-type rescue lives there), or something genuinely
    /// wants them (an update, a crash notice). The pointer is deliberately
    /// NOT an exception: hovering cannot summon what the user chose not to
    /// have. Pure, so the rule is pinned by tests.
    static func islandHidden(
        collapsed: Bool, toastShowing: Bool, sentLightShowing: Bool, somethingWantsYou: Bool
    ) -> Bool {
        collapsed && !toastShowing && !sentLightShowing && !somethingWantsYou
    }
}
