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
        /// Hold-to-dictate is live. A SIBLING of `.listening`, never a reuse:
        /// `.listening` runs `voice.begin()`, which starts VoiceController's
        /// own recognizer, and two engines listening at once is the
        /// doubled-text failure the dictation merge exists to end.
        case dictating
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

        /// Whether this destination has a full-height form worth giving
        /// the island's whole panel to.
        ///
        /// Sessions first, and alone for now: it is the destination
        /// most starved of room, and the one this pattern is being
        /// proven on before it is spent anywhere else.
        var canFocus: Bool { self == .sessions }

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
        /// A text just arrived and the island is offering the reply.
        /// Like `.welcome`, it takes the panel for as long as it is up.
        case message
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

    /// A microphone owns the island right now: a voice-command session, or a
    /// hold-to-dictate strip.
    ///
    /// Every guard that exists to stop something expanding over a live capture
    /// has to ask this rather than naming `.listening` alone. `.dictating`
    /// strands worse than `.listening` does: `endDictating()` guards on the
    /// state, so an expansion landing mid-hold makes the key-up a no-op,
    /// `restoreTheRoom()` never runs, and the music stays paused with nothing
    /// left that would ever start it again.
    /// A hold the message card hosts never enters `.dictating` (the card
    /// is its surface), and it is every bit as live: nothing may expand
    /// over it either.
    var micIsLive: Bool { state == .listening || state == .dictating || cardDictationLive }

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
    @Published var tab: Tab = .today {
        didSet {
            // A panel shortcut or a dropped file asked for somewhere else
            // while a message card held the panel. The card drew over the
            // destination, so the shortcut did nothing anyone could see,
            // and the card's fade then threw the destination away too.
            guard pane == .message, state == .expanded, oldValue != tab else { return }
            stepMessageAside()
        }
    }

    /// The one destination the island has given its whole height to,
    /// or nil for the ordinary expanded island.
    ///
    /// Hover opens a glance; a click opens this. Those two gestures are
    /// the difference between "what is happening" and "I am working in
    /// here", and only the second one has any business being tall. The
    /// island already lives inside a 720pt panel and spends 288 of it,
    /// so the room this needs is room it has been leaving on the floor.
    @Published var focusedTab: Tab?

    /// Give a destination the whole panel. Sets `tab` too, so leaving
    /// again lands on the thing that was being worked in rather than
    /// wherever the island happened to be before.
    func focus(on destination: Tab) {
        tab = destination
        focusedTab = destination
    }

    func unfocus() { focusedTab = nil }
    @Published var pane: Pane = .none {
        didSet {
            // The one place a message card is let go of. `pane` can be
            // changed from a dozen places (collapse, the tour, its replay,
            // whatever is added next), and a card left behind with words in
            // it blocked every later message as "mid-reply" until relaunch.
            if oldValue == .message, pane != .message { tearDownMessage() }
        }
    }

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
        configWidth: CGFloat, tab: Tab, pane: Pane, chatFull: Bool, focused: Bool = false
    ) -> CGFloat {
        // A floor, never an override, and the wider of the two floors
        // wins: a user who has already dialled past 820 keeps their
        // width and the room simply gets a longer reading column.
        //
        // 820 is what two panes need. The rail is a fixed 280 and does
        // not grow with the island (sidebars do not), so everything past
        // it lands in the conversation: at the widest padding this still
        // leaves 456 there, about 68 characters, which is a real measure
        // rather than a column of broken lines.
        if focused { return max(configWidth, 820) }
        return tab == .chat && pane == .none && chatFull ? max(configWidth, 680) : configWidth
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

    // MARK: - A text arrives

    /// The message waiting on the island, and the reply being written
    /// into it. See `MessageReply` for the rules it keeps.
    let messages = MessageReply()
    private let messageWatch = MessageWatch()
    /// Whether the island was already open when the message arrived.
    /// Closing the card puts it back the way it was found rather than
    /// collapsing something the user had deliberately opened.
    private var islandWasOpenBeforeMessage = false

    /// The card's mic button is physically down. It decides one thing:
    /// whether a dictation reveal belongs to the card (and leaves the
    /// island as it is) or to somebody's Option hold (and gets the strip).
    /// While it is down the Option key is refused by `PushToTalk.press`, so
    /// no foreign hold can be mistaken for the card's.
    ///
    /// It points dictation at NOTHING. The first two builds borrowed the
    /// tour's global landing slot, for the card's life and then for one
    /// press plus a patience timer, and both leaked: an Option hold could
    /// land in the card, and a card closed mid-finalize typed the private
    /// reply into the front app. The words now travel with the press that
    /// heard them (`Dictation.press(landingIn:)`), and if the card has gone
    /// by the time they arrive they are dropped, never typed.
    private(set) var cardMicDown = false
    /// The mic is live on the card's behalf, with the island left
    /// exactly as it was. Set in `beginDictating`, cleared in
    /// `endDictating`.
    private var cardDictationLive = false
    /// Whether this press ever went live. A hold the controller refused
    /// (model still downloading, microphone not granted) never does, and
    /// the card has to say so rather than claim to be listening.
    private var cardPressWentLive = false
    /// A reply was in progress when somebody's own Option hold took the
    /// island for its strip. The card comes back when that hold ends.
    private var restoreCardAfterHold = false

    /// Start listening for incoming iMessages, if there is an island
    /// for them to land on. A dictation-only Chalant has no island and
    /// no doors into one, so it gets no watcher either rather than a
    /// card that can never be shown.
    private func watchForMessages() {
        guard ChalantRole.current != .dictation else { return }
        messageWatch.onSighting = { [weak self] sighting in
            self?.showMessage(sighting)
        }
        messageWatch.start()

        // The watch lives inside another process's window tree, so it
        // dies with that process. macOS restarts NotificationCenter
        // rarely, but a watcher that goes quietly deaf until the next
        // relaunch is the worst kind of bug to report: everything looks
        // fine and nothing arrives.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.notificationcenterui" else { return }
            MainActor.assumeIsolated {
                self?.messageWatch.stop()
                self?.messageWatch.start()
            }
        }
    }

    /// When a message may take the island, as plain values so the rule
    /// can be tested without building a model (the `IslandFace`
    /// convention).
    static func messageMayShow(
        role: ChalantRole, micIsLive: Bool, expanded: Bool, midInteraction: Bool,
        welcomeIsUp: Bool = false, cardMidReply: Bool = false,
        showingIdleCard: Bool = false
    ) -> Bool {
        messageBlockReason(
            role: role, micIsLive: micIsLive, expanded: expanded,
            midInteraction: midInteraction, welcomeIsUp: welcomeIsUp,
            cardMidReply: cardMidReply, showingIdleCard: showingIdleCard
        ) == nil
    }

    /// The same rule, saying which part of it stopped the card. `nil`
    /// means it may show.
    ///
    /// - A dictation-only Chalant has no island to pop from.
    /// - Mid-hold, the card stays away entirely: expanding over a live
    ///   dictation leaves the room ducked forever (`micIsLive`), and no
    ///   message is worth eating somebody's sentence.
    /// - The welcome tour keeps the island to itself.
    /// - **Mid-reply, the card is not replaced.** Somebody is answering
    ///   the last message; a newer one taking the card would throw their
    ///   words away, or leave them sitting under the wrong name.
    /// - Already open and in use by something else: replacing what
    ///   somebody is in the middle of is an interruption, not an offer.
    ///   An UNANSWERED message card is not "in use": that is the one
    ///   case where newest wins. The first build counted its own card as
    ///   the island being busy, so the second text of a burst never
    ///   showed and "newest wins" was dead code.
    static func messageBlockReason(
        role: ChalantRole, micIsLive: Bool, expanded: Bool, midInteraction: Bool,
        welcomeIsUp: Bool = false, cardMidReply: Bool = false,
        showingIdleCard: Bool = false
    ) -> String? {
        if role == .dictation { return "dictation-only" }
        if micIsLive { return "mid-hold" }
        if welcomeIsUp { return "welcome-tour" }
        if cardMidReply { return "mid-reply" }
        if expanded, midInteraction, !showingIdleCard { return "island-in-use" }
        return nil
    }

    private func showMessage(_ sighting: MessageWatch.Sighting) {
        let blocked = Self.messageBlockReason(
            role: ChalantRole.current,
            micIsLive: micIsLive || cardMicDown,
            expanded: state == .expanded,
            // A focused island draws one destination and nothing else,
            // so a card mounted there was never drawn while the log
            // said "shown". It was opened on purpose; it is in use.
            midInteraction: isMidInteraction || focusedTab != nil,
            welcomeIsUp: pane == .welcome,
            cardMidReply: messages.isMidReply,
            showingIdleCard: pane == .message && messages.isShowing && !messages.isMidReply
        )
        // Nothing about the message itself, only what became of it.
        WireLog.note(
            event: "message-card", ntype: blocked ?? "shown",
            tool: "messages", response: blocked == nil ? "card up" : "no card"
        )
        guard blocked == nil else { return }
        // A card replacing a card keeps what it was told the first time.
        let replacing = pane == .message
        if !replacing { islandWasOpenBeforeMessage = state == .expanded }
        messages.onAimed = { answer in
            WireLog.note(
                event: "message-aim", ntype: MessageReply.summary(of: answer),
                tool: "messages", response: "")
        }
        messages.show(sighting) { [weak self] in self?.closeMessage() }
        pane = .message
        // Already open: the card goes where the island already is. Asking
        // to expand again can mean a hand-off to another display, which is
        // a collapse and an expansion, and the collapse would take the card
        // just shown with it and leave a bare island open (two displays).
        guard state != .expanded else { return }
        // `takeKey: false`, and this is the whole difference between a
        // notification and an interruption. A card that appeared on its
        // own may never take the keyboard: the founder was typing in a
        // terminal once and their keystrokes stopped arriving
        // (2026-08-03). Clicking the reply field still focuses it,
        // because a click is being asked.
        expand(takeKey: false)
    }

    /// The card's mic button went down.
    func messageTalkPress() {
        guard let asked = messages.sighting, Dictation.shared.isRunning,
              !cardMicDown else { return }
        messages.talkPressed()
        guard messages.phase == .listening else { return }
        cardMicDown = true
        cardPressWentLive = false
        Dictation.shared.press { [weak self] text in
            // Delivered by the session that heard it. `heard` drops the
            // words if this card has gone or belongs to someone else now.
            self?.messages.heard(text, for: asked)
        }
    }

    /// The button came up. `held` is false for a click that was never a
    /// hold: nothing was said, so nothing should be waited for.
    func messageTalkRelease(held: Bool) {
        guard cardMicDown else { return }
        cardMicDown = false
        Dictation.shared.practiceRelease()
        if held, !cardPressWentLive {
            // Held long enough to have gone live, and never did: the
            // controller refused it. Saying "Got it" now would be a lie.
            messages.talkRefused()
        } else {
            messages.talkReleased(held: held)
        }
    }

    /// Everything the card holds, let go. Every way the card can leave
    /// ends here, because `pane` itself calls it on the way out of
    /// `.message`: the X, the fade, a send, a click elsewhere, a hotkey,
    /// the tour, anything added later. The first build cleaned up only on
    /// the exits it had thought of.
    private func tearDownMessage() {
        if cardMicDown {
            cardMicDown = false
            Dictation.shared.practiceRelease()
        }
        restoreCardAfterHold = false
        messages.dismiss()
    }

    /// Something else wants the panel. An unanswered card gives it up
    /// without closing the island; a reply in progress keeps it and says
    /// so, because a draft is never the price of a shortcut.
    @discardableResult
    private func stepMessageAside() -> Bool {
        guard pane == .message else { return true }
        if messages.isMidReply || cardMicDown || cardDictationLive {
            messages.note("Finish this reply, or close it, first.")
            return false
        }
        pane = .none
        islandWasOpenBeforeMessage = false
        return true
    }

    /// The card goes: faded, dismissed, or sent.
    func closeMessage() {
        guard pane == .message else { return tearDownMessage() }
        let wasOpenBefore = islandWasOpenBeforeMessage
        pane = .none   // tears the card down on its way out
        islandWasOpenBeforeMessage = false
        // An island the user had open stays open, but only while they are
        // still there. Hover-out is ignored for as long as a card is up, so
        // an island that was hover-opened and then left would otherwise
        // stay open with nothing left to close it.
        if !wasOpenBefore || !isHovering { collapse() }
    }

    /// An untouched card is not the user's doing, so their next click in
    /// whatever they are working on must not kill it: the first build's
    /// "thirty seconds" really lasted until the next mouse click in any
    /// app. Once they have touched it, clicking away means what it
    /// always means.
    var clickAwayMayCollapse: Bool {
        pane != .message || messages.engaged
    }

    /// The way forward the card always has: the conversation itself. Any
    /// words already written go with it, so "reply in Messages" never
    /// costs the reply.
    func openMessageInMessages() {
        var target = URL(fileURLWithPath: "/System/Applications/Messages.app")
        if case .known(_, let thread) = messages.recipient {
            let handle = thread.handle
            var parts = URLComponents()
            parts.scheme = "sms"
            parts.path = handle
            let draft = messages.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.isEmpty { parts.queryItems = [URLQueryItem(name: "body", value: draft)] }
            if let direct = parts.url { target = direct }
        }
        NSWorkspace.shared.open(target)
        closeMessage()
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
        crashWatch.markSeenNow() // shown is seen; the card and verbs still work this session
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

    /// Words that could not be typed, and what can still be done with them.
    ///
    /// **A toast could not carry this and was already failing to carry
    /// less.** Every insertion failure funnels into `flashGlance`, which draws
    /// one `lineLimit(1)` line in a notch wing reserving 124 pt, and all four
    /// existing sentences are 45 to 70 characters: they have been clipped for
    /// as long as they have existed. "Your words are on the clipboard" needs
    /// to be actionable, not truncated, so it gets a glance of its own with
    /// the two things a person wants: the text, and another go at putting it
    /// where they meant.
    struct Recovery: Identifiable, Equatable {
        let id = UUID()
        /// What was said. Also on the clipboard, always, before this appears.
        let text: String
        /// Why it did not land, in one short phrase that fits.
        let reason: String
        /// Another attempt at the app in front right now, when one makes
        /// sense. Nil when there is nothing to retry into.
        let retry: (@MainActor () -> Void)?

        static func == (a: Recovery, b: Recovery) -> Bool { a.id == b.id }
    }

    @Published var dictationRecovery: Recovery?
    private var recoveryClearWork: DispatchWorkItem?

    /// Show the recovery glance. Thirty seconds, not the toast's six: this one
    /// asks the user to do something, and six seconds is not long enough to
    /// notice a line in a notch wing and decide to act on it.
    func offerRecovery(_ recovery: Recovery, seconds: TimeInterval = 30) {
        recoveryClearWork?.cancel()
        dictationRecovery = recovery
        let work = DispatchWorkItem { [weak self] in
            guard self?.dictationRecovery?.id == recovery.id else { return }
            self?.dictationRecovery = nil
        }
        recoveryClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Put the words back on the clipboard, in case something has been copied
    /// since they were rescued there.
    func copyRecoveredText() {
        guard let text = dictationRecovery?.text else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        flashGlance("Copied.")
        clearRecovery()
    }

    func clearRecovery() {
        recoveryClearWork?.cancel()
        recoveryClearWork = nil
        dictationRecovery = nil
    }
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
    let weather = WeatherController()
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

    /// Grants and the record of what was settled without asking.
    let policy = PolicyStore()
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
        // No badge for a dark-shipped surface: a count you cannot open
        // is an itch with nothing to scratch it.
        guard FeatureFlags.sessionsVisible else { return nil }
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
        // Wider than a toast, because it carries two buttons as well as a
        // line. Still a wing rather than a panel: law 2, and the founder has
        // already rejected one object that appeared over their work.
        if dictationRecovery != nil { return 210 }
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
        // The sessions clause holds only while the surface exists: an
        // island that un-hides itself for a question nobody can see or
        // answer would be the worst of both worlds (the dark-ship,
        // FeatureFlags).
        (FeatureFlags.sessionsVisible && sessions.sessions.contains { session in
            session.state == .needsInput
                || (session.ask.map { !$0.isFullyAnswered } ?? false)
        }) || activities.activities.contains { $0.state == .needsInput }
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
        watchForMessages()
        clipboard.start()
        stats.start()
        shortcuts.announce = { [weak self] message in
            self?.flashGlance(message)
        }
        // Before the server opens its door, so the first gated call of
        // the session already sees what the old key held. Runs once:
        // the migration empties the key it reads.
        policy.migrateLegacyExceptions(from: .standard)
        // The dark-ship reaches the wire too: a store that surfaces no
        // cards makes every /hook hold answer with silence at once, so
        // an upgrader whose hooks are still armed loses only the card,
        // never ten minutes (FeatureFlags).
        sessions.surfacesCards = FeatureFlags.sessionsVisible
        activityServer.start(store: activities, sessions: sessions, policy: policy)
        // Registry first: it lists four small JSON files and can paint
        // a session row immediately. Discovery scrapes transcript tails
        // and can walk the filesystem to resolve a cwd, which is slow
        // enough to be visible (B3, founder 2026-08-02: "sometimes they
        // take a second to load all the sessions"). Its own first scan
        // is deferred so it decorates rows the registry already showed,
        // rather than making everyone wait for it to go first.
        // And discovery now only reads the transcripts of sessions the
        // registry vouches for, so it has to be told the moment that list
        // grows rather than waiting out its own twenty-second clock.
        // Dark-shipped sessions start no watchers at all: no registry
        // sweep, no transcript scraping, no rows to announce. The
        // hidden feature has to cost what a deleted one would.
        if FeatureFlags.sessionsVisible {
            sessionRegistry.onLiveSetChanged = { [weak self] in
                self?.sessionDiscovery.refresh()
            }
            sessionRegistry.start()
            sessionDiscovery.start()
            cursorDiscovery.start()
        }
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
        // The same law for the announcements: none of these may fire
        // while sessions are dark-shipped, because every one of them
        // ends by steering the island to a tab that no longer exists.
        // With the watchers above off the store stays empty and they
        // could not fire anyway; the gate makes that a promise rather
        // than a coincidence (a held hook can still write to the store
        // through the server).
        if FeatureFlags.sessionsVisible {
            sessions.onSessionCameToRest = { [weak self] id, title in
                guard let self, self.opensWhenAnAgentFinishes else { return }
                self.flashGlance("\(title) finished", seconds: 6)
                // Same restraint as a question: never over a live mic, and
                // never over an island already busy with something. A turn
                // ending is worth showing, and it is not worth taking the
                // screen away from whatever is already being typed into.
                // Both mics, not just the voice one: expanding over a
                // dictation hold leaves the room ducked forever (`micIsLive`).
                guard !self.micIsLive else { return }
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
                // A dictation hold counts as a live capture here too, and
                // for a worse reason: see `micIsLive`.
                guard !self.micIsLive else { return }
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
        }
        events.startGlanceTicker()
        // Unset means on: a fresh install shows the weather line, same
        // default the toggle itself carries in Settings.
        if WeatherController.showsWeather() {
            weather.start()
        }
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
                // "debug message Sam|are you coming" pops the reply card
                // as if a text had arrived. The card needs no banner to
                // be looked at, and a real one cannot be produced on
                // demand: it takes a second person and a phone.
                if text.hasPrefix("debug message ") {
                    let parts = text.dropFirst("debug message ".count)
                        .split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    self.showMessage(MessageWatch.Sighting(
                        sender: parts[0], body: parts[1], seen: Date()))
                    return
                }
                // "debug reply words" fills the card's reply field, since
                // keystrokes cannot be injected into a panel that never
                // takes focus by itself.
                if text.hasPrefix("debug reply ") {
                    self.messages.touch()
                    self.messages.draft = String(text.dropFirst("debug reply ".count))
                    return
                }
                // "debug aim Name" reports which thread a banner name
                // would be answered in, and over which service, without
                // sending anything. The one check that cannot be faked:
                // it runs against the real Messages on this Mac.
                if text.hasPrefix("debug aim ") {
                    let sender = String(text.dropFirst("debug aim ".count))
                    Task { @MainActor in
                        let threads = await MessageCourier.conversations()
                        let answer = MessageCourier.conversation(named: sender, in: threads)
                        var line = "threads=\(threads.count) "
                        switch answer {
                        case .one(let found):
                            line += "-> \(found.service) \(found.id)"
                        case .several: line += "-> refused: several"
                        case .none: line += "-> refused: none"
                        }
                        WireLog.note(event: "debug-aim", tool: "messages", response: line)
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
                    self.welcomeStep = min(WelcomeView.stepCount - 1, max(0, Int(tail) ?? 0))
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
        // Dictation-only Chalant has no doors: hover, hotkeys and clicks all
        // arrive here, and none of them may open an island the user chose
        // not to have. The one exception is the welcome tour, which is how
        // the role gets chosen in the first place (one app, two faces;
        // founder, 2026-08-20).
        guard ChalantRole.current != .dictation || pane == .welcome else { return }
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
        } ?? landing
    }

    /// The front door, asked fresh each time: a grant given since the
    /// last open should bring Today straight back.
    private var landing: Tab {
        let defaults = UserDefaults.standard
        // Both ship on (unset means on, EventKitService's one rule);
        // an explicit false from the settings window is honoured.
        let seesCalendar = EventKitService.showsCalendar(in: defaults) && !events.calendarDenied
        let seesReminders = EventKitService.showsReminders(in: defaults) && !events.remindersDenied
        return Self.landingTab(todayCanSee: seesCalendar || seesReminders, in: defaults)
    }

    /// Where the island opens when nothing else decides it.
    ///
    /// Today, almost always. But Today with no calendar and no reminders
    /// is a sentence telling you to go and change a setting, and that
    /// was the most-seen screen in the app: every open landed on it. A
    /// front door should have something behind it.
    ///
    /// Diverted only on positive knowledge of both denials, the same
    /// rule the session registry follows. One of the two still granted
    /// leaves Today with real content and one honest line beside it,
    /// which is information rather than a dead end.
    ///
    /// The fallback is a preference order rather than the next tab
    /// along: `ask` sits second in the switcher and is empty until
    /// something asks, so falling through to it would trade one blank
    /// screen for another. Clipboard leads because it is the one surface
    /// that fills itself.
    /// `todayCanSee` is whether any source Today draws from is both
    /// switched on and permitted. Not merely "not denied": a calendar
    /// the user turned off in settings is just as invisible as one macOS
    /// is withholding, and either way Today has nothing behind it.
    static func landingTab(todayCanSee: Bool, in defaults: UserDefaults = .standard) -> Tab {
        if todayCanSee, isAvailable(.today, in: defaults) { return .today }
        let preferred: [Tab] = [.clipboard, .sessions, .focus, .notes, .shelf, .links, .chat]
        return preferred.first { isAvailable($0, in: defaults) } ?? .today

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
        // A dark-shipped tab is nowhere, whatever its settings switch
        // says: the switch itself is hidden with it (FeatureFlags).
        if tab == .sessions, !FeatureFlags.sessionsVisible { return false }
        if tab == .chat, !FeatureFlags.chatVisible { return false }
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
        // Whatever closed the island closed the card with it: a click
        // elsewhere, Escape, the hotkey, the gear. Every one of those
        // used to leave the card's mic or its dictation landing behind.
        if pane == .message { islandWasOpenBeforeMessage = false }
        state = .collapsed
        pane = .none   // leaving `.message` lets the card go (see `pane`)
        focusedTab = nil
        // The island always reopens small and clean, unless the user
        // asked it to reopen where they left off.
        if UserDefaults.standard.bool(forKey: Self.rememberLastTabKey) {
            UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
        } else {
            tab = landing
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
            // A focused island was opened on purpose and closes on
            // purpose. Letting the pointer drift out of it would break
            // the one thing it exists for: reading something long and
            // typing a reply, neither of which can be done inside a
            // rectangle you must not leave. The click-away monitor and
            // the back button are its exits.
            guard focusedTab == nil else { return }
            // A message card has its own life. The pointer drifting
            // across it and away again is somebody reading, not leaving.
            guard pane != .message else { return }
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
            // The focused island is exempt for the same reason Chat is,
            // only more so: it was opened by a click rather than a
            // hover, and nothing a pointer does should end it. Guarded
            // here as well as at the call site, because a timer that
            // was already in flight does not care what the call site
            // decided afterwards.
            guard self.state == .expanded, !self.isHovering,
                  !self.isWorking, self.focusedTab == nil,
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

    /// How the live session was started. The two are finished in
    /// opposite ways and the caption has to say which: a hold ends when
    /// the finger lifts, a tap ends on a second tap. Telling somebody
    /// who clicked a mic to "release to run" leaves them holding
    /// nothing, watching their words pile up with no way to send them.
    enum VoiceEntry { case held, tapped }

    /// Set by whichever entrance started the session, like
    /// `voiceDestination`, and read only while `state == .listening`.
    @Published private(set) var voiceEntry: VoiceEntry = .held

    /// What ends the live session, in the words the caption uses. The
    /// whole listening surface is the tap target
    /// (`NotchRootView.listeningContent`), so a tapped session is
    /// finished by clicking anywhere on it, not by finding the mic
    /// again: `ExpandedView` is unmounted while listening and the mic
    /// is not on screen to be found.
    var listeningFinishHint: String {
        VoiceDoor.finishHint(held: voiceEntry == .held)
    }

    /// Which session's compose card is open in the strip, if any. Lives
    /// here rather than as the strip's own view state: the composer's
    /// mic sends the whole island through `.listening`, which unmounts
    /// `ExpandedView`, taking the strip with it, exactly as it does for
    /// the persistent mic. View-local state does not survive that round
    /// trip; `tab` and `draftPrompt` live here for the same reason.
    @Published var composingSessionID: String?

    /// Which session the room has open on its right-hand side.
    ///
    /// An id, never an index. The store re-sorts the instant any
    /// session's state changes, and it changes constantly: a session
    /// moving from Working to Needs you would pull a different row under
    /// the pointer of somebody who was about to click, and an
    /// index-keyed selection would silently start showing them a
    /// different conversation than the one they were reading.
    ///
    /// Lives here rather than in the room for the same reason
    /// `composingSessionID` does: the composer's mic sends the island
    /// through `.listening`, which unmounts `ExpandedView` and every
    /// piece of view-local state under it.
    @Published var selectedSessionID: String?


    func beginListening(to destination: VoiceDestination = .chalant) {
        // The voice door belongs to the island; dictation-only keeps only
        // the hold-to-dictate ear.
        guard ChalantRole.current != .dictation else { return }
        guard state == .collapsed else { return }
        voiceDestination = destination
        voiceEntry = .held
        startListening()
    }

    /// Mic button in the expanded island: tap to talk, tap to run.
    /// `to:` defaults to `.chalant`, so the ask bar's mic, the `.talk`
    /// hotkey and the collapsed long press all keep their exact
    /// behaviour without being touched.
    func toggleListening(to destination: VoiceDestination = .chalant) {
        // A dictation hold already owns the ear. Anything not `.listening`
        // used to mean "start", which sent a hold straight into
        // `startListening()` and `voice.begin()`: two recognizers at once,
        // the doubled-text failure the sibling state exists to prevent.
        // Refused out loud, because a mic that does nothing and says nothing
        // is the other half of that same bug.
        if state == .dictating || cardMicDown || cardDictationLive {
            Self.log.notice("talk refused: a dictation hold has the microphone")
            return
        }
        if state == .listening {
            endListening()
        } else {
            voiceDestination = destination
            voiceEntry = .tapped
            startListening()
        }
    }

    // MARK: - Dictating

    /// What the strip shows beside the level: where the words are going and
    /// which ear is live.
    struct DictationInfo: Equatable {
        var appName: String
        var micName: String?
    }

    /// The voice, 0...1, driven by DictationController's meter timer and
    /// smoothed by `DictationStripLevel.Voice` (quick to answer, slow to let
    /// go), and how much of the sentence has been said, which is what spreads
    /// the lit edge. The view draws from these two and nothing else.
    @Published var dictationLevel: CGFloat = 0
    @Published var dictationFill: CGFloat = 0
    /// The syllable (1 the tick a word lands, gone in ~0.1 s), the speaker's
    /// gear (0 unhurried to 1 quick), and the onset counter the view fires a
    /// glint on. All three live in `DictationStripLevel.Voice`; the view
    /// draws from these and nothing else.
    @Published var dictationPulse: CGFloat = 0
    @Published var dictationPace: CGFloat = 0
    @Published var dictationBeat: Int = 0
    /// The pool's life: a phase that never stops advancing while the strip
    /// listens, slow in a pause, quick under voice.
    @Published var dictationSway: CGFloat = 0
    @Published var dictationInfo: DictationInfo?
    private var dictationVoice = DictationStripLevel.Voice()
    /// The meter is a fixed 30 Hz timer (`DictationController.startMeter`),
    /// so the voice is stepped by that interval rather than by a wall clock:
    /// deterministic under test, and timer jitter is invisible in a light.
    private static let dictationTick: TimeInterval = 1.0 / 30

    /// Open the strip. Owns a display like an expansion does, ducks the room
    /// like listening does, and touches nothing on `voice`.
    func beginDictating(into appName: String, mic: String?, on display: CGDirectDisplayID?) {
        // A live voice session is the one thing the strip may not take over:
        // two recognizers at once is the failure this state exists to prevent.
        // An expansion, though, is fair game. Refusing it reproduced the exact
        // complaint the strip was built for: an agent finishes, the island
        // opens by itself, the founder holds Option and sees nothing at all.
        guard state != .listening else { return }
        // The card's own mic button started this hold, so the card IS the
        // surface. The first build let the strip take over here, which
        // pulled the card out from under the finger holding it and then
        // collapsed the island, so the words landed on a card nobody
        // could see and a reply could never be finished.
        if cardMicDown, pane == .message, state == .expanded {
            cardPressWentLive = true
            dictationVoice.reset()
            dictationLevel = 0
            dictationFill = 0
            dictationPulse = 0
            dictationPace = 0
            quietTheRoom()
            cardDictationLive = true
            return
        }
        // A hold aimed anywhere else while a card is up: the person is
        // busy with their own sentence. The card steps aside completely
        // rather than sharing a screen with the strip.
        if pane == .message {
            if messages.isMidReply {
                // Their own sentence, into their own editor, exactly as
                // rule 3 says. But a reply half written must not be the
                // price of it: the strip borrows the island, and the card
                // comes back when the hold ends (`endDictating`).
                restoreCardAfterHold = true
            } else {
                pane = .none
                islandWasOpenBeforeMessage = false
            }
        }
        // Same handling as `startListening()`: a display already holding the
        // island keeps it unless dictation resolved one of its own, which it
        // usually does, because the strip belongs on the screen showing the
        // app being dictated into.
        if let display {
            expandedDisplayID = display
        } else if expandedDisplayID == nil {
            expandedDisplayID = defaultOwnerDisplay()
        }
        dictationInfo = DictationInfo(appName: appName, micName: mic)
        dictationPhase = .listening
        dictationVoice.reset()
        dictationLevel = 0
        dictationFill = 0
        dictationPulse = 0
        dictationPace = 0
        dictationSway = 0
        quietTheRoom()
        state = .dictating
    }

    /// Whether the strip is hearing you or thinking about what it heard.
    ///
    /// A phase rather than a fifth `IslandState`, deliberately: `.dictating`
    /// already owns the display, the ducked room and the shape, and a new
    /// state would mean teaching every guard in this file and
    /// `ChalantRole.islandHidden` about it for a difference the user reads as
    /// "the light went still".
    enum DictationPhase: Equatable { case listening, working }

    @Published private(set) var dictationPhase: DictationPhase = .listening

    /// The key came up. The room stays quiet, because the words are not there
    /// yet and restoring the music now would announce a finish that has not
    /// happened.
    func finishDictationListening() {
        if cardDictationLive {
            dictationVoice.reset()
            dictationLevel = 0
            dictationPulse = 0
            dictationPace = 0
            return
        }
        guard state == .dictating else { return }
        dictationPhase = .working
        dictationVoice.reset()
        dictationLevel = 0
        dictationPulse = 0
        dictationPace = 0
    }

    func updateDictating(level: CGFloat, mic: String?) {
        guard state == .dictating || cardDictationLive else { return }
        dictationVoice.step(raw: level, dt: Self.dictationTick)
        dictationLevel = dictationVoice.level
        dictationFill = dictationVoice.fill
        dictationPulse = dictationVoice.pulse
        dictationPace = dictationVoice.pace
        dictationBeat = dictationVoice.beat
        dictationSway = dictationVoice.sway
        if let mic, mic != dictationInfo?.micName {
            // The ear can hop mid-hold; the strip must say so in place.
            dictationInfo?.micName = mic
        }
    }

    func endDictating() {
        // A hold the card hosted never entered `.dictating`, so there is
        // no strip to close and no island to collapse. The room was still
        // quieted, though, and has to be given back.
        if cardDictationLive {
            cardDictationLive = false
            restoreTheRoom()
            dictationVoice.reset()
            dictationLevel = 0
            dictationFill = 0
            dictationPulse = 0
            dictationPace = 0
            return
        }
        guard state == .dictating else { return }
        dictationPhase = .listening
        restoreTheRoom()
        dictationVoice.reset()
        dictationLevel = 0
        dictationFill = 0
        dictationPulse = 0
        dictationPace = 0
        dictationInfo = nil
        // The strip can now be entered from an open island, and the island it
        // closes into is a collapsed one. Left true, the music controller
        // would keep polling AppleScript once a second for a surface nobody
        // can see, because `collapse()` only ever runs from `.expanded`.
        music.expandedVisible = false
        state = .collapsed
        expandedDisplayID = nil
        // A reply was in progress when this hold took the island.
        if restoreCardAfterHold {
            restoreCardAfterHold = false
            if pane == .message, messages.isShowing { expand(takeKey: false) }
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
        // A voice session and a message card cannot share the island. An
        // unanswered card steps aside; a reply in progress is never the
        // price of a hotkey, so that one refuses and says why on the card.
        if pane == .message, !stepMessageAside() { return }
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
                  self.pendingContext == nil, self.focusedTab == nil,
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
        // Mid-dictation too: this path ends in `expand()`, which over a hold
        // would leave the room ducked with nothing to restore it (`micIsLive`).
        guard !micIsLive else { return }
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
                // The Chat tab is only worth pointing at while it
                // exists (the dark-ship, FeatureFlags): a promise about
                // a hidden tab is a broken one.
                answer = FeatureFlags.chatVisible
                    ? "That one needs Apple Intelligence, System Settings, Apple Intelligence and Siri. Reminders, notes, timers, focus, calendar, and music all work without it, and the Chat tab carries your own Claude, ChatGPT, or Gemini."
                    : "That one needs Apple Intelligence, System Settings, Apple Intelligence and Siri. Reminders, notes, timers, focus, calendar, and music all work without it."
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
