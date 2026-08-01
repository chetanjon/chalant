import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Borderless panel that can take keyboard focus without activating the app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One dragged pasteboard item, resolved to exactly one flavor.
enum DroppedItem {
    case file(URL)
    case image(NSImage)
    case link(URL)
    case text(String)
}

/// The panel's hosting view, extended to receive drags. Drops must be
/// handled by the island's own (frontmost) window, so the panel level is
/// lowered enough that macOS routes drags to it.
final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onDrop: (([DroppedItem]) -> Void)?
    var onTargeted: ((Bool) -> Void)?
    /// A voice session owns the island; drags are refused outright.
    var acceptsDrop: (() -> Bool)?
    /// The drag crossed into the panel / left it without dropping.
    /// These run synchronously inside the drag callout, so the island
    /// can open under the drag and offer its body as the target,
    /// well clear of Mission Control's top-edge reveal.
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?

    func enableDrops() {
        registerForDraggedTypes([
            .fileURL, .png, .tiff,
            NSPasteboard.PasteboardType(UTType.image.identifier),
            .URL, .string,
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop?() ?? true else { return [] }
        onTargeted?(true)
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrop?() ?? true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
        onDragExited?()
    }

    /// Fires however the session ends, even a drop stolen by another
    /// window (Mission Control's top-edge reveal can do this), so the
    /// accent edge never sticks on after an aborted drag.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        guard acceptsDrop?() ?? true else { return false }
        let items = (sender.draggingPasteboard.pasteboardItems ?? [])
            .compactMap(Self.resolve)
        guard !items.isEmpty else { return false }
        onDrop?(items)
        return true
    }

    /// First matching flavor wins: a Finder image drag also carries
    /// image data, it must land once, as the file. A plain string that
    /// happens to be a URL stays text; only real url flavors are links.
    private static func resolve(_ item: NSPasteboardItem) -> DroppedItem? {
        if let raw = item.string(forType: .fileURL),
           let url = URL(string: raw)?.standardizedFileURL, url.isFileURL {
            return .file(url)
        }
        if let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
           let data = item.data(forType: type),
           let image = NSImage(data: data) {
            return .image(image)
        }
        if let raw = item.string(forType: .URL),
           let url = URL(string: raw), url.scheme != nil, !url.isFileURL {
            return .link(url)
        }
        if let raw = item.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(raw)
        }
        return nil
    }
}

@MainActor
final class NotchWindowController {
    private var panel: NotchPanel?
    private var clickMonitor: Any?
    private var hoverTimer: Timer?
    private var stateSub: AnyCancellable?
    private var toastSub: AnyCancellable?
    private var napActivity: NSObjectProtocol?
    private var pointerInside = false
    /// Drag-in-flight sensing: the drag pasteboard's changeCount moves
    /// when a session begins anywhere in the system.
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBaseline = 0
    private var lastBaselineSample = Date.distantPast
    /// Pending open-intent check; the pointer must linger in the zone,
    /// not just cross it.
    private var openIntentWork: DispatchWorkItem?
    private var lastOpenAt = Date.distantPast
    /// Brief cooldown after any collapse so the island can't bounce
    /// straight back open while the pointer lingers near the notch.
    /// (An exit-before-reopen rule was tried instead and field-failed:
    /// it armed at launch and blocked hover for anyone who parks the
    /// pointer near the notch, see 2026-07-18 diagnostics.)
    private var lastCollapseAt = Date.distantPast
    private let reopenCooldown: TimeInterval = 0.6
    let viewModel = NotchViewModel()

    /// Ignore hover-out this soon after opening, so nothing can cycle.
    private let minimumOpen: TimeInterval = 0.25

    /// Pointer must stay in the open zone this long before the island
    /// opens, drive-through traffic along the top edge never triggers.
    /// User-tunable ("openDelay" in settings). 0.18 over the old 0.12:
    /// the extra beat reads as intent answered, not a startle.
    private var openDwell: TimeInterval {
        UserDefaults.standard.object(forKey: "openDelay") as? Double ?? 0.18
    }

    /// The panel is a fixed transparent region at the top of the screen.
    /// The island animates inside it, so the window never resizes. Its
    /// height must clear the tallest island (Full + a session strip +
    /// the Settings pane measures ~640pt) and its width the chat
    /// island's 840; clear areas hit-test through, so the extra room
    /// costs nothing.
    private let panelSize = CGSize(width: 1000, height: 720)

    /// Everything `placement(on:)` writes onto the view model, as one
    /// comparable value. Kept together so adding a per-display setting
    /// cannot quietly leave the repaint check behind — the failure
    /// there is silent and looks like the setting doing nothing.
    /// `hasPhysicalNotch` used to be one of these; it is now derived
    /// from `islandStyle` (already here), so leaving it out drops
    /// nothing. `islandDisplayID` is here instead: it is per-display
    /// and was the one write `placement(on:)` made that this check
    /// never covered (2026-08-01) — the Displays pane's "island here"
    /// badge would have gone stale exactly like any other silent miss.
    private var islandGeometry: [AnyHashable] {
        [
            viewModel.islandDisplayID, viewModel.notchSize,
            viewModel.islandStyle, viewModel.islandCornerRadius,
            viewModel.islandContentPadding,
        ]
    }

    /// Measure the target screen and compute the panel frame; shared
    /// by first show and every display change after it.
    private func placement(on screen: NSScreen) -> NSRect {
        // This screen's own settings, resolved out of `.auto` against
        // what the hardware actually reports.
        let config = viewModel.displays.config(for: screen)
        let style = DisplayConfigStore.resolve(
            config.style, hasHardwareNotch: screen.safeAreaInsets.top > 0
        )
        viewModel.islandStyle = style
        viewModel.islandCornerRadius = config.cornerRadius
        viewModel.islandContentPadding = config.contentPadding
        viewModel.islandDisplayID = screen.displayID
        // hasPhysicalNotch used to be written here too; it is now
        // derived from islandStyle (NotchViewModel.hasPhysicalNotch),
        // so a screen change can no longer update one and leave the
        // other holding a stale answer.

        // The configured size is the starting point, so a pill — and an
        // emulated notch on a screen with no cutout — is sizeable.
        var notchSize = CGSize(width: config.width, height: config.height)
        // A real notch's dimensions are the hardware's to state, not
        // ours to invent, so measured values win wherever the island is
        // actually wrapping one.
        if style == .notch,
           screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(
                width: screen.frame.width - left.width - right.width,
                height: screen.safeAreaInsets.top
            )
        }
        viewModel.notchSize = notchSize
        return NSRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    // The chin is dead. Two rounds grew a computed "housing overhang"
    // below the safe area, built on the theory that macOS understates
    // the glass at scaled resolutions (native-pixel math, R70/R93).
    // Measured directly on 2026-07-22: at the current mode the safe
    // area, the menu bar, and the auxiliary-area heights all agree
    // (32pt at 1470x956), macOS maps the cutout into the current
    // space itself, and every chin the math ever added was pill
    // hanging below the glass; the user's eye caught what captures
    // cannot (the cutout renders through, overshoot photographs as
    // intent). The pill's height is the safe area, no more. If glass
    // ever pokes out again, come back with fresh measurements, not
    // native-pixel myths.

    /// Block-based observers hand back a token, and the notification
    /// centre holds the block until that token is handed in. Kept so
    /// deinit can, rather than leaving them registered for good.
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var showRetry: DispatchWorkItem?

    func show() {
        // Built once. A second call would overwrite the click monitor
        // and the hover timer without releasing either.
        guard panel == nil else { return }
        // Prefer the built-in display with a notch, else the primary.
        // At login, or waking from a closed lid, the screen list can
        // still be empty here. This used to return and never come
        // back: no panel, no start(), no timers, no hover, and since
        // the app has no Dock icon the only symptom was Chalant simply
        // not being there. reposition() already knew to wait; so does
        // this now.
        showRetry?.cancel()
        showRetry = nil
        guard let screen = notchScreen else {
            let retry = DispatchWorkItem { [weak self] in self?.show() }
            showRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        let frame = placement(on: screen)

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Status-bar level (the menu bar's own level) still floats over
        // apps via fullScreenAuxiliary, but unlike screen-saver level it
        // is low enough that macOS routes file drags to it.
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Keep mouse-moved events flowing even while this panel is key,
        // so the hover monitors never go blind mid-session.
        panel.acceptsMouseMovedEvents = true

        let hosting = DropHostingView(rootView: NotchRootView(model: viewModel))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.enableDrops()
        hosting.onTargeted = { [weak viewModel] targeted in
            viewModel?.isDropTargeted = targeted
        }
        hosting.acceptsDrop = { [weak viewModel] in
            viewModel?.state != .listening
        }
        hosting.onDragEntered = { [weak viewModel] in
            guard let viewModel, viewModel.state == .collapsed else { return }
            viewModel.dragExpanded = true
            viewModel.expand(takeKey: false)
        }
        hosting.onDragExited = { [weak viewModel] in
            guard let viewModel, viewModel.dragExpanded else { return }
            viewModel.dragExpanded = false
            viewModel.collapse()
        }
        hosting.onDrop = { [weak viewModel] items in
            viewModel?.receiveDrop(items)
        }
        panel.contentView = hosting

        // When the island expands, take key focus so typing works
        // without pulling the user's current app out of focus.
        viewModel.onExpandChange = { [weak panel] expanded in
            if expanded {
                panel?.makeKeyAndOrderFront(nil)
            }
        }

        panel.orderFrontRegardless()
        self.panel = panel

        viewModel.start()

        // Debug-only: surface the drop bubble for screenshots.
        // A slider moved in settings has to reach the island now.
        // Without this the new value sits in the store until the next
        // display event, which reads as the control doing nothing.
        viewModel.displays.onChange = { [weak self] in
            self?.reposition()
            self?.rebuildSlivers()
        }
        // The Displays pane's "Move island here" button: it holds a
        // stable UUID key, never an NSScreen (see
        // DisplayConfigStore.key(for:)), so resolving the key back to
        // a live screen at click time is this controller's job.
        viewModel.travelToDisplay = { [weak self] key in
            guard let self,
                  let screen = NSScreen.screens.first(where: { DisplayConfigStore.key(for: $0) == key })
            else { return }
            self.travel(to: screen)
        }
        viewModel.onDebugDropDock = { [weak self] in
            guard let self, let screen = self.notchScreen else { return }
            self.dockPinnedUntil = Date().addingTimeInterval(3)
            self.showDropDock(on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.hideDropDock()
            }
        }

        // Clicking anywhere outside the app dismisses whatever the
        // island is doing. A listening session cancels (discarded, not
        // run: the click says the user left); before this, a surprise
        // voice panel had no exit except a tap on the island itself.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.viewModel.state == .listening {
                    self.viewModel.cancelListening()
                } else {
                    self.viewModel.collapse()
                }
            }
        }

        // Hover is tracked against *state-based* zones, not the
        // animating SwiftUI view (which flickers), and by polling the
        // pointer rather than event monitors: global mouseMoved
        // delivery silently stops in several key-window/active-app
        // configurations, but reading the location always works.
        //
        // A background LSUIElement app gets App Nap'd when launched via
        // LaunchServices, which throttles timers to a crawl, declare a
        // long-running activity (idle sleep still allowed) to opt out.
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Notch hover tracking"
        )
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            // Inline, never via the main queue: during a drag session
            // only the tracking run-loop mode runs and main-queue
            // tasks stall, but this poll is exactly what senses the
            // drag. The timer always fires on the main thread.
            MainActor.assumeIsolated {
                self?.pointerMoved()
            }
        }
        // Common modes so menu/event tracking doesn't pause the poll.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        dragBaseline = dragPasteboard.changeCount

        // Whenever the island changes state, for any reason, hover or
        // not, re-sync hover bookkeeping so a stale flag can never
        // block the next open.
        stateSub = viewModel.$state.sink { [weak self] newState in
            Task { @MainActor in self?.stateChanged(newState) }
        }

        // Displays come and go; the island follows. Without this the
        // panel stayed on a screen layout that no longer existed.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
                self?.rebuildSlivers()
            }
        })
        // The "Show edge when idle" switch governs the slivers too.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildSlivers() }
        })
        // Waking is not a screen-parameters change. A display that
        // slept, or a monitor switched off and on, often comes back
        // without posting one at all, and the panel would wake sized
        // for a geometry that no longer applied or ordered behind
        // whatever came up in front of it. Nothing re-fronted it after
        // show(), so it stayed behind.
        for name: NSNotification.Name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.reposition()
                        self?.rebuildSlivers()
                        self?.panel?.orderFrontRegardless()
                    }
                }
            )
        }
        // A toast appearing on a notchless display must pull that
        // display's bead so the two don't overlap.
        toastSub = viewModel.$glanceToast.sink { [weak self] _ in
            Task { @MainActor in self?.rebuildSlivers() }
        }
        rebuildSlivers()
    }

    /// Re-measure and re-place after a display change: a notch
    /// arriving or leaving changes the pill itself, not just where
    /// the panel sits.
    private var repositionRetry: DispatchWorkItem?

    private func reposition() {
        guard let panel else { return }
        repositionRetry?.cancel()
        repositionRetry = nil
        // Mid-transition (lid closing, display waking) the screen
        // list can be briefly empty; bailing here once used to leave
        // the island wearing the old display's notch forever.
        guard let screen = notchScreen else {
            let retry = DispatchWorkItem { [weak self] in self?.reposition() }
            repositionRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        // A visited display that vanished takes its travel with it;
        // otherwise replugging it would teleport an open island back
        // mid-use (review-caught).
        if let id = travelDisplayID,
           !NSScreen.screens.contains(where: { $0.displayID == id }) {
            travelDisplayID = nil
        }
        // Everything placement() derives from the screen, so a swap
        // between two displays with different settings repaints.
        let before = islandGeometry
        let frame = placement(on: screen)
        let frameChanged = panel.frame != frame
        if frameChanged {
            panel.setFrame(frame, display: true)
        }
        // The frame can survive a display swap unchanged while the
        // notch geometry does not; repaint on either difference.
        if frameChanged || before != islandGeometry {
            viewModel.objectWillChange.send()
        }
    }

    /// Resolved fresh every time: AppKit recreates NSScreen objects at
    /// will, so holding one weakly goes nil and kills hover silently.
    /// The island rests on the notched display; hovering another
    /// display's top edge summons it there (travel), and it walks
    /// home after it collapses. Held by display id, never by object.
    private var travelDisplayID: CGDirectDisplayID?

    /// A notched display if there is one, otherwise a sensible one
    /// that has not been switched off. Never NSScreen.main: that is
    /// the display holding the *focused window*, so on a notchless
    /// Mac with two monitors the island's home moved every time the
    /// user clicked something on the other screen, which made travel
    /// clear itself and the island teleport mid-use. It can also be
    /// nil, which is how the panel went missing at launch. screens.first
    /// is the menu-bar display and it holds still.
    ///
    /// With the lid shut the built-in leaves NSScreen.screens
    /// entirely, so every remaining display has no safe-area inset
    /// and `.auto` resolves every one of them to `.pill` — there is no
    /// notch anywhere to prefer. A display set to Off must never be
    /// picked as home, or the island lands somewhere it will never
    /// draw (clamshell, 2026-08-01). If every attached display is Off,
    /// that is a real state, not an accident: the last fallback still
    /// returns a real screen so the panel has somewhere to sit,
    /// invisible, rather than going homeless.
    private var homeScreen: NSScreen? {
        let notOff = NSScreen.screens.filter { viewModel.displays.resolvedStyle(for: $0) != .off }
        return notOff.first(where: { $0.safeAreaInsets.top > 0 })
            ?? notOff.first
            ?? NSScreen.screens.first
    }

    private var notchScreen: NSScreen? {
        // A travelled-to display that was switched to Off since must
        // not keep the island there — the door and bead this plan
        // adds are both gone on an Off display, and the island would
        // be reachable by nothing at all (clamshell requirement,
        // 2026-08-01).
        if let id = travelDisplayID,
           let visiting = NSScreen.screens.first(where: { $0.displayID == id }),
           viewModel.displays.resolvedStyle(for: visiting) != .off {
            return visiting
        }
        return homeScreen
    }

    private func travel(to screen: NSScreen) {
        travelDisplayID = screen.displayID == homeScreen?.displayID
            ? nil : screen.displayID
        reposition()
        rebuildSlivers()
    }

    /// Resting hints on every display the island is not dressing: a
    /// Mac mini owner has no notch anywhere, and a fully invisible
    /// island reads as not installed (user, 2026-07-23). The sliver
    /// is a handle, never a display; "Show edge when idle" turns it
    /// off for the total invisibility R96 chose.
    /// The bead's room: the panel that hosts the resting hint on a
    /// notchless display, and, since the uninvited-bloom fix, also the
    /// exact size of that display's hover door.
    static let sliverRoom = CGSize(width: 116, height: 20)

    /// Whether a display wears a resting bead. Static and screen-free
    /// so the rule can be checked without a monitor attached.
    ///
    /// Style-shaped, not hardware-shaped: hardware barred a bead from
    /// any display with a notch, which stranded a MacBook forced to
    /// Pill with no resting handle once the island travelled away,
    /// and let an emulated notch (Notch style, no real cutout) keep
    /// an exemption it no longer earned.
    static func wearsBead(
        style: DisplayConfigStore.Style,
        isIslandDisplay: Bool,
        islandShowing: Bool
    ) -> Bool {
        style == .pill && !(isIslandDisplay && islandShowing)
    }

    private var sliverPanels: [NSPanel] = []
    /// Defaults change constantly (the voice log alone writes every
    /// utterance); only a real difference rebuilds the panels.
    private var sliverSignature = ""

    func rebuildSlivers() {
        let wantsEdge = UserDefaults.standard.object(forKey: "idleEdgeOn") as? Bool ?? true
        // One answer for "is the island drawing on this display right
        // now", also read by the island's own opacity
        // (NotchViewModel.islandIsShowing). This used to be two rules:
        // the bead asked "collapsed with no toast" here, the island
        // asked "nothing to say" in NotchRootView, and a collapsed
        // island with a song playing satisfied the second without
        // satisfying the first, so both drew on the same display
        // (2026-08-01, photographed).
        let showing = viewModel.islandIsShowing
        let islandID = notchScreen?.displayID
        let targets = wantsEdge
            ? NSScreen.screens.filter {
                Self.wearsBead(
                    style: viewModel.displays.resolvedStyle(for: $0),
                    isIslandDisplay: $0.displayID == islandID,
                    islandShowing: showing
                )
            }
            : []
        let signature = targets
            .map { "\($0.displayID ?? 0)@\(Int($0.frame.midX)),\(Int($0.frame.maxY))" }
            .joined(separator: "|")
        guard signature != sliverSignature else { return }
        sliverSignature = signature
        sliverPanels.forEach { $0.orderOut(nil) }
        sliverPanels.removeAll()
        for screen in targets {
            // The panel is larger than the bead so IslandShape's eave
            // flare and belly, which draw beyond the shape's own rect,
            // are not clipped into a squared lozenge (review-caught;
            // the source of three rounds of "it looks wrong"). The
            // bead is centered inside this room by SliverHint.
            let width = Self.sliverRoom.width, height = Self.sliverRoom.height
            let frame = NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width, height: height
            )
            let sliver = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            sliver.level = .statusBar
            sliver.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
            ]
            sliver.isOpaque = false
            sliver.backgroundColor = .clear
            sliver.hasShadow = false
            sliver.ignoresMouseEvents = true
            sliver.contentView = NSHostingView(rootView: SliverHint())
            sliver.orderFrontRegardless()
            sliverPanels.append(sliver)
        }
    }

    private func pointerMoved() {
        guard let screen = notchScreen else { return }
        // ponytail: resolves a UUID per screen at 20 Hz so the bead's
        // answer stays live when music starts or a timer finishes
        // while collapsed - without it the bead only re-checked on
        // the next display or state event and could sit wrong for the
        // rest of the session (EC-11/EC-12, 2026-08-01). The signature
        // guard inside rebuildSlivers means this is cheap until the
        // answer actually changes; cache the resolved style on the
        // store, keyed by UUID, if this ever shows up in a trace.
        rebuildSlivers()
        let location = NSEvent.mouseLocation
        senseDrag(at: location, on: screen)
        switch viewModel.state {
        case .collapsed:
            // Any display's top edge is a door. Travel is deferred to
            // the dwell (below): a bare sweep through a monitor's top
            // band must NOT relocate the island, or it strands itself
            // invisible there with no walk-home ever armed
            // (review-caught). The relocation happens only once intent
            // is confirmed, paired with the open that guarantees a
            // later collapse and walk-home.
            let hit = NSScreen.screens.first {
                collapsedZone(on: $0).contains(location)
            }
            publishPointerUnit(location, zone: collapsedZone(on: hit ?? screen))
            if let hit {
                let hitID = hit.displayID
                guard Date().timeIntervalSince(lastCollapseAt) > reopenCooldown,
                      openIntentWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openIntentWork = nil
                    // Still there after the dwell, still collapsed?
                    // Rechecked against the HIT display, since travel
                    // has not happened yet.
                    guard self.viewModel.state == .collapsed,
                          let hitScreen = NSScreen.screens
                              .first(where: { $0.displayID == hitID }),
                          self.collapsedZone(on: hitScreen)
                              .contains(NSEvent.mouseLocation)
                    else { return }
                    // Intent confirmed: bring the island here, then open.
                    if hitID != self.notchScreen?.displayID {
                        self.travel(to: hitScreen)
                    }
                    self.lastOpenAt = Date()
                    self.viewModel.hoverChanged(true)
                }
                openIntentWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + openDwell, execute: work)
            } else {
                openIntentWork?.cancel()
                openIntentWork = nil
                // Clear the hover even when we never marked pointerInside:
                // with "Open on hover" off, the dwell set isHovering
                // true without expanding, and gating the clear on
                // pointerInside latched the pill grown forever
                // (review-caught).
                if pointerInside || viewModel.isHovering {
                    pointerInside = false
                    viewModel.hoverChanged(false)
                }
            }
        case .expanded:
            publishPointerUnit(location, zone: expandedZone(on: screen))
            openIntentWork?.cancel()
            openIntentWork = nil
            let inside = expandedZone(on: screen).contains(location)
            guard inside != pointerInside else { return }
            // Freshly opened islands don't close; kills any fast cycle.
            if !inside, Date().timeIntervalSince(lastOpenAt) < minimumOpen { return }
            pointerInside = inside
            viewModel.hoverChanged(inside)
        case .listening:
            // Voice sessions are press-driven; hover keeps its hands off.
            break
        }
    }

    /// A drag rising toward the top of the screen summons the drop
    /// bubble a third of the way down, nowhere near the top edge,
    /// whose Mission Control reveal fires after ~2s of dwell and
    /// cannot be disabled for file drags on this macOS. Held drags
    /// hover the bubble safely for as long as they like.
    private func senseDrag(at location: NSPoint, on screen: NSScreen) {
        guard Date() >= dockPinnedUntil else { return }
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        guard buttonDown else {
            // changeCount is an IPC round trip to the pasteboard
            // server, and this branch is the one the pointer is in
            // almost always: it ran twenty times a second for the whole
            // life of the app, on battery, to hold a number that only
            // matters at the instant a drag begins. Twice a second
            // holds it just as well.
            let now = Date()
            if now.timeIntervalSince(lastBaselineSample) > 0.5 {
                lastBaselineSample = now
                dragBaseline = dragPasteboard.changeCount
            }
            hideDropDock()
            return
        }
        guard dragPasteboard.changeCount != dragBaseline else { return }
        let zone = NSRect(
            x: screen.frame.midX - 430,
            y: screen.frame.maxY - screen.frame.height * 0.5,
            width: 860,
            height: screen.frame.height * 0.5
        )
        // A drag already over the island uses the island itself.
        if viewModel.isDropTargeted {
            hideDropDock()
        } else if zone.contains(location) {
            showDropDock(on: screen)
        } else if let dock = dropDock, dock.isVisible,
                  !zone.insetBy(dx: -60, dy: -60).contains(location) {
            hideDropDock()
        }
    }

    // MARK: - Drop bubble

    private var dropDock: NSPanel?

    /// Built once: a small transparent panel whose whole face is the
    /// dashed stash card, floating where a rising drag will meet it.
    private func ensureDropDock() -> NSPanel {
        if let dropDock { return dropDock }
        let size = CGSize(width: 360, height: 200)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        let hosting = DropHostingView(rootView: DropStashCard().frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.enableDrops()
        hosting.acceptsDrop = { [weak viewModel] in
            viewModel?.state != .listening
        }
        hosting.onDrop = { [weak self] items in
            self?.hideDropDock()
            self?.viewModel.receiveDrop(items, quietly: true)
        }
        panel.contentView = hosting
        dropDock = panel
        return panel
    }

    /// While set, the sensing poll keeps its hands off the bubble
    /// (debug previews have no real drag keeping them alive).
    private var dockPinnedUntil = Date.distantPast

    private func showDropDock(on screen: NSScreen) {
        let dock = ensureDropDock()
        if dock.isVisible {
            // A hide may be mid-fade; breathe it back instead.
            guard dock.alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                dock.animator().alphaValue = 1
            }
            return
        }
        let size = dock.frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - screen.frame.height * 0.34 - size.height / 2
        )
        // Rise a few points while fading in; arriving, not popping.
        dock.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 12))
        dock.alphaValue = 0
        dock.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dock.animator().alphaValue = 1
            dock.animator().setFrame(
                NSRect(origin: origin, size: size), display: true
            )
        }
    }

    private func hideDropDock() {
        guard let dropDock, dropDock.isVisible, dropDock.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            dropDock.animator().alphaValue = 0
        }, completionHandler: { [weak dropDock] in
            // AppKit runs this on the main thread but does not say so
            // in its type, the same situation as the hover timer above.
            MainActor.assumeIsolated {
                // A show may have raced the fade; only stow a faded dock.
                if let dropDock, dropDock.alphaValue == 0 {
                    dropDock.orderOut(nil)
                }
            }
        })
    }

    /// Publish a coarse 0...1 pointer position across the hover zone
    /// so the shell's specular light can follow the cursor. Quantized
    /// to 1/24 steps and set only on change: a normal sweep costs a
    /// handful of re-renders, not the full 20 Hz.
    private func publishPointerUnit(_ location: NSPoint, zone: NSRect) {
        guard zone.contains(location) else {
            if viewModel.pointerUnit != nil { viewModel.pointerUnit = nil }
            return
        }
        let raw = (location.x - zone.minX) / zone.width
        let unit = min(max((raw * 24).rounded() / 24, 0), 1)
        if viewModel.pointerUnit != unit {
            viewModel.pointerUnit = unit
        }
    }

    /// Any state change, hover-driven or not (tap, file drop, click-away
    /// collapse), resets hover bookkeeping to match reality.
    private func stateChanged(_ newState: NotchViewModel.IslandState) {
        openIntentWork?.cancel()
        openIntentWork = nil
        // The bead yields while the island is open on its display and
        // returns when it closes; signature-guarded, so cheap here.
        rebuildSlivers()
        // The light never survives a state morph; it fades back in on
        // the next poll if the pointer is still there.
        viewModel.pointerUnit = nil
        switch newState {
        case .collapsed:
            pointerInside = false
            lastCollapseAt = Date()
            // A visiting island walks home once it has settled, unless
            // the cursor is still on the visited door (re-hovering it
            // must not yank the island out from under the pointer,
            // review-caught).
            if travelDisplayID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.viewModel.state == .collapsed,
                          self.travelDisplayID != nil else { return }
                    if let here = self.notchScreen,
                       self.collapsedZone(on: here).contains(NSEvent.mouseLocation) {
                        return
                    }
                    self.travelDisplayID = nil
                    self.reposition()
                    self.rebuildSlivers()
                }
            }
        case .expanded:
            lastOpenAt = Date()
            if let screen = notchScreen {
                pointerInside = expandedZone(on: screen).contains(NSEvent.mouseLocation)
            }
        case .listening:
            break
        }
    }

    /// Close reach only: the island opens when the cursor is on it
    /// or a hair away, not from half a menu bar out. The old 160 of
    /// slack opened it for passersby (user call, 2026-07-21).
    private func collapsedZone(on screen: NSScreen) -> NSRect {
        // Sized from the STYLE that display resolves to, not its raw
        // hardware: the door and the shape it opens have to agree, or
        // a door can sit under a shape too wide for it (an emulated
        // notch on a screen with no cutout, EC-5) or a shape can draw
        // with no door under it at all (Off, which used to still wear
        // the hardware-shaped door and left a travelled island
        // stranded there, EC-4, 2026-08-01).
        switch viewModel.displays.resolvedStyle(for: screen) {
        case .off:
            // Every caller guards on contains() first, and
            // CGRect.null.contains is false by definition: no caller
            // needs to change for a display with no door at all.
            return .null
        case .pill:
            // The door is exactly the bead's room: the island opens
            // only when the cursor touches the thing the eye can see.
            // The old notch-wide invisible strip kept catching runs at
            // browser tabs on maximized windows and blooming uninvited
            // (user, 2026-07-23). With the bead switched off the same
            // small door remains, just invisible; R96's law that a
            // door always exists survives at bead scale.
            return hoverZone(
                on: screen,
                width: Self.sliverRoom.width,
                height: Self.sliverRoom.height
            )
        case .notch, .auto:
            // .auto never reaches here — resolvedStyle always resolves
            // it — but the switch has to be whole. Sized from THIS
            // screen's own notch, not the display the island currently
            // dresses: viewModel.notchSize is the dressed display's,
            // so every other display's door inherited the wrong width
            // and could miss the real notch (review-caught).
            let notch = notchMetric(of: screen)
            return hoverZone(
                on: screen,
                width: notch.width + 116,
                height: notch.height + 12
            )
        }
    }

    /// A screen's own notch, or — for an emulated one — the size the
    /// pane configured for it, so a door is correct on whichever
    /// display it hangs from. A real notch's dimensions are the
    /// hardware's to state; falling back to the static default here
    /// left a 420pt-wide emulated notch behind a door sized for the
    /// old ~310pt default, and the island's own ends could not reach
    /// it (EC-5).
    private func notchMetric(of screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            let config = viewModel.displays.config(for: screen)
            return CGSize(width: config.width, height: config.height)
        }
        return CGSize(
            width: screen.frame.width - left.width - right.width,
            height: screen.safeAreaInsets.top
        )
    }

    private func expandedZone(on screen: NSScreen) -> NSRect {
        let size = viewModel.expandedSize
        return hoverZone(on: screen, width: size.width + 28, height: size.height + 16)
    }

    /// A rect hanging from the top-center of the screen, in the global
    /// bottom-left coordinate space mouseLocation uses. Extends past the
    /// top edge: a cursor pinned to the top reports y == maxY exactly,
    /// and NSRect.contains excludes its max edge, without the overhang,
    /// hovering the notch itself counts as "outside".
    private func hoverZone(on screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height + 20
        )
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        hoverTimer?.invalidate()
        showRetry?.cancel()
        repositionRetry?.cancel()
        if let napActivity {
            ProcessInfo.processInfo.endActivity(napActivity)
        }
    }
}

/// The resting handle on displays the island is not dressing: the
/// sliver silhouette, pure hint, no content. Hovering it (the zone,
/// not the pixels; it ignores the mouse) summons the island over.
private struct SliverHint: View {
    /// A miniature of the Mac's own notch pill (user, 2026-07-23,
    /// "the same thing as it is on my Mac, but smaller"): flat top,
    /// straight sides, the shoulder eave and rounded bottom of the
    /// real hardware, at half scale. No arcs, no beads.
    private var shape: IslandShape {
        IslandShape(eave: 4, bottomRadius: 8, belly: 0.5)
    }

    var body: some View {
        shape
            .fill(Color.black)
            .overlay(shape.strokeBorder(Theme.specularEdge, lineWidth: 1).opacity(0.75))
            .overlay(shape.strokeBorder(Theme.lipLight, lineWidth: 1))
            // The shape's own rect, hugging the panel's top edge; the
            // panel's extra room lets the eave and belly draw uncut.
            .frame(width: 100, height: 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// Internal rather than private: DisplayConfigStore needs the same live
// handle to look a screen up before filing its settings under the
// stable UUID.
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
