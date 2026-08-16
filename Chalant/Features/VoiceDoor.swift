import Foundation

/// Every door onto voice, and which ones an install actually has.
///
/// This exists because 1.12.3 shipped with none of the visible ones, and
/// nothing in the codebase was in a position to notice.
///
/// The media-row mic went on 2026-08-02 (H1, founder: "not needed near
/// the spotify"), and that was right: the `.talk` hotkey, the collapsed
/// island's long-press and the session card's own mic all still stood,
/// which is exactly what `ExpandedView.swift` says where the mic used to
/// be. Then the 2026-08-09 dark-ship hid the sessions surface, and took
/// the last mic anyone could see with it. Two sound decisions a week
/// apart, neither able to see the other, because "how does a person
/// start voice" was written down nowhere: it lived scattered across a
/// view, a hotkey table and a feature flag. Meanwhile the welcome tour
/// went on telling every new user to tap a mic that was no longer drawn.
///
/// So it is written down here, once, and the tour reads its copy off it.
enum VoiceDoor: CaseIterable {
    /// The mic in the switcher row (`TabRow.swift`), beside the gear.
    /// Drawn on every tab, because that row is required in every
    /// layout, and drawn always rather than conditionally: voice can
    /// always act.
    case switcherMic
    /// The mic inside an agent session's compose card
    /// (`SessionCards.swift`), which the dark-ship currently hides.
    case sessionCardMic
    /// Press and hold the collapsed island for `pressToTalkDelay`.
    case holdTheIsland
    /// The global `.talk` key, which ships bound to nothing.
    case talkHotkey
    /// Hold left Option anywhere and speak, and the words land in whatever
    /// app you were already typing in. Added by the dictation merge, and it
    /// is a different job from every door above: those turn speech into
    /// island commands, this one turns speech into text at your cursor.
    /// Present only on macOS 26, because `SpeechTranscriber` has no backport.
    case dictationHold

    /// A control you can see and click, as against knowledge somebody
    /// had to give you. A build with none of these has no voice at all
    /// as far as the person who just downloaded it is concerned, which
    /// is the whole of the 1.12.3 bug.
    var isVisibleControl: Bool {
        switch self {
        case .switcherMic, .sessionCardMic: return true
        case .holdTheIsland, .talkHotkey, .dictationHold: return false
        }
    }

    /// Whether the switcher row draws its mic. A constant, because a
    /// SwiftUI placement cannot be asked at runtime; it is pinned by
    /// test the way the dark-ship is, and `Switcher` in `TabRow.swift`
    /// is the one place that has to move with it.
    static let switcherDrawsMic = true

    /// The doors this install actually has. `hotkeyBound` comes from
    /// `HotKeyCenter.combo(for: .talk)`, which is nil on a fresh install:
    /// nothing anywhere registers a default binding. `dictationAvailable`
    /// comes from the OS version, because `SpeechTranscriber` is macOS 26
    /// only; it deliberately has no default value, so a new caller has to
    /// say which build it is asking about rather than silently getting the
    /// answer for a machine that cannot dictate.
    static func shipped(hotkeyBound: Bool, dictationAvailable: Bool) -> Set<VoiceDoor> {
        var doors: Set<VoiceDoor> = [.holdTheIsland]
        if switcherDrawsMic { doors.insert(.switcherMic) }
        if FeatureFlags.sessionsVisible { doors.insert(.sessionCardMic) }
        if hotkeyBound { doors.insert(.talkHotkey) }
        if dictationAvailable { doors.insert(.dictationHold) }
        return doors
    }

    /// True when somebody who has just installed can find voice without
    /// being told a gesture first.
    ///
    /// Dictation cannot rescue this and is not asked to: it is a hold with
    /// nothing drawn, which is the same shape as the gesture that left
    /// 1.12.3 looking mic-less. It is counted as a door, never as an answer
    /// to "can a new user see how to start".
    static func hasVisibleControl(hotkeyBound: Bool, dictationAvailable: Bool) -> Bool {
        shipped(hotkeyBound: hotkeyBound, dictationAvailable: dictationAvailable)
            .contains { $0.isVisibleControl }
    }

    /// What a user must be told before hold-to-dictate exists for them, or
    /// nil when this build cannot dictate at all.
    ///
    /// The 1.12.3 lesson applies with full force here: a hold that nothing
    /// on screen mentions is not a door a person can find. If dictation
    /// ships, some surface has to say this sentence.
    static func dictationLine(available: Bool) -> String? {
        available ? "Hold left Option anywhere and talk. Your words land where you were typing." : nil
    }

    /// What ends a live session, in the words the listening caption
    /// uses. Lives here beside the doors because it is a fact about the
    /// door you came in by: only the island's long-press is a hold, and
    /// only a hold ends by letting go. Everything else was a click and
    /// ends with another one, anywhere on the listening surface.
    static func finishHint(held: Bool) -> String {
        held ? "RELEASE TO RUN" : "TAP TO RUN"
    }

    /// What the welcome tour may say about starting voice. A new install
    /// has no hotkey, so the promise is judged against that install and
    /// no other. The tour must never name a control the build withholds.
    /// Judged with `dictationAvailable: false` on purpose. The tour is about
    /// finding voice with your eyes, and dictation adds no visible control,
    /// so letting it into this answer could only ever mask a missing mic.
    static var welcomeLine: String {
        hasVisibleControl(hotkeyBound: false, dictationAvailable: false)
            ? "Tap the mic and talk, or just type in the bar."
            : "Hold the island and talk, or just type in the bar."
    }
}
