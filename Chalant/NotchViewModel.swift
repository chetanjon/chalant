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

    @Published var state: IslandState = .collapsed
    @Published var isHovering = false
    /// Which lower panel the switcher is showing. `.today` is home.
    @Published var tab: Tab = .today
    @Published var pane: Pane = .none

    /// The island's expanded size, measured from the content itself,
    /// the island hugs what's shown instead of reserving a fixed void.
    @Published var expandedSize = CGSize(width: 520, height: 170)

    /// A drag is hovering the island: light the accent edge.
    @Published var isDropTargeted = false

    /// Debug builds show the drop bubble on request; the window
    /// controller owns the panel, so it hangs the hook here.
    var onDebugDropDock: (() -> Void)?

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

    /// The island opened itself for an incoming drag; if the drag
    /// leaves without dropping it closes again.
    var dragExpanded = false

    /// Pointer position across the island, 0...1, published by the
    /// window controller's hover poll, quantized so casual movement
    /// costs a few re-renders per second, not twenty. nil = no light.
    @Published var pointerUnit: CGFloat?

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
    let sessions = SessionStore()
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

    /// Default pill for notch-less displays, so Chalant works on any Mac.
    static let defaultNotchSize = CGSize(width: 196, height: 34)

    /// Physical notch size measured by NotchWindowController. Published
    /// because the whole collapsed geometry is derived from it; it was
    /// a plain var, and the controller compensated with a manual
    /// objectWillChange *after* mutating, which is the wrong order and
    /// left any other writer silently rendering stale geometry.
    @Published var notchSize = NotchViewModel.defaultNotchSize
    /// Debug-driven request to open the shortcut add flow; the
    /// Shortcuts pane consumes and resets it.
    @Published var wantsShortcutAdd = false
    /// Same, straight into the Shortcuts.app library picker.
    @Published var wantsShortcutPick = false

    /// Per-display island settings. `placement(on:)` is the one place a
    /// screen turns into island geometry, and the only reader.
    let displays = DisplayConfigStore()

    /// How the island's contents are arranged, and the saved presets.
    let layout = IslandLayoutStore()

    /// The shape this screen's island wears, already resolved out of
    /// `.auto`. `hasPhysicalNotch` is its render-facing half.
    @Published var islandStyle: DisplayConfigStore.Style = .notch
    /// Bottom-corner radius of the collapsed island on this screen.
    @Published var islandCornerRadius: CGFloat = Theme.Island.radiusCollapsed
    /// Room down each side of the expanded island on this screen.
    @Published var islandContentPadding: CGFloat = Theme.Space.xl

    /// Which display `placement(on:)` last measured. The Displays pane
    /// lists every attached screen as an equal, and the island can
    /// only be on one: without this, editing any display but this one
    /// was a correct write with no visible effect and nothing on
    /// screen saying why (2026-08-01). `placement(on:)` is its only
    /// writer.
    @Published var islandDisplayID: CGDirectDisplayID?

    /// Set by the window controller so the Displays pane's "Move
    /// island here" button can ask for a travel it would otherwise
    /// have no way to trigger — the pane holds a stable UUID key,
    /// never an `NSScreen` (see `DisplayConfigStore.key(for:)`), so
    /// resolving the key back to a live screen is the controller's
    /// job, not this model's.
    var travelToDisplay: ((String) -> Void)?

    /// True on the built-in display where hardware occupies the middle
    /// of the island; external displays keep that space usable.
    ///
    /// Derived from `islandStyle` rather than its own stored
    /// `@Published` bool: the stored version defaulted `false` while
    /// `islandStyle` defaulted `.notch` — two answers to one question
    /// that only ever agreed because `placement(on:)` runs before the
    /// first render. Deriving it removes the second default outright;
    /// a reader still gets a live re-render, since `islandStyle` is
    /// the `@Published` one.
    ///
    /// Read as "the island wraps a notch here", not "this panel has one
    /// in it": a screen set to Notch in settings wraps an emulated one,
    /// and a MacBook set to Pill does not wrap its real one. Every read
    /// site is a render decision and wants the resolved answer.
    var hasPhysicalNotch: Bool { islandStyle == .notch }

    /// How much room island content leaves clear at the top.
    ///
    /// A real notch has to be cleared or the content slides under the
    /// camera. A display without one has nothing to clear — but
    /// `placement(on:)` still assigns the fabricated 196×34 default so
    /// the collapsed pill has a shape, and every content site was
    /// reserving that height as if it were hardware. The result was an
    /// empty 34pt band across the top of the island on every external
    /// monitor ("the blank space at the top is not quite right").
    ///
    /// Read by all three content sites so the rule lives in one place
    /// rather than being re-derived from `notchSize` at each of them.
    var contentTopReserve: CGFloat {
        hasPhysicalNotch ? notchSize.height : Theme.Space.m
    }

    /// Set by the window controller so the panel can grab key focus.
    var onExpandChange: ((Bool) -> Void)?

    // MARK: - What the resting island has to say
    //
    // Moved here from NotchRootView (2026-08-01). The bead
    // (NotchWindowController.rebuildSlivers) and the island's own
    // opacity used to each carry a version of "is there anything to
    // show" — the bead asked "collapsed with no toast", the island
    // asked "nothing to say" — and a collapsed island with music
    // playing satisfied the second without satisfying the first, so
    // both drew on the same display. `islandIsShowing` below is the
    // one place either can ask it now.
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
    /// `stale` is deliberately excluded: a session Chalant has only
    /// inferred is quiet is not something to put a live mark next to.
    /// `idle` is deliberately excluded too, on purpose and not an
    /// oversight: the sessions strip lists an idle session (you cannot
    /// pick what is not listed), but this count stays "things are
    /// happening" rather than becoming "things exist" — a badge that
    /// grows every time a terminal sits at its prompt would say less,
    /// not more.
    var agentGlance: (count: Int, waiting: Bool)? {
        guard UserDefaults.standard.object(forKey: "glanceAgents") as? Bool ?? true else {
            return nil
        }
        let live = sessions.sessions.filter { $0.state == .working || $0.state == .needsInput }
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
    var showsSongBeside: Bool {
        let collapsedSong = UserDefaults.standard.object(forKey: "collapsedSong") as? Bool ?? true
        return islandStyle == .pill
            && collapsedSong
            && state == .collapsed
            && music.nowPlaying?.isPlaying == true
    }

    /// Each wing earns exactly what its content needs: the session
    /// mark wants 26 (digits clipped at real pomodoro widths, so the
    /// wing wears a symbol that cannot: the ring, or the stopwatch
    /// glyph; user, 2026-07-22), the slimmed wave takes 28. Quiet
    /// mode keeps the bare pill and lets the rim carry it (both moods
    /// proved real within one day, so it's a setting).
    var leftWingNeed: CGFloat {
        if showsSongBeside { return 156 }
        let playingSignal = UserDefaults.standard
            .object(forKey: MusicController.playingSignalKey) as? String
            ?? MusicController.playingSignalDefault
        if playingSignal == "wave", music.nowPlaying?.isPlaying == true { return 28 }
        let glanceSession = UserDefaults.standard.object(forKey: "glanceSession") as? Bool ?? true
        if glanceSession, sessionActive, !sessionOnRight { return 26 }
        return 0
    }

    /// The glance that has earned the space beside the notch.
    ///
    /// Precedence is the user's list rather than the order these
    /// happen to be written in, since only one of them fits and which
    /// one matters more is a matter of taste, not of code.
    var winningCollapsedItem: CollapsedItem? {
        layout.layout.collapsed.first { collapsedWidth($0) > 0 }
    }

    /// What a glance needs, and nothing if it has nothing to say. One
    /// function so the width and the decision to show it can never
    /// disagree — a glance with no width has nowhere to sit, which is
    /// how the charge shipped invisible.
    func collapsedWidth(_ item: CollapsedItem) -> CGFloat {
        switch item {
        case .agents:
            return agentGlance != nil ? 44 : 0
        case .timers:
            return sessionOnRight ? 30 : 0
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

    /// Width the right-of-camera glance needs on notched displays.
    var notchSideNeed: CGFloat {
        if glanceToast != nil { return 124 }
        // Nothing beyond the user's list: the day, the streak, and the
        // clock glances all duplicated surfaces that already exist (the
        // menu bar clock sits an inch away), and every one of them
        // stretched the pill past the hardware (user, 2026-07-23, "it
        // should not be too wide on the Mac").
        return winningCollapsedItem.map(collapsedWidth) ?? 0
    }

    /// Anything the resting island would actually draw.
    var collapsedHasSomethingToSay: Bool {
        glanceToast != nil || leftWingNeed > 0 || notchSideNeed > 0
            || (ambience.active != nil && music.nowPlaying?.isPlaying != true)
    }

    /// The island is putting pixels on this display right now.
    ///
    /// One answer, read by the island's own opacity and by the bead.
    /// They used to carry a rule each — the bead asked "collapsed
    /// with no toast", the island asked "nothing to say" — so a
    /// collapsed island with a song playing drew its pill AND the
    /// bead on the same display (2026-08-01).
    var islandIsShowing: Bool {
        switch islandStyle {
        case .off: return false
        // A notch island dresses hardware; it is drawn whether or not
        // it has anything to say. `.auto` never reaches here,
        // `placement(on:)` resolves it, but the switch has to be whole.
        case .auto, .notch: return true
        case .pill: return state != .collapsed || collapsedHasSomethingToSay
        }
    }

    init() {
        focus = FocusController(ambience: ambience)
        timer.onComplete = { [weak self] minutes in
            guard let self else { return }
            self.focusStats.recordSession(minutes: minutes)
            self.flashGlance("timer done")
        }
        focus.onBreakComplete = { [weak self] round in
            self?.flashGlance("break's over · round \(round)")
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
        sessionDiscovery.start()
        sessionRegistry.start()
        cursorDiscovery.start()
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
                    self.isDropTargeted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.isDropTargeted = false
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

    /// `takeKey: false` for drag-driven opens: grabbing key focus in
    /// the middle of someone's drag yanks their app around.
    func expand(takeKey: Bool = true) {
        // Switched off on this screen. Refused here rather than hidden
        // in the view: hover is tracked by the window controller against
        // screen zones, not by the island's own hit testing, so an
        // invisible island would still open under the pointer.
        guard islandStyle != .off else { return }
        guard state != .expanded else { return }
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
        tab = stored.flatMap { Self.isAvailable($0, in: defaults) ? $0 : nil } ?? .today
    }

    /// Whether a tab is somewhere the island can open onto right now:
    /// its tool has not been switched off in settings.
    static func isAvailable(_ tab: Tab, in defaults: UserDefaults = .standard) -> Bool {
        guard let key = tab.toolKey else { return true }
        // An unset flag means the tool ships on, matching the
        // @AppStorage defaults the settings window declares.
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
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

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            // The reader arrived; the voice answer is theirs now.
            answerCollapseWork?.cancel()
            answerCollapseWork = nil
            let expandOnHover = UserDefaults.standard
                .object(forKey: "expandOnHover") as? Bool ?? true
            if state == .collapsed, expandOnHover { expand() }
        } else if state == .expanded {
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

    func beginListening() {
        guard state == .collapsed else { return }
        startListening()
    }

    /// Mic button in the expanded island: tap to talk, tap to run.
    func toggleListening() {
        if state == .listening {
            endListening()
        } else {
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
        // Leave listening immediately, finalization can take a second
        // and lingering in the listening UI reads as "release didn't
        // work". Dots show while the transcript settles.
        tab = .ask
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
                self.answer = why
                // Empty sessions were the only unlogged outcome, and
                // exactly the ones every mystery report is made of.
                self.logVoice(
                    "(nothing)",
                    outcome: "\(why) [ear: \(self.voice.activeDeviceName ?? "unknown"),"
                        + " \(self.voice.deviceNote)]"
                )
            } else {
                self.submit(spoken)
                self.lastHeard = spoken
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
    func cancelListening() {
        guard state == .listening else { return }
        voice.cancel()
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
        dragExpanded = false
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
