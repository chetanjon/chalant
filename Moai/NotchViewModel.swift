import AppKit
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum IslandState {
        case collapsed
        case listening
        case expanded
    }

    enum Tab {
        case today
        case ask
        case clipboard
        case shelf
        case links
        case notes
        case focus
    }

    /// Settings slides over the island body; collapsing closes it.
    enum Pane {
        case none
        case settings
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

    private let onboardedKey = "moai.onboarded"

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
    let ambience = AmbienceController()
    let focus: FocusController
    let focusStats = FocusStatsStore()
    let voice = VoiceController()
    let stats = SystemStatsController()
    let shortcuts = ShortcutStore()
    let updates = UpdateChecker()
    private(set) lazy var engine = ActionEngine(model: self)

    /// Default pill for notch-less displays, so Moai works on any Mac.
    static let defaultNotchSize = CGSize(width: 196, height: 34)

    /// Physical notch size measured by NotchWindowController.
    var notchSize = NotchViewModel.defaultNotchSize

    /// True on the built-in display where hardware occupies the middle
    /// of the island; external displays keep that space usable.
    var hasPhysicalNotch = false

    /// Set by the window controller so the panel can grab key focus.
    var onExpandChange: ((Bool) -> Void)?

    init() {
        focus = FocusController(ambience: ambience)
        // Before any view can read the key: legacy plaintext storage
        // moves into the Keychain once.
        KeychainStore.migrateFromDefaults(key: "anthropicKey", account: "anthropicKey")
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
        events.startGlanceTicker()
        updates.onNewVersion = { [weak self] version in
            self?.flashGlance("\(version) is out", seconds: 8)
        }
        updates.start()
        showWelcomeIfFirstRun()
        #if DEBUG
        // Terminal-driven verb testing, Debug builds only. Keystrokes
        // can't be injected into the non-activating panel (they land in
        // the frontmost app), so autonomous verification posts the
        // sentence by distributed notification instead:
        //   Notification name com.cj.moai.debug.submit, text in object.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cj.moai.debug.submit"),
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
                    self.welcomeStep = min(2, max(0, Int(tail) ?? 0))
                    self.pane = .welcome
                    self.expand()
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
                        "shelf": .shelf, "go": .links, "notes": .notes, "focus": .focus,
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
        NSWorkspace.shared.notificationCenter.addObserver(
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
        guard state != .expanded else { return }
        state = .expanded
        if takeKey { onExpandChange?(true) }
    }

    func collapse() {
        guard state == .expanded else { return }
        state = .collapsed
        // The island always reopens small and clean.
        pane = .none
        tab = .today
        onExpandChange?(false)
    }

    // MARK: - Hover opens the island

    private var hoverCollapseWork: DispatchWorkItem?

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
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
            guard self.state == .expanded, !self.isHovering,
                  !self.isWorking, self.draftPrompt.isEmpty,
                  self.pendingContext == nil, self.pane == .none else { return }
            self.collapse()
        }
        hoverCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Voice, hold to talk

    func beginListening() {
        guard state == .collapsed else { return }
        state = .listening
        voice.begin()
    }

    /// Mic button in the expanded island: tap to talk, tap to run.
    func toggleListening() {
        if state == .listening {
            endListening()
        } else {
            state = .listening
            voice.begin()
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
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.isEmpty {
                self.lastHeard = nil
                self.answer = self.voice.failure
                    ?? "Heard nothing. Hold a beat longer next time."
            } else {
                self.submit(spoken)
                self.lastHeard = spoken
            }
        }
    }

    /// The global hotkey: tap to listen from anywhere, tap again to
    /// run. From the answer surface it starts a fresh session.
    func summon() {
        if state == .collapsed {
            beginListening()
        } else {
            toggleListening()
        }
    }

    /// Discard the recording without running anything.
    func cancelListening() {
        guard state == .listening else { return }
        voice.cancel()
        state = .collapsed
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
                return
            }

            // Beyond local verbs, freeform questions go to a model. The
            // Mac's on-device model answers with no key; a cloud provider
            // (added quietly in Settings) takes over only when its key is
            // on file. None of this is surfaced in the island UI.
            let provider = AIProvider.current
            var key = ""
            if provider.needsKey {
                key = KeychainStore.read(provider.keychainAccount) ?? ""
            }
            let ready = provider == .local ? AIService.localModelAvailable : !key.isEmpty
            guard ready else {
                answer = "That one needs a model. Turn on Apple Intelligence, or add a key in Settings. Reminders, notes, timers, focus, calendar, and music all work without one."
                return
            }

            // Loose phrasings become verbs first: the model translates,
            // the same deterministic engine executes. Nobody has to
            // remember the exact words.
            if pendingContext == nil, text.count < 160 {
                isWorking = true
                let verb = await AIService.translateToVerb(
                    text, provider: provider, apiKey: key
                )
                isWorking = false
                if let verb, verb.lowercased() != text.lowercased(),
                   let acted = await engine.handle(verb) {
                    answer = acted
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
                    for try await delta in AIService.stream(
                        prompt: fullPrompt, provider: provider, apiKey: key
                    ) {
                        guard let self else { return }
                        self.answer += delta
                        self.lastStreamActivity = Date()
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
