import Foundation

/// Whether just-inserted text may be replaced by its tidied version.
///
/// **Instant, then tidied in place (spec 2026-08-17).** The words land the
/// moment the key comes up, exactly as said; the on-device model takes about a
/// second more, and when it returns the raw text is swapped for the tidied one
/// by undoing the paste and pasting again. That is only ever an upgrade to
/// text that was already correct, so every doubt says keep:
///
/// - the tidied text is the same (nothing to gain);
/// - the insert did not land by pasting (there is no paste to undo);
/// - the user typed or clicked since (their document is theirs again);
/// - focus moved (the undo would land somewhere else);
/// - too long has passed (a document changing under someone who has moved on
///   is worse than a stray "um");
/// - the app has no undo for a paste (a terminal), where ⌘Z does nothing and
///   the second paste would double the text.
///
/// Pure, so every condition is pinned by a test and the reason for a keep is
/// one loggable word.
public enum SwapPolicy {

    public struct Situation: Sendable {
        public var inserted: String
        public var tidied: String
        public var outcome: InsertionOutcome
        public var userActedSinceInsert: Bool
        public var frontIsStillTarget: Bool
        public var secondsSinceInsert: TimeInterval
        public var bundleID: String?

        public init(
            inserted: String, tidied: String, outcome: InsertionOutcome, userActedSinceInsert: Bool,
            frontIsStillTarget: Bool, secondsSinceInsert: TimeInterval, bundleID: String?
        ) {
            self.inserted = inserted
            self.tidied = tidied
            self.outcome = outcome
            self.userActedSinceInsert = userActedSinceInsert
            self.frontIsStillTarget = frontIsStillTarget
            self.secondsSinceInsert = secondsSinceInsert
            self.bundleID = bundleID
        }
    }

    public enum KeepReason: String, Sendable, CaseIterable {
        case unchanged
        case notPasted
        case userActed
        case focusMoved
        case tooLate
        case noUndoHere
    }

    public enum Decision: Sendable, Equatable {
        case swap
        case keep(KeepReason)
    }

    /// After this long the user has moved on. Measured cleanup p95 is ~2 s, so
    /// an honest result arrives well inside it; anything later is a hung
    /// request, not a slow one.
    public static let maximumDelay: TimeInterval = 4

    /// Apps where ⌘Z may not be "undo the last paste". Terminals: undo does
    /// nothing or something else, and a second ⌘V doubles the text. And the
    /// editors that carry a terminal inside them (VS Code, Cursor, Zed): the
    /// founder dictates into the Claude Code prompt in VS Code's terminal
    /// panel, Electron exposes nothing through Accessibility to tell that panel
    /// from the editor, and doubling their text there is the one outcome this
    /// whole design must never produce. Their editor buffers lose the swap for
    /// it; the raw text there is still right.
    public static let noUndoBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
    ]

    public static func decide(_ s: Situation) -> Decision {
        let before = s.inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = s.tidied.trimmingCharacters(in: .whitespacesAndNewlines)
        if after.isEmpty || after == before { return .keep(.unchanged) }
        guard case .inserted(let tier) = s.outcome, tier != .clipboardOnly else { return .keep(.notPasted) }
        if s.userActedSinceInsert { return .keep(.userActed) }
        if !s.frontIsStillTarget { return .keep(.focusMoved) }
        if s.secondsSinceInsert > maximumDelay { return .keep(.tooLate) }
        guard let bundleID = s.bundleID, !noUndoBundleIDs.contains(bundleID) else { return .keep(.noUndoHere) }
        return .swap
    }
}
