import AppKit
import os
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    /// State the island got itself stuck in. Nothing the user said or
    /// typed goes here, only the shape of the wedge.
    static let log = Logger(subsystem: "com.cj.chalant", category: "island")

    /// Observer tokens, kept so deinit can hand them back. A block
    /// observer is retained by its centre until the token returns.
    private var motionObserver: NSObjectProtocol?
    #if DEBUG
    private var debugObserver: NSObjectProtocol?
    #endif

    deinit {
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
        #if DEBUG
        if let debugObserver {
            DistributedNotificationCenter.default().removeObserver(debugObserver)
        }
        #endif
    }

    enum IslandState {
        case collapsed
        case listening
        case expanded
    }

    /// Raw-valued so "reopen where I left off" can survive a relaunch
    /// without a second parallel enum to keep in step.
    enum Tab: String, CaseIterable {
        case today
        case ask
        case clipboard
        case shelf
        case links
        case notes
        case focus
        case chat
        case sessions
        case battery

        /// The settings switch that hides this tab's tool, if it has
        /// one. `today` and `ask` are the island itself and cannot be
        /// switched off.
        var toolKey: String? {
            switch self {
            case .today, .ask: return nil
            case .clipboard: return "toolClips"
            case .shelf: return "toolShelf"
            case .links: return "toolGo"
            case .notes: return "toolNotes"
            case .focus: return "toolFocus"
            case .chat: return "toolChat"
            case .sessions: return "toolSessions"
            case .battery: return "toolBattery"
            }
        }
    }

    /// The welcome tour slides over the island body; collapsing closes
    /// it. Settings used to live here too and now has a window of its
    /// own — see Dashboard.swift.
    enum Pane {
        case none
        case welcome
    }

    /// Cleared to nil the instant this becomes `.collapsed` (see the
    /// `didSet` below), so a stale `expandedDisplayID` can never
    /// outlive the state it was opened for.
    @Published var state: IslandState = .collapsed {
        didSet {
            // One guard here beats a clear at every path that can
            // collapse (`collapse()`, `cancelListening()`, and any
            // future one): `expand(on:)`'s hand-off logic treats a
            // non-nil `expandedDisplayID` as "someone else is open,
            // collapse them first," and a stale id left behind by a
            // path that forgot to clear it would wedge every later
            // expand behind a hand-off to a display that was never
            // actually open (2026-08-02).
            if state == .collapsed { expandedDisplayID = nil }
        }
    }

    /// Which display's island is open, when one is.
    ///
    /// `state` stays one value because only one island can ever be
    /// open: there is one keyboard, one `WKWebView`
    /// (`ChatController.swift:96`) and one `VoiceController`. What was
    /// missing, once more than one display wears an island, was not a
    /// second state, it was WHICH display the one state applies to —
    /// without it, hovering one display expanded all of them, because
    /// every face read the same `state` (2026-08-02).
    @Published private(set) var expandedDisplayID: CGDirectDisplayID?

    /// Which display last reported hovering true, remembered after the
    /// hover itself ends: `defaultOwner` below falls back to it when
    /// there is nothing more specific — the pointer's own display — to
    /// go on (EC-12, 2026-08-02).
    @Published private(set) var lastHoveredDisplayID: CGDirectDisplayID?

    /// A display that vanished takes its last-hovered claim with it, so
    /// a stale id can never outrank a screen that still exists in
    /// `defaultOwner`'s fallback chain. The window controller calls
    /// this when a panel is torn down.
    func forgetHover(on display: CGDirectDisplayID) {
        if lastHoveredDisplayID == display { lastHoveredDisplayID = nil }
    }

    /// What a given face should render as. The one function that turns
    /// the shared `state` into a per-display one: a face reads
    /// `.collapsed` unless it IS the one display holding the
    /// expansion, however loud `shared` is (2026-08-02).
    static func state(
        _ shared: IslandState,
        expandedOn: CGDirectDisplayID?,
        face: CGDirectDisplayID?
    ) -> IslandState {
        guard let face, face == expandedOn else { return .collapsed }
        return shared
    }

    @Published var isHovering = false
    /// Which lower panel the switcher is showing. `.today` is home.
    @Published var tab: Tab = .today
    @Published var pane: Pane = .none

    /// The island's expanded size, measured from the content itself,
    /// the island hugs what's shown instead of reserving a fixed void.
    @Published var expandedSize = CGSize(width: 520, height: 170)

    /// The expanded island's width: the user's own dial, except while
    /// full chat is open, where the chat site's desktop breakpoint at
    /// 0.8 zoom needs 680 regardless of what the dial says (W-F,
    /// 2026-08-02). A floor under the dial there, never a ceiling on
    /// it: a wider dial than 680 still wins.
    ///
    /// Pulled out of `ExpandedView.islandWidth` so `expandedZone(on:)`
    /// can compute the identical number before any layout pass runs:
    /// a hover-out door sized from a stale, one-frame-late width could
    /// let the pointer fall outside it mid-drag and collapse the
    /// island out from under it (EC-11).
    static func expandedWidth(
        configWidth: CGFloat, tab: Tab, pane: Pane, chatFull: Bool
    ) -> CGFloat {
        tab == .chat && pane == .none && chatFull ? max(configWidth, 680) : configWidth
    }

    /// The expanded island's height: whatever the content measured,
    /// unless the user's own floor asks for more. Never the other way
    /// around, a ceiling here would clip the chat pane or the notes
    /// list with no scrollbar and no sign anything was cut (EC-10,
    /// W-F, 2026-08-02).
    static func expandedHeight(measured: CGFloat, floor: CGFloat) -> CGFloat {
        max(measured, floor)
    }

    /// The collapsed frame, in points. Flush with the cutout when
    /// there is nothing to say and nobody reaching: on a MacBook the
    /// cutout has no pixels, so an island exactly its size is eaten by
    /// the hardware and is invisible by construction, which is the
    /// whole of A2. The 8pt width tuck and the 3pt apron (founder,
    /// 2026-07-22) are kept for every state where the island is
    /// outside the hole anyway, and only for those: flush and apron
    /// cannot both be true at once (founder, 2026-08-02,
    /// notch-geometry-plan, W-C).
    ///
    /// `wings` is zero in exactly the states
    /// `collapsedHasSomethingToSay` is false in too, bar one: ambience
    /// alone, which draws with no wing width reserved for it either and
    /// so is already tucked out of sight today regardless of whether
    /// this frame is flush or -8. No second predicate is needed here
    /// (C24) — `wings == 0` already is the "nothing to say" test this
    /// frame cares about.
    static func collapsedFrame(
        cutout: CGSize?, base: CGSize, wings: CGFloat, hovering: Bool
    ) -> CGSize {
        if let cutout, wings == 0, !hovering {
            return cutout
        }
        let growW: CGFloat = hovering ? 14 : 0
        let growH: CGFloat = hovering ? 4 : 0
        return CGSize(
            width: base.width - 8 + wings + growW,
            height: base.height + 3 + growH
        )
    }

    /// The eave (meniscus flare) and belly (bottom sag) for the
    /// collapsed `.notch` silhouette, driven by how far the frame
    /// already overhangs the cutout rather than a fixed constant:
    /// flush has nothing to flare over, which is A3's arc gone too,
    /// and the shoulders grow back in step with whatever pushed the
    /// frame past the hole. `overhang <= 0` folds in the flush case;
    /// an emulated notch has no real cutout to measure an overhang
    /// against and never hides inside one (EC-5), so its caller passes
    /// a positive sentinel here instead of a computed overhang.
    static func eaveAndBelly(overhang: CGFloat) -> (eave: CGFloat, belly: CGFloat) {
        guard overhang > 0 else { return (0, 0) }
        return (min(Theme.Island.eaveCollapsed, overhang), Theme.Island.bellyCollapsed)
    }

    /// The size the collapsed island draws as its base, before any of
    /// the flush/grow arithmetic above runs: the hardware by default
    /// (A1), unless the user has explicitly turned "follow the
    /// hardware" off, in which case their own stored size wins.
    /// Pulled out of `NotchWindowController.apply(_:to:)` so the rule
    /// is checkable with no screen or face to build (W-D, EC-6): every
    /// blob written before `sizeFollowsHardware` existed decodes to
    /// `true`, which reproduces exactly today's behaviour on both a
    /// real notch (measured wins) and a screen with none (nothing to
    /// follow, the stored size wins regardless).
    static func notchSize(
        cutout: CGSize?, sizeFollowsHardware: Bool, configWidth: CGFloat, configHeight: CGFloat
    ) -> CGSize {
        (sizeFollowsHardware ? cutout : nil) ?? CGSize(width: configWidth, height: configHeight)
    }

    /// Debug builds show the drop bubble on request; the window
    /// controller owns the panel, so it hangs the hook here.
    var onDebugDropDock: (() -> Void)?

    /// Lets "debug droptarget" flash the same highlight a live drag
    /// would. `isDropTargeted` lives on `IslandFace` now, and
    /// `IslandFace` holds a reference back to the model, not the other
    /// way around, so this is the one way a debug command here can
    /// still reach it (2026-08-02).
    var debugSetDropTargeted: ((Bool) -> Void)?

    /// Which page of the first-run tour is showing.
    @Published var welcomeStep = 0

    private let onboardedKey = "chalant.onboarded"

    /// First launch only: the island introduces itself, once. Marked
    /// seen at show time; Settings offers a replay.
    func showWelcomeIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: onboardedKey) else { return }
        UserDefaults.standard.set(true, forKey: onboardedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.state == .collapsed else { return }
            self.welcomeStep = 0
            self.pane = .welcome
            self.expand()
        }
    }

    /// Say once, plainly, that the last run ended badly.
    ///
    /// It rides the activity list rather than a new surface: needs-input
    /// sorts to the top and, unlike done and failed, never expires on a
    /// timer, so a crash that happened while nobody was looking is still
    /// there when they look. The glance line covers the closed island.
    private func reportLastCrashIfAny() {
        crashWatch.check()
        guard crashWatch.unreported != nil else { return }
        activities.push(
            id: CrashWatch.activityID,
            title: "Chalant quit unexpectedly last time",
            detail: "Say \u{201C}crash report\u{201D} for the reason,"
                + " or \u{201C}copy crash report\u{201D} to paste it somewhere.",
            state: .needsInput
        )
        flashGlance("Chalant crashed last time. Say \u{201C}crash report\u{201D}.", seconds: 8)
    }

    func replayWelcome() {
        welcomeStep = 0
        pane = .welcome
    }

    func finishWelcome() {
        pane = .none
        collapse()
    }

    /// Which way the next tab switch should slide, set by TabRow just
    /// before the tab changes so both land in the same transaction.
    var tabSlideDirection: CGFloat = 1

    /// Draft text in the Do box. Lives here so clipboard and shelf
    /// actions can hand content to the Do surface.
    @Published var draftPrompt = ""

    /// Result surface state, shared by typed and spoken input.
    @Published var answer = ""
    @Published var errorText = ""
    @Published var isWorking = false

    /// What the recognizer heard, echoed above voice answers so a
    /// mistranscription is never a mystery.
    @Published var lastHeard: String?

    /// Content attached to the next question (a file or a clip).
    @Published var pendingContext: (name: String, text: String)?

    /// When the last streamed delta arrived; the ask watchdog reads it
    /// to tell a slow answer from a dead one.
    private var lastStreamActivity = Date.distantPast

    /// A short-lived line in the collapsed glance: a session landing,
    /// a timer finishing. Clears itself.
    @Published var glanceToast: String?
    private var toastClearWork: DispatchWorkItem?

    func flashGlance(_ text: String, seconds: TimeInterval = 6) {
        toastClearWork?.cancel()
        glanceToast = text
        let work = DispatchWorkItem { [weak self] in
            self?.glanceToast = nil
        }
        toastClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // Feature stores
    let music = MusicController()
    let clipboard = ClipboardStore()
    let shelf = ShelfStore()
    let notes = NotesStore()
    let events = EventKitService()
    let timer = CountdownController()
    let stopwatch = StopwatchController()
    let ambience = AmbienceController()
    let focus: FocusController
    let focusStats = FocusStatsStore()
    let voice = VoiceController()
    let stats = SystemStatsController()
    let shortcuts = ShortcutStore()
    let courier = MessageCourier()
    let activities = ActivityStore()
    let activityServer = ActivityServer()
    /// Claude Code sessions on this Mac. Discovery reads the metadata
    /// files Claude Code already writes, so sessions show up with no
    /// setup and no hook contract — including ones that were already
    /// running before Chalant launched.
    ///
    /// The explicit directory is what turns on outbox persistence: a
    /// queued message now survives a relaunch instead of vanishing with
    /// it. `SessionStore`'s own default is nil (persistence off), so
    /// this is the one real opt-in; every test still gets a bare,
    /// disk-free store unless it asks for one.
    let sessions = SessionStore(outboxDirectory: SessionStore.defaultOutboxDirectory())
    private lazy var sessionDiscovery = SessionDiscovery(store: sessions)
    /// The liveness overlay: busy/idle from the registry Claude Code
    /// already writes, layered on top of the scraper above rather than
    /// replacing it (notch-messaging-plan-2026-08-01.md).
    private lazy var sessionRegistry = SessionRegistry(store: sessions)
    private lazy var cursorDiscovery = CursorDiscovery(store: sessions)
    let updates = UpdateChecker()
    let crashWatch = CrashWatch()
    /// Hands the update ask to Sparkle (set by the AppDelegate, which
    /// owns the updater): download, install, relaunch, no browser.
    var installUpdate: (() -> Void)?
    /// Opens the settings window, optionally at a named section (set by
    /// the AppDelegate, which owns the window). Everything that used to
    /// set `pane = .settings` calls this instead, so the island's gear
    /// and the menu bar item open the one same window.
    var openDashboard: ((DashboardSection?) -> Void)?
    /// Created on first open of the chat tab; the web view then lives
    /// for the app's lifetime so the conversation survives collapses.
    private(set) lazy var chat = ChatController()
    private(set) lazy var engine = ActionEngine(model: self)

    // `defaultNotchSize` used to live here as `IslandFace.notchSize`'s
    // starting value, a second hardcoded 196x34 next to `Config`'s own
    // 196x38 that only ever differed for the moment between `init` and
    // the first `apply(_:to:)` (EC-12). Deleted; `IslandFace.notchSize`
    // now initialises from a plain `Config()` instead (W-A, 2026-08-02).

    /// Debug-driven request to open the shortcut add flow; the
    /// Shortcuts pane consumes and resets it.
    @Published var wantsShortcutAdd = false
    /// Same, straight into the Shortcuts.app library picker.
    @Published var wantsShortcutPick = false
    /// The clipboard hotkey's second half: focus the search field once
    /// the panel is open. The Clipboard pane consumes and resets it.
    @Published var wantsClipboardSearch = false

    /// Per-display island settings. `apply(_:to:)` is the one place a
    /// screen turns into island geometry, and the only reader.
    let displays = DisplayConfigStore()

    /// How the island's contents are arranged, and the saved presets.
    let layout = IslandLayoutStore()

    // `islandStyle`, `notchSize`, `islandCornerRadius` and
    // `islandContentPadding` used to live here too, dual-written by
    // `apply(_:to:)` alongside the same values on `IslandFace` — a
    // stopgap for the round where only one face existed. Now that
    // every display gets its own face, a single shared copy of a
    // per-display fact is exactly the bug class this branch exists to
    // remove: every face would read whichever screen `apply(_:to:)`
    // happened to run for last. Deleted; `IslandFace` is the only
    // copy (island-per-display-plan, W-C, 2026-08-02).

    /// Set by the window controller so the panel can grab key focus.
    var onExpandChange: ((Bool) -> Void)?

    // MARK: - What the resting island has to say
    //
    // Moved here from NotchRootView (2026-08-01). The bead
    // (`NotchWindowController.rebuildSlivers`, now deleted) and the
    // island's own opacity used to each carry a version of "is there
    // anything to show" — the bead asked "collapsed with no toast",
    // the island asked "nothing to say" — and a collapsed island with
    // music playing satisfied the second without satisfying the
    // first, so both drew on the same display. `islandIsShowing`
    // below is the one place either can ask it now.
    //
    // These read UserDefaults directly rather than through
    // `@AppStorage`, which only works as a SwiftUI `DynamicProperty`
    // and does nothing outside a View — the same pattern already used
    // elsewhere on this model (`isAvailable(_:in:)`, `hoverChanged`).
    // NotchRootView keeps its own `@AppStorage` declarations for these
    // same keys so it still re-renders the instant a glance switch
    // flips in Settings.

    /// The camera mark's earned width, one number for both pill
    /// families (two hand-derived constants drifted apart once).
    private static let cameraMarkWidth: CGFloat = 16

    /// Agents running right now, and whether any wants an answer.
    ///
    /// What counts as one is `SessionStore.glanceable`, and it lives
    /// there rather than here so this number and the rows in the strip
    /// are answering from the same rule. They disagreed once, which is
    /// how the closed pill came to read 2 beside a list with one session
    /// worth opening.
    var agentGlance: (count: Int, waiting: Bool)? {
        guard UserDefaults.standard.object(forKey: "glanceAgents") as? Bool ?? true else {
            return nil
        }
        let live = sessions.glanceable
        guard !live.isEmpty else { return nil }
        return (live.count, live.contains { $0.state == .needsInput })
    }

    /// The event about to start, if the user lets the glance carry it.
    var upcomingEvent: DayEvent? {
        let glanceNextEvent = UserDefaults.standard.object(forKey: "glanceNextEvent") as? Bool ?? true
        return glanceNextEvent ? events.nextEvent : nil
    }

    /// Anything counting: a pomodoro, a plain timer, the stopwatch.
    var sessionActive: Bool {
        focus.isActive || timer.isActive || stopwatch.isActive
    }

    /// Music and a session at once: the wave keeps the left wing and
    /// the session mark takes the right (user, 2026-07-22).
    var sessionOnRight: Bool {
        let glanceSession = UserDefaults.standard.object(forKey: "glanceSession") as? Bool ?? true
        return glanceSession && sessionActive && music.nowPlaying?.isPlaying == true
    }

    /// The song's name on the resting island, not just its bars.
    ///
    /// This reverses an earlier call. The collapsed island on a monitor
    /// was stripped bare because content there "sat on top of someone's
    /// window" (user, 2026-07-22) and because a wide pill did not match
    /// the hardware (user, 2026-07-23). Both objections were about a
    /// screen pretending to be a MacBook. Asked again for an island
    /// rather than a notch on external displays, the user now wants the
    /// song beside it, so this is on for pills and off for notches —
    /// where the old reasoning still holds exactly.
    ///
    /// Style-and-state-shaped rather than reading `self.islandStyle`/
    /// `self.state`, now that those are per-face facts and not a single
    /// fact about the model: a caller passes its own face's `style` and
    /// `state`, so four faces can answer this four different ways in
    /// the same instant (island-per-display-plan, W-C, 2026-08-02).
    func showsSongBeside(style: DisplayConfigStore.Style, state: IslandState) -> Bool {
        let collapsedSong = UserDefaults.standard.object(forKey: "collapsedSong") as? Bool ?? true
        return style == .pill
            && collapsedSong
            && state == .collapsed
            && music.nowPlaying?.isPlaying == true
    }

    /// Each wing earns exactly what its content needs: the session
    /// mark wants 26 on a notch (digits clipped at real pomodoro
    /// widths, so the wing wears a symbol that cannot: the ring, or the
    /// stopwatch glyph; user, 2026-07-22) and 90 on a pill, which has
    /// the room for the digits themselves — a notch's narrow wing is
    /// the only reason they were ever dropped (2026-08-02). The slimmed
    /// wave takes 28. Quiet mode keeps the bare pill and lets the rim
    /// carry it (both moods proved real within one day, so it's a
    /// setting).
    func leftWingNeed(style: DisplayConfigStore.Style, state: IslandState) -> CGFloat {
        if showsSongBeside(style: style, state: state) { return Theme.Island.songGlanceWidth }
        let playingSignal = UserDefaults.standard
            .object(forKey: MusicController.playingSignalKey) as? String
            ?? MusicController.playingSignalDefault
        if playingSignal == "wave", music.nowPlaying?.isPlaying == true { return 28 }
        let glanceSession = UserDefaults.standard.object(forKey: "glanceSession") as? Bool ?? true
        if glanceSession, sessionActive, !sessionOnRight {
            return style == .pill ? 90 : 26
        }
        return 0
    }

    /// The glance that has earned the space beside the notch.
    ///
    /// Precedence is the user's list rather than the order these
    /// happen to be written in, since only one of them fits and which
    /// one matters more is a matter of taste, not of code.
    func winningCollapsedItem(style: DisplayConfigStore.Style) -> CollapsedItem? {
        layout.layout.collapsed.first { collapsedWidth($0, style: style) > 0 }
    }

    /// What a glance needs, and nothing if it has nothing to say. One
    /// function so the width and the decision to show it can never
    /// disagree — a glance with no width has nowhere to sit, which is
    /// how the charge shipped invisible.
    ///
    /// Style-shaped since 2026-08-02: a pill and a notch used to answer
    /// "is there anything to show" from the same numbers here while a
    /// monitor rendered from a separate, shorter list that disagreed
    /// with them — an agent session with nothing else running grew the
    /// pill to a 40x18 lozenge with nothing drawn in it. Threading style
    /// through this one function is what makes that impossible now.
    func collapsedWidth(_ item: CollapsedItem, style: DisplayConfigStore.Style) -> CGFloat {
        switch item {
        case .agents:
            return agentGlance != nil ? 44 : 0
        case .timers:
            return Self.timersWidth(sessionOnRight: sessionOnRight, style: style)
        // A session shows only its left-wing ring and countdown; the
        // right-side FOCUS 1 OF 4 label was width without value
        // (user call, 2026-07-21). A joinable meeting's camera mark
        // earns its own width; stealing the marquee's sent titles
        // into perpetual scroll.
        case .event:
            guard let next = upcomingEvent else { return 0 }
            return 112 + (next.joinURL != nil ? Self.cameraMarkWidth : 0)
        case .battery:
            let glanceBattery = UserDefaults.standard.object(forKey: "glanceBattery") as? Bool ?? false
            return glanceBattery && stats.battery != nil ? 44 : 0
        }
    }

    /// The session mark's width when it has crossed to the right wing
    /// (music is holding the left one): a notch's narrow side only has
    /// room for the ring or the stopwatch glyph, never digits; a pill
    /// has room for both (2026-08-02). Its own static, pulled out of
    /// `collapsedWidth`, so the split is checkable with no `NotchViewModel`
    /// to build (T-A2).
    static func timersWidth(sessionOnRight: Bool, style: DisplayConfigStore.Style) -> CGFloat {
        guard sessionOnRight else { return 0 }
        return style == .pill ? 90 : 30
    }

    /// Width the right-of-camera glance needs.
    func notchSideNeed(style: DisplayConfigStore.Style) -> CGFloat {
        if glanceToast != nil { return 124 }
        // Nothing beyond the user's list: the day, the streak, and the
        // clock glances all duplicated surfaces that already exist (the
        // menu bar clock sits an inch away), and every one of them
        // stretched the pill past the hardware (user, 2026-07-23, "it
        // should not be too wide on the Mac").
        return winningCollapsedItem(style: style).map { collapsedWidth($0, style: style) } ?? 0
    }

    /// The resting island's total span, in points, or nil when it has
    /// nothing to say. One function for "how wide" and "is there
    /// anything", so they can never disagree again — a pill used to
    /// answer the second question from these two numbers while
    /// rendering from a shorter, separate list, which is how an agent
    /// session with nothing else running grew a pill to a 40x18 lozenge
    /// with nothing drawn in it and suppressed the bead that would at
    /// least have been findable (2026-08-02).
    ///
    /// A notch widens symmetrically because the camera sits at the
    /// screen's centre and content would otherwise slide under it. A
    /// pill has no middle to clear, so its two wings sit adjacent.
    static func collapsedSpan(
        left: CGFloat, right: CGFloat, style: DisplayConfigStore.Style
    ) -> CGFloat? {
        guard left > 0 || right > 0 else { return nil }
        return style == .notch ? 2 * max(left, right) : left + right
    }

    /// Something is asking for the user, right now.
    ///
    /// Hiding is a preference about clutter, never about silence: a
    /// session that has stopped and wants an answer is the one moment
    /// the island exists for, and a hidden island that stayed hidden
    /// through it would be worse than no island (founder, 2026-08-02).
    /// A pill that has already been shut away comes back on its own for
    /// this, and goes away again when the asking is over.
    var somethingWantsYou: Bool {
        sessions.sessions.contains { session in
            session.state == .needsInput
                || (session.ask.map { !$0.isFullyAnswered } ?? false)
        } || activities.activities.contains { $0.state == .needsInput }
    }

    /// Whether an already-expanded island is in the middle of something:
    /// the same set of guards `scheduleHoverCollapse` already trusts not
    /// to be interrupted by a grazing cursor, reused here for a louder
    /// interruption. A question landing must yank nothing out from under
    /// mid-conversation chat, an attachment waiting to be sent, the
    /// welcome tour, a half-typed line in the Do box, or a message being
    /// composed to a session, so it marks and flashes instead of
    /// expanding over any of them.
    var isMidInteraction: Bool {
        isWorking || pendingContext != nil || pane != .none || tab == .chat
            || composingSessionID != nil || !draftPrompt.isEmpty
    }

    /// Anything the resting island would actually draw.
    func collapsedHasSomethingToSay(style: DisplayConfigStore.Style, state: IslandState) -> Bool {
        let left = leftWingNeed(style: style, state: state)
        let right = notchSideNeed(style: style)
        return Self.collapsedSpan(left: left, right: right, style: style) != nil
            || (ambience.active != nil && music.nowPlaying?.isPlaying != true)
    }

    /// Style-and-state-shaped so a rule about "is the island showing"
    /// can be asked of any display, not only this model's own screen —
    /// the whole of "hovering one display must not expand four"
    /// (2026-08-02).
    ///
    /// Deliberately **not called** from `NotchRootView` any more, and
    /// that is a real behaviour change, not an oversight: before W-C,
    /// a quiet pill's own opacity went to 0 here and the bead
    /// (`NotchWindowController.rebuildSlivers`, now deleted) drew the
    /// visible resting sliver in its place. With no bead left to hand
    /// off to, gating the shell on this would make a quiet pill show
    /// nothing at all, which is exactly the "fully invisible island
    /// reads as not installed" problem the sliver existed to solve —
    /// and the founder's explicit call is the opposite: a quiet
    /// display keeps its sliver. `collapsedIsEmpty` in `NotchRootView`
    /// already shrinks the shell to that sliver instead of hiding it.
    /// Kept and still tested (T-B2) as the rule it always was — an Off
    /// display never shows, a notch always does — for whatever future
    /// caller needs exactly that rule; there is none in this round.
    static func islandIsShowing(
        style: DisplayConfigStore.Style, expandedHere: Bool, hasSomethingToSay: Bool
    ) -> Bool {
        switch style {
        case .off: return false
        case .auto, .notch: return true
        case .pill: return expandedHere || hasSomethingToSay
        }
    }

    init() {
        focus = FocusController(ambience: ambience)
        timer.onComplete = { [weak self] minutes in
            guard let self else { return }
            self.focusStats.recordSession(minutes: minutes)
            self.flashGlance("timer done")
        }
        // The session ends with the break; no round number, nothing
        // is starting behind it.
        focus.onBreakComplete = { [weak self] _ in
            self?.flashGlance("break's over")
        }
        focus.onWorkPhaseComplete = { [weak self] minutes in
            guard let self else { return }
            let metBefore = self.focusStats.goalMet
            self.focusStats.recordSession(minutes: minutes)
            // The session that crosses the goal line gets the moment.
            if self.focusStats.goalMet, !metBefore {
                self.flashGlance("goal met · \(FocusStatsStore.clock(self.focusStats.todayMinutes))")
            } else {
                self.flashGlance("\(minutes) in the bank")
            }
        }
    }

    func start() {
        music.start()
        clipboard.start()
        stats.start()
        shortcuts.announce = { [weak self] message in
            self?.flashGlance(message)
        }
        activityServer.start(store: activities, sessions: sessions)
        // Registry first: it lists four small JSON files and can paint
        // a session row immediately. Discovery scrapes transcript tails
        // and can walk the filesystem to resolve a cwd, which is slow
        // enough to be visible (B3, founder 2026-08-02: "sometimes they
        // take a second to load all the sessions"). Its own first scan
        // is deferred so it decorates rows the registry already showed,
        // rather than making everyone wait for it to go first.
        sessionRegistry.start()
        sessionDiscovery.start()
        cursorDiscovery.start()
        // EC-11: a session can exit with a message still queued while
        // nobody has the composer open to see the row flip. The store
        // has no glance to flash, so it hands the moment back here.
        activities.onNeedsInput = { [weak self] title in
            self?.flashGlance(title, seconds: 8)
        }
        // An agent that simply finished is the common case, and until
        // now only a question reached the island. The founder wants the
        // turn's last words in front of them the moment it ends, with
        // the reply box under them, so answering is one place rather
        // than a hunt (2026-08-03).
        sessions.onSessionCameToRest = { [weak self] id, title in
            guard let self, self.opensWhenAnAgentFinishes else { return }
            self.flashGlance("\(title) finished", seconds: 6)
            // Same restraint as a question: never over a live mic, and
            // never over an island already busy with something. A turn
            // ending is worth showing, and it is not worth taking the
            // screen away from whatever is already being typed into.
            guard self.state != .listening else { return }
            guard self.state != .expanded || !self.isMidInteraction else { return }
            // takeKey: false, and this is the whole difference between a
            // notification and an interruption. The default takes
            // keyboard focus, which is right when a person just clicked
            // the island and wrong when the island appeared on its own:
            // the founder was typing in a terminal and their keystrokes
            // stopped going there (2026-08-03). Nothing that opens
            // without being asked may take the keyboard. Clicking into
            // the composer still focuses it, because that is a click.
            self.expand(takeKey: false)
            self.tab = .sessions
            // Straight to that session's own card, open, so its last
            // words and the box to answer them are the same surface.
            self.composingSessionID = id
        }
        sessions.onSessionWantsYou = { [weak self] title in
            guard let self else { return }
            self.flashGlance("\(title) wants you", seconds: 8)
            // Founder's explicit call: a question opens the island by
            // itself rather than waiting to be found (2026-08-03,
            // "Auto-open" -> "Yes, always open"). Two things still
            // outrank it: a live voice capture, which this would yank
            // the microphone out from under, and an island already open
            // on something the user is actively doing, which the flash
            // above is enough to point at without taking over their
            // screen mid-task. Everything else, including an island
            // that is merely open and idle, gets opened straight to it.
            guard self.state != .listening else { return }
            if self.state == .expanded, self.isMidInteraction { return }
            // takeKey: false for the same reason the finished-turn path
            // uses it: an island nobody asked to open must not take the
            // keyboard away from whatever they were typing into.
            self.expand(takeKey: false)
            // After expand(), never before: expand() runs
            // restoreLastTabIfWanted(), which would otherwise stomp this
            // the instant it ran (same bug and same fix as the shortcut
            // handler in ChalantApp.swift).
            self.tab = .sessions
        }
        sessions.onMessageUndelivered = { [weak self] title in
            self?.flashGlance("\(title) ended before reading your message")
        }
        // scripts/chalant-hook posts a Claude Code session's pill as
        // "claude-<session>" (only the pill is prefixed; the outbox and
        // ask routes take the bare id), the same mapping
        // ActivitiesStrip reverses to find a session for a tapped pill.
        // Resolves a needs-input pill once its session actually ends
        // (H5), rather than leaving it sitting there answerable to
        // nobody.
        sessions.onSessionGone = { [weak self] id in
            self?.activities.resolveIfPending(id: "claude-\(id)")
        }
        events.startGlanceTicker()
        updates.onNewVersion = { [weak self] version in
            self?.flashGlance("\(version) is out", seconds: 8)
        }
        updates.start()
        reportLastCrashIfAny()
        showWelcomeIfFirstRun()
        #if DEBUG
        // Terminal-driven verb testing, Debug builds only. Keystrokes
        // can't be injected into the non-activating panel (they land in
        // the frontmost app), so autonomous verification posts the
        // sentence by distributed notification instead:
        //   Notification name com.cj.chalant.debug.submit, text in object.
        debugObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cj.chalant.debug.submit"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let text = note.object as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                // "debug drop /path" exercises the drop pipeline,
                // which no synthetic drag can reach; "debug droptext"
                // does the same for text, "debug pin" pins the newest
                // clip. Buttons can't be clicked synthetically either.
                if text.hasPrefix("debug drop ") {
                    let path = String(text.dropFirst("debug drop ".count))
                        .trimmingCharacters(in: .whitespaces)
                    self.receiveDrop([.file(URL(fileURLWithPath: path))])
                    return
                }
                if text.hasPrefix("debug droptext ") {
                    self.receiveDrop([.text(String(text.dropFirst("debug droptext ".count)))])
                    return
                }
                // "debug dropquiet /path" exercises the bubble's
                // announce-only path.
                if text.hasPrefix("debug dropquiet ") {
                    let path = String(text.dropFirst("debug dropquiet ".count))
                        .trimmingCharacters(in: .whitespaces)
                    self.receiveDrop([.file(URL(fileURLWithPath: path))], quietly: true)
                    return
                }
                if text == "debug pin" {
                    if let newest = self.clipboard.clips.first(where: { !$0.pinned }) {
                        self.clipboard.togglePin(newest)
                    }
                    return
                }
                // "debug unshelf name" removes a shelf item, the row
                // buttons being unclickable synthetically.
                if text.hasPrefix("debug unshelf ") {
                    let name = String(text.dropFirst("debug unshelf ".count))
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    if let item = self.shelf.items.first(where: {
                        $0.name.lowercased().contains(name)
                    }) {
                        self.shelf.remove(item)
                    }
                    return
                }
                // "debug voice" reports the speech stack's health.
                if text == "debug voice" {
                    self.expand()
                    self.tab = .ask
                    self.answer = self.voice.diagnostics
                    return
                }
                // "debug music" dumps the resolved media state to
                // `defaults read com.cj.chalant musicDebug`: the one
                // window into how a source (browser, helper process,
                // player app) actually landed after resolution.
                if text == "debug music" {
                    var bits = ["adapter=\(self.music.bridge.adapterAvailable)"]
                    if let playing = self.music.nowPlaying {
                        bits += [
                            "source=\(playing.source.displayName)",
                            "track=\(playing.track)",
                            "artist=\(playing.artist)",
                            "playing=\(playing.isPlaying)",
                            "duration=\(Int(playing.duration))",
                            "position=\(Int(self.music.position()))",
                            "volume=\(Int(playing.volume))",
                            "shuffle=\(playing.supportsShuffle)",
                            "artwork=\(self.music.artwork != nil)",
                        ]
                        if case .system(let bundleID, _) = playing.source {
                            bits.append("bundle=\(bundleID)")
                        }
                    } else {
                        bits.append("idle")
                    }
                    if let state = self.music.bridge.state {
                        bits.append("bridge=\(state.bundleIdentifier)/\(state.parentBundleIdentifier ?? "-")/\(state.title)/\(state.playing)")
                    } else {
                        bits.append("bridge=nil")
                    }
                    bits.append("trace=\(self.music.bridgeTrace)")
                    bits.append("snap=\(self.music.bridge.snapshotTrace)")
                    bits.append("enrich=\(self.music.enrichCount)")
                    UserDefaults.standard.set(bits.joined(separator: " | "), forKey: "musicDebug")
                    return
                }
                // "debug join" resolves what the join verb would open
                // without opening it; read com.cj.chalant joinDebug.
                if text == "debug join" {
                    let event = await self.events.joinableEvent()
                    UserDefaults.standard.set(
                        event.map {
                            "\($0.title) | \($0.joinURL?.absoluteString ?? "-") | starts \($0.start)"
                        } ?? "none",
                        forKey: "joinDebug"
                    )
                    return
                }
                // "debug goadd" opens the shortcut add flow for
                // screenshots; the field states are view-local.
                if text == "debug goadd" {
                    self.expand()
                    self.tab = .links
                    self.wantsShortcutAdd = true
                    return
                }
                if text == "debug gopick" {
                    self.expand()
                    self.tab = .links
                    self.wantsShortcutPick = true
                    return
                }
                // "debug addshortcut <text>" runs the same store path
                // the add field commits through.
                if text.hasPrefix("debug addshortcut ") {
                    let link = String(text.dropFirst("debug addshortcut ".count))
                    self.shortcuts.add(title: "", link: link)
                    return
                }
                // "debug listen" runs a real 4-second capture through
                // the normal deliver path; ambient audio becomes the
                // transcript and proves the chain on real hardware.
                if text == "debug listen" {
                    if self.state == .expanded { self.collapse() }
                    self.beginListening()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        self?.endListening()
                    }
                    return
                }
                // "debug update" fires the Sparkle flow itself, for
                // rehearsing the install-and-relaunch loop.
                if text == "debug update" {
                    self.installUpdate?()
                    return
                }
                // "debug updatecheck <ver>" rehearses the stale path
                // against the real releases feed.
                if text.hasPrefix("debug updatecheck ") {
                    let pretend = String(text.dropFirst("debug updatecheck ".count))
                        .trimmingCharacters(in: .whitespaces)
                    Task { await self.updates.check(pretendCurrent: pretend) }
                    return
                }
                // "debug welcome <n>" opens tour page n for screenshots.
                if text.hasPrefix("debug welcome") {
                    let tail = text.dropFirst("debug welcome".count)
                        .trimmingCharacters(in: .whitespaces)
                    self.welcomeStep = min(3, max(0, Int(tail) ?? 0))
                    self.pane = .welcome
                    self.expand()
                    return
                }
                // "debug rec" records the live tap to /tmp/chalant-tap.caf;
                // "debug recfile" runs the recognizer over it. Together
                // they split "garbled capture" from "deaf recognizer".
                if text == "debug rec" {
                    self.voice.debugRecord(seconds: 3.5) { [weak self] note in
                        self?.expand()
                        self?.tab = .ask
                        self?.answer = note
                    }
                    return
                }
                if text.hasPrefix("debug recfile") {
                    let tail = text.dropFirst("debug recfile".count)
                        .trimmingCharacters(in: .whitespaces)
                    self.voice.debugRecognizeFile(
                        path: "/tmp/chalant-tap.caf",
                        locale: tail.isEmpty ? nil : tail
                    ) { [weak self] note in
                        self?.expand()
                        self?.tab = .ask
                        self?.answer = note
                    }
                    return
                }
                // "debug settings" opens the settings window for
                // screenshots; an optional tail picks a section,
                // "debug settings island".
                if text.hasPrefix("debug settings") {
                    let tail = text.dropFirst("debug settings".count)
                        .trimmingCharacters(in: .whitespaces)
                    self.openDashboard?(tail.isEmpty ? nil : DashboardSection.named(tail))
                    return
                }
                // "debug dropdock" shows the mid-screen drop bubble.
                if text == "debug dropdock" {
                    self.onDebugDropDock?()
                    return
                }
                // "debug droptarget" shows the drop overlay briefly;
                // real drags cannot be synthesized.
                if text == "debug droptarget" {
                    self.expand(takeKey: false)
                    self.debugSetDropTargeted?(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.debugSetDropTargeted?(false)
                    }
                    return
                }
                // "debug tab focus" opens a pane for screenshots;
                // synthetic clicks never reach the switcher.
                if text.hasPrefix("debug tab ") {
                    let name = String(text.dropFirst("debug tab ".count))
                    let tabs: [String: Tab] = [
                        "today": .today, "ask": .ask, "clipboard": .clipboard,
                        "shelf": .shelf, "go": .links, "notes": .notes,
                        "focus": .focus, "chat": .chat,
                    ]
                    if let tab = tabs[name] {
                        self.tab = tab
                        self.expand()
                    }
                    return
                }
                self.expand()
                self.submit(text)
            }
        }
        #endif
        // Theme.Feel reads the system Reduce Motion flag at render
        // time; nudge the tree when it flips so the change is live.
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    /// Where an island opens when nothing said which display.
    ///
    /// The pointer's own display, else the one last hovered, else the
    /// main one, else whatever is attached. Written once rather than at
    /// each of the fifteen callers of the old no-argument `expand()`:
    /// fifteen answers to one question is how `hasPhysicalNotch` and
    /// `islandStyle` once came to contradict each other (56cd56c).
    static func defaultOwner(
        pointerOn: CGDirectDisplayID?, lastHovered: CGDirectDisplayID?,
        main: CGDirectDisplayID?, any: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        pointerOn ?? lastHovered ?? main ?? any
    }

    /// `defaultOwner` fed from live AppKit state: wherever the pointer
    /// currently sits, else the last display that reported hovering,
    /// else the main screen, else the first attached one.
    private func defaultOwnerDisplay() -> CGDirectDisplayID? {
        let pointerOn = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID
        return Self.defaultOwner(
            pointerOn: pointerOn,
            lastHovered: lastHoveredDisplayID,
            main: NSScreen.main?.displayID,
            any: NSScreen.screens.first?.displayID
        )
    }

    /// `takeKey: false` for drag-driven opens: grabbing key focus in
    /// the middle of someone's drag yanks their app around. No display
    /// named, so `defaultOwnerDisplay()` picks one (EC-12).
    func expand(takeKey: Bool = true) {
        expand(on: defaultOwnerDisplay(), takeKey: takeKey)
    }

    /// The one door into an expansion on a specific display.
    ///
    /// Handing the island from one display to another is a collapse
    /// and an expansion, one run-loop turn apart, never a swap of
    /// `expandedDisplayID` under a live view: `ExpandedView` holds
    /// `ChatController`'s single `WKWebView` (`ChatController.swift:96`),
    /// an `NSView` cannot be in two hierarchies, and the outgoing
    /// panel keeps its content mounted for the removal fade
    /// (`NotchRootView.swift`). Swapped in place, the chat went blank
    /// on both (EC-9, 2026-08-02).
    func expand(on display: CGDirectDisplayID?, takeKey: Bool = true) {
        // Switched off on this screen, or the screen is gone. Refused
        // here rather than hidden in the view: hover is tracked by the
        // window controller against screen zones, not by the island's
        // own hit testing, so an invisible island would still open
        // under the pointer.
        guard let display,
              let screen = NSScreen.screens.first(where: { $0.displayID == display }),
              displays.resolvedStyle(for: screen) != .off
        else { return }
        if let current = expandedDisplayID, current != display {
            collapse()
            DispatchQueue.main.async { [weak self] in
                self?.expand(on: display, takeKey: takeKey)
            }
            return
        }
        guard state != .expanded else { return }
        expandedDisplayID = display
        state = .expanded
        restoreLastTabIfWanted()
        music.expandedVisible = true
        if takeKey { onExpandChange?(true) }
    }

    /// Reopen where the user left off, when they have asked for that.
    /// A tool switched off in settings since is not a place to reopen
    /// into, so a stored tab pointing at one is dropped rather than
    /// opened onto a panel whose switcher icon is gone.
    private func restoreLastTabIfWanted() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.rememberLastTabKey) else { return }
        let stored = defaults.string(forKey: Self.lastTabKey).flatMap(Tab.init(rawValue:))
        // Falls back to today rather than returning early, and that
        // distinction is the whole bug: while remembering, `collapse()`
        // never resets `tab`, so it still holds the closed-on value in
        // memory. Bailing out left it there — switch a tool off while
        // the island is shut and it reopened straight onto that tool's
        // panel, the one case this guard exists to prevent.
        tab = stored.flatMap {
            Self.isAvailable($0, in: defaults, batteryPresent: stats.battery != nil) ? $0 : nil
        } ?? .today
    }

    /// Whether a tab is somewhere the island can open onto right now:
    /// its tool has not been switched off in settings, and, battery
    /// alone among these, the hardware it shows actually exists.
    /// `batteryPresent` defaults true so every other tab, and the
    /// hotkey dispatch in ChalantApp.swift that never targets
    /// `.battery`, reads exactly as before.
    static func isAvailable(
        _ tab: Tab, in defaults: UserDefaults = .standard, batteryPresent: Bool = true
    ) -> Bool {
        if tab == .battery, !batteryPresent { return false }
        guard let key = tab.toolKey else { return true }
        // An unset flag means the tool ships on, matching the
        // @AppStorage defaults the settings window declares.
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// Whether a finished turn opens the island. On by default: it is
    /// the behaviour that was asked for, and an agent finishing is the
    /// event this app exists to catch. Off is for anyone who would
    /// rather glance than be shown.
    static let openOnFinishKey = "openWhenAnAgentFinishes"
    var opensWhenAnAgentFinishes: Bool {
        UserDefaults.standard.object(forKey: Self.openOnFinishKey) as? Bool ?? true
    }

    static let rememberLastTabKey = "rememberLastTab"
    private static let lastTabKey = "lastTab"

    func collapse() {
        guard state == .expanded else { return }
        state = .collapsed
        pane = .none
        // The island always reopens small and clean, unless the user
        // asked it to reopen where they left off.
        if UserDefaults.standard.bool(forKey: Self.rememberLastTabKey) {
            UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
        } else {
            tab = .today
        }
        music.expandedVisible = false
        onExpandChange?(false)
    }

    // MARK: - Hover opens the island

    private var hoverCollapseWork: DispatchWorkItem?

    /// `isHovering` stays the one shared flag the collapse guards below
    /// read ("is the pointer on the island at all"); `on:` is which
    /// display it is on, so hover-out only schedules a collapse when it
    /// is the display actually holding the expansion that lost the
    /// pointer, and hover-in expands that display specifically rather
    /// than wherever `expandedDisplayID` used to point.
    func hoverChanged(_ hovering: Bool, on display: CGDirectDisplayID) {
        isHovering = hovering
        if hovering {
            lastHoveredDisplayID = display
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            // The reader arrived; the voice answer is theirs now.
            answerCollapseWork?.cancel()
            answerCollapseWork = nil
            let expandOnHover = UserDefaults.standard
                .object(forKey: "expandOnHover") as? Bool ?? true
            if state == .collapsed, expandOnHover { expand(on: display) }
        } else if state == .expanded, expandedDisplayID == display {
            scheduleHoverCollapse()
        }
    }

    /// Collapse as soon as the cursor leaves, unless the user is
    /// mid-something: typing a draft, waiting on an answer, or holding
    /// an attachment. The tiny default delay is a debounce so the island
    /// doesn't thrash when the pointer skims its edge.
    private func scheduleHoverCollapse() {
        let delay = UserDefaults.standard
            .object(forKey: "collapseDelay") as? Double ?? 0.05
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Chat is a deliberate surface: mid-conversation with
            // Claude, a grazing cursor must not close the island.
            // A half-typed draft, though, survives collapse (model
            // state, waiting on the next open) and must never pin
            // the island to the screen; it did, and it read as stuck.
            guard self.state == .expanded, !self.isHovering,
                  !self.isWorking,
                  self.pendingContext == nil, self.pane == .none,
                  self.tab != .chat else { return }
            self.collapse()
        }
        hoverCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Voice, hold to talk

    /// The room goes quiet before the island listens: playing music
    /// pauses and ambience ducks, restored the moment the session
    /// ends. The mic was drowning in the user's own speakers (seen
    /// live, bars maxed on a Tame Impala chorus).
    private var duckedMusicForVoice = false
    private var duckedAmbienceVolume: Double?

    private func quietTheRoom() {
        if music.nowPlaying?.isPlaying == true {
            duckedMusicForVoice = true
            music.pause()
        }
        // Only duck once. A second quietTheRoom() before the matching
        // restore would read the already-ducked 0 as "the volume to go
        // back to", and the chip stays lit over silence forever with no
        // way back but the slider. Two mic taps inside the 1.2s finalize
        // window is all it takes.
        if ambience.active != nil, duckedAmbienceVolume == nil {
            duckedAmbienceVolume = ambience.volume
            ambience.volume = 0
        }
    }

    private func restoreTheRoom() {
        if duckedMusicForVoice {
            duckedMusicForVoice = false
            music.play()
        }
        if let restored = duckedAmbienceVolume {
            duckedAmbienceVolume = nil
            ambience.volume = restored
        }
    }

    /// Where the next transcript goes. Passed in at every entrance
    /// rather than stored as a mode: a sticky destination would send
    /// the next reminder, note or text message into an agent's context
    /// with nothing on screen having changed, the worst outcome named
    /// in the plan (notch-messaging-plan-2026-08-01.md, EC-12).
    enum VoiceDestination: Equatable {
        case chalant
        case session(id: String, title: String)
    }

    /// Set by whichever entrance started this listening session,
    /// captured and reset by `endListening` before anything else runs.
    /// Never read outside that capture and `listeningContent`, which
    /// only names the destination while `state == .listening`.
    @Published private(set) var voiceDestination: VoiceDestination = .chalant

    /// Which session's compose card is open in the strip, if any. Lives
    /// here rather than as the strip's own view state: the composer's
    /// mic sends the whole island through `.listening`, which unmounts
    /// `ExpandedView`, taking the strip with it, exactly as it does for
    /// the persistent mic. View-local state does not survive that round
    /// trip; `tab` and `draftPrompt` live here for the same reason.
    @Published var composingSessionID: String?

    func beginListening(to destination: VoiceDestination = .chalant) {
        guard state == .collapsed else { return }
        voiceDestination = destination
        startListening()
    }

    /// Mic button in the expanded island: tap to talk, tap to run.
    /// `to:` defaults to `.chalant`, so the persistent media-row mic,
    /// the `.talk` hotkey and the collapsed long press all keep their
    /// exact behaviour without being touched.
    func toggleListening(to destination: VoiceDestination = .chalant) {
        if state == .listening {
            endListening()
        } else {
            voiceDestination = destination
            startListening()
        }
    }

    /// The one door into a listening session, because the invariant
    /// below has to hold at every entrance.
    ///
    /// Starting a session abandons any finalize still in flight: begin()
    /// drops the previous session's completion, and that completion is
    /// the only thing that would ever have cleared isWorking. Left set,
    /// it makes every later question a silent no-op (submit guards on
    /// it) and pins the island open (hover-collapse guards on it too),
    /// with no error and nothing on screen to explain it. Tap, tap, tap
    /// inside 1.2 seconds and then click outside, and the app was deaf
    /// until relaunch.
    private func startListening() {
        // A listening session needs an owner display too, just like an
        // expansion — `state(_:expandedOn:face:)` treats `.listening`
        // the same as `.expanded`, so with no owner every face would
        // read `.collapsed` while the mic was live and the room ducked
        // (EC-11, 2026-08-02). Only when nothing already owns this: the
        // composer's mic and the persistent media-row mic both start
        // listening while already expanded on a specific display, and
        // must keep it, not have it reassigned here.
        if expandedDisplayID == nil {
            expandedDisplayID = defaultOwnerDisplay()
        }
        quietTheRoom()
        state = .listening
        // Only the orphaned case clears the flag. A typed question
        // still streaming its answer owns isWorking too, and must keep
        // it: clearing that one would hide the working indicator with
        // the answer still arriving, and let a second submit through.
        if voice.begin(), isWorking {
            Self.log.notice("listen abandoned a finalize still in flight; clearing isWorking")
            isWorking = false
        }
    }

    func endListening() {
        guard state == .listening else { return }
        // Captured now and reset in the same statement, before any
        // await below: the one invariant EC-12 exists to protect.
        // Every entrance sets `voiceDestination` fresh right before it
        // starts listening, so nothing downstream can carry a
        // destination past the transcript it was captured for.
        let destination = voiceDestination
        voiceDestination = .chalant
        // Leave listening immediately, finalization can take a second
        // and lingering in the listening UI reads as "release didn't
        // work". Dots show while the transcript settles.
        //
        // Only a Chalant-bound answer wants the Ask tab; jumping there
        // mid-message to a session would pull the user off the
        // composer they were just speaking into.
        if case .chalant = destination { tab = .ask }
        state = .expanded
        onExpandChange?(true)
        isWorking = true
        voice.end { [weak self] text in
            guard let self else { return }
            self.isWorking = false
            self.restoreTheRoom()
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.isEmpty {
                self.lastHeard = nil
                let why = self.voice.failure
                    ?? "Heard nothing. Hold a beat longer next time."
                if case .chalant = destination {
                    self.answer = why
                }
                // Empty sessions were the only unlogged outcome, and
                // exactly the ones every mystery report is made of.
                self.logVoice(
                    "(nothing)",
                    outcome: "\(why) [ear: \(self.voice.activeDeviceName ?? "unknown"),"
                        + " \(self.voice.deviceNote)]"
                )
            } else {
                switch destination {
                case .chalant:
                    self.submit(spoken)
                    self.lastHeard = spoken
                case .session(let id, let title):
                    // Straight to the outbox, never through submit():
                    // ActionEngine's verbs are Chalant's business, not
                    // an agent's, and the body never reaches the trail
                    // that follows (EC-13).
                    //
                    // The result is read, not discarded. `queue` refuses
                    // a session that has ended, a row that cannot
                    // receive, and anything past the cap, and a refusal
                    // here means the user just spoke a sentence that
                    // went nowhere. Dropping it silently while the trail
                    // recorded "queued" would make the log lie about the
                    // one thing it exists to answer.
                    let queued = self.sessions.queue(message: spoken, for: id)
                    if queued {
                        let (heard, outcome) = Self.agentMessageLogLine(title: title, text: spoken)
                        self.logVoice(heard, outcome: outcome)
                    } else {
                        self.flashGlance("\(title) did not take that message")
                        let (heard, _) = Self.agentMessageLogLine(title: title, text: spoken)
                        self.logVoice(heard, outcome: "refused, nothing was queued")
                    }
                }
            }
            // A voice answer opened the island without the cursor
            // ever visiting; give it a readable moment, then slip
            // shut on its own. A hover cancels this, the reader has
            // taken over.
            self.scheduleVoiceCollapse()
        }
    }

    /// The last utterances and what became of them, persisted so the
    /// trail survives relaunches (the app restarts more than voice
    /// sessions fail). "voice log" reads it; so does
    /// `defaults read com.cj.chalant voiceLog` from a terminal.
    private let voiceLogKey = "voiceLog"

    /// The trail keeps the shape of what was said, never the sentence
    /// itself when that sentence is bound for another person. Those
    /// words were being written verbatim into a plist that is never
    /// cleared, so every message dictated since install was sitting in
    /// preferences. Who it was for survives, because that is what a
    /// staging bug looks like; what it said does not.
    static func redactedForLog(heard: String, outcome: String) -> (String, String) {
        var heard = heard
        var outcome = outcome
        if let prefix = ActionEngine.textingPrefix(of: heard.lowercased()) {
            let words = heard.dropFirst(prefix.count).split(separator: " ")
            // A recipient is only nameable when something follows it.
            // With one token there is no telling a name from a one word
            // message, and this used to keep it either way: "tell
            // hunter2" logged hunter2 as the recipient. A redactor that
            // guesses keeps the very thing it exists to hide, so the
            // ambiguous case holds everything back and reports only the
            // shape. Found by fuzzing, not by reading.
            if words.count >= 2 {
                // A multi-word name loses its tail, which is the safe
                // direction to be wrong in.
                heard = "\(prefix)\(words[0]) \(heldBack(words.count - 1))"
            } else {
                heard = "\(prefix)\(heldBack(words.count))"
            }
        }
        // The staging read-back quotes the whole message back so the
        // user can hear it before saying send.
        if outcome.hasPrefix("To "),
           let open = outcome.firstIndex(of: "\u{201C}"),
           let close = outcome.lastIndex(of: "\u{201D}"), open < close {
            let body = outcome[outcome.index(after: open)..<close]
            let held = heldBack(body.split(separator: " ").count)
            outcome.replaceSubrange(open...close, with: "\u{201C}\(held)\u{201D}")
        }
        return (heard, outcome)
    }

    /// A message bound for an agent is the same class of thing as one
    /// bound for a person: the user's own words, going somewhere else.
    /// `voiceLog` is a preferences array that is never cleared, so the
    /// body never reaches it at all here, not redacted after the fact
    /// like `redactedForLog` above, simply never assembled. Only where
    /// it went and how long it was.
    static func agentMessageLogLine(title: String, text: String) -> (String, String) {
        let words = text.split(separator: " ").count
        return ("a message for \(title)", "queued, \(words) word\(words == 1 ? "" : "s")")
    }

    private static func heldBack(_ words: Int) -> String {
        "[\(max(0, words)) words held back]"
    }

    func logVoice(_ heard: String, outcome: String) {
        let (heard, outcome) = Self.redactedForLog(heard: heard, outcome: outcome)
        var lines = UserDefaults.standard.stringArray(forKey: voiceLogKey) ?? []
        lines.append("heard \u{201C}\(heard)\u{201D} → \(outcome)")
        // 40 lines: a 10-line trail rotated evidence away mid-sweep
        // twice in one day (R114, R122); reading it is the first move
        // on any voice report, so it has to hold a whole session.
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        UserDefaults.standard.set(lines, forKey: voiceLogKey)
    }

    func clearVoiceLog() {
        UserDefaults.standard.removeObject(forKey: voiceLogKey)
    }

    var voiceLogRendered: String {
        let lines = UserDefaults.standard.stringArray(forKey: voiceLogKey) ?? []
        guard !lines.isEmpty else { return "Nothing heard yet." }
        return lines.suffix(5).joined(separator: "\n")
    }

    private var answerCollapseWork: DispatchWorkItem?

    private func scheduleVoiceCollapse(after delay: TimeInterval = 5) {
        answerCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Still thinking or still streaming: check back shortly.
            if self.isWorking {
                self.scheduleVoiceCollapse(after: 3)
                return
            }
            guard self.state == .expanded, !self.isHovering,
                  self.pendingContext == nil,
                  self.pane == .none, self.tab != .chat else { return }
            self.collapse()
        }
        answerCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Discard the recording without running anything.
    ///
    /// This is also EC-20's guard: the global click monitor
    /// (`NotchWindowController`) already calls this the instant a click
    /// lands outside the app while `state == .listening`, for any
    /// destination, so a composer dismissed mid-dictation never has its
    /// transcript delivered anywhere. It is simply never spoken into a
    /// destination that outlives it.
    func cancelListening() {
        guard state == .listening else { return }
        voice.cancel()
        // Defensive: nothing reads this outside a listening session,
        // but a destination left pointed at a session between here and
        // the next `beginListening`/`toggleListening` is exactly the
        // kind of stored mode EC-12 exists to rule out.
        voiceDestination = .chalant
        // cancel() drops the completion too, so this is the last hand
        // that can put the flag down.
        isWorking = false
        state = .collapsed
        restoreTheRoom()
    }

    /// Content dropped on the island, delivered from the panel's AppKit
    /// drag handler (SwiftUI's onDrop never fires in this panel). Files
    /// and links stash on the shelf; images and text join the clipboard,
    /// ready to paste. Dropped on the island itself, the island opens to
    /// show the catch; `quietly` (the mid-screen bubble) announces in
    /// the glance instead, the island stays tucked away and the right
    /// tab waits for the next open.
    func receiveDrop(_ items: [DroppedItem], quietly: Bool = false) {
        // The hosting view already refuses drags mid-voice; belt and braces.
        guard state != .listening else { return }
        // `dragExpanded` itself now lives on `IslandFace` (2026-08-02);
        // the window controller clears it at the same `onDrop` call that
        // reaches here, right beside where it is set.
        var landedShelf = false
        var landedClip = false
        for item in items {
            switch item {
            case .file(let url):
                shelf.add(url)
                landedShelf = true
            case .image(let image):
                if clipboard.addImage(image) { landedClip = true }
            case .link(let url):
                if shelf.addLink(url) { landedShelf = true }
            case .text(let text):
                if clipboard.addText(text) { landedClip = true }
            }
        }
        guard landedShelf || landedClip else { return }
        tab = landedShelf ? .shelf : .clipboard
        if quietly {
            flashGlance(
                landedShelf && landedClip ? "stashed"
                    : landedShelf ? "on the shelf" : "in clips"
            )
        } else {
            expand()
        }
    }

    /// Attach text (from a clip or file) and jump to the Do surface.
    func askAbout(name: String, text: String) {
        pendingContext = (name, text)
        tab = .ask
        expand()
    }

    // MARK: - One path for every input

    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        errorText = ""
        // Typed and debug input carries no transcript; the voice path
        // sets lastHeard right after this call.
        lastHeard = nil
        // Answers need room, the island grows to show them.
        tab = .ask

        Task {
            // Local verbs first: instant, offline, keyless.
            if let local = await engine.handle(text) {
                answer = local
                logVoice(text, outcome: local)
                return
            }
            logVoice(text, outcome: "no verb matched, went to the model")

            // Beyond local verbs, freeform questions go to the Mac's
            // own model, keyless. Long conversations belong to the
            // Chat tab, where the user's real subscription lives.
            guard AIService.localModelAvailable else {
                answer = "That one needs Apple Intelligence, System Settings, Apple Intelligence and Siri. Reminders, notes, timers, focus, calendar, and music all work without it, and the Chat tab carries your own Claude, ChatGPT, or Gemini."
                return
            }

            // Loose phrasings become verbs first: the model translates,
            // the same deterministic engine executes. Nobody has to
            // remember the exact words.
            if pendingContext == nil, text.count < 160 {
                isWorking = true
                let verb = await AIService.translateToVerb(text)
                isWorking = false
                logVoice(text, outcome: "model said: \(verb ?? "nothing")")
                if let verb, verb.lowercased() != text.lowercased(),
                   let acted = await engine.handle(verb) {
                    answer = acted
                    logVoice(text, outcome: "\(verb) \u{2192} \(acted)")
                    return
                }
            }

            var fullPrompt = text
            if let context = pendingContext {
                fullPrompt = """
                Attached content from "\(context.name)":
                \(context.text)

                Question: \(text)
                """
                pendingContext = nil
            }

            answer = ""
            isWorking = true
            lastStreamActivity = Date()
            let streaming = Task { [weak self] in
                do {
                    for try await delta in AIService.stream(prompt: fullPrompt) {
                        guard let self else { return }
                        self.answer += delta
                        self.lastStreamActivity = Date()
                    }
                    // Freeform answers used to vanish from the trail
                    // ("went to the model" was the last word); the
                    // landing is worth a line.
                    if let self, !self.answer.isEmpty {
                        self.logVoice(text, outcome: "model answered, \(self.answer.count) chars")
                    }
                } catch {
                    // Watchdog cancellation reports through its own
                    // message; only real failures land here.
                    if !(error is CancellationError),
                       (error as? URLError)?.code != .cancelled {
                        self?.errorText = error.localizedDescription
                    }
                }
                self?.isWorking = false
            }
            // A stalled provider must never wedge the island: before
            // this, isWorking stayed true forever on a hung stream,
            // which blocked hover-collapse and every later question
            // until relaunch. 20 quiet seconds ends the session.
            Task { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, self.isWorking, !streaming.isCancelled else { return }
                    if Date().timeIntervalSince(self.lastStreamActivity) > 20 {
                        streaming.cancel()
                        // Cancelling asks; it does not guarantee. The
                        // stream is awaiting a reply from another
                        // process, and if that reply never comes the
                        // task's own tail never runs, so the hand that
                        // gave up has to put the flag down itself.
                        // Otherwise the watchdog returns having fixed
                        // nothing and the island is wedged anyway.
                        self.isWorking = false
                        Self.log.notice("stream went quiet for 20s; cancelled and released the island")
                        if self.answer.isEmpty {
                            self.errorText = "No answer arrived. Check the network, then try again."
                        }
                        return
                    }
                }
            }
        }
    }
}
