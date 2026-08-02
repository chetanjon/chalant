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
    /// One panel per display that wears an island, keyed by the
    /// display's live `CGDirectDisplayID` (never held as `NSScreen`:
    /// AppKit recreates those at will). `rebuildIslands()` is the only
    /// writer (island-per-display-plan, W-C, 2026-08-02).
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    /// Each panel's render state, same keys as `panels`, built and torn
    /// down alongside it.
    private var faces: [CGDirectDisplayID: IslandFace] = [:]
    /// `show()` guard: panels themselves can legitimately be empty for
    /// a moment (every display resolved to Off, or mid-wake), so a
    /// dedicated flag is the reentry guard instead of `panels.isEmpty`.
    private var started = false
    private var clickMonitor: Any?
    private var hoverTimer: Timer?
    private var stateSub: AnyCancellable?
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

    /// Everything `apply(_:to:)` writes onto a face, as one comparable
    /// value. Kept together so adding a per-display setting cannot
    /// quietly leave the repaint check behind — the failure there is
    /// silent and looks like the setting doing nothing. A per-face
    /// check, not a per-model one (2026-08-02): with a face per
    /// display, this always compares a face against itself, never one
    /// face against another's numbers.
    private func islandGeometry(of face: IslandFace) -> [AnyHashable] {
        [
            face.displayID, face.notchSize, face.style, face.cornerRadius, face.contentPadding,
            face.expandedWidth, face.expandedMinHeight,
        ]
    }

    /// Measure the target screen and write the face's geometry — the
    /// one copy of it, now that every display has its own face — then
    /// compute the panel frame. Shared by every display, on first build
    /// and on every re-measure after.
    ///
    /// Used to dual-write the same five values onto `viewModel` too.
    /// That was a stopgap for the round where only one face existed;
    /// with a face per display, a single shared model field can only
    /// ever hold whichever screen `apply(_:to:)` last ran for, which is
    /// exactly the bug class this branch exists to remove. All of them
    /// are deleted, `islandDisplayID` included: it fed the Displays
    /// pane's "island here" badge, and a badge naming one display is a
    /// plain untruth once every display wears an island
    /// (island-per-display-plan, W-C and W-E, 2026-08-02).
    @discardableResult
    private func apply(_ screen: NSScreen, to face: IslandFace) -> NSRect {
        // This screen's own settings, resolved out of `.auto` against
        // what the hardware actually reports.
        let config = viewModel.displays.config(for: screen)
        let style = DisplayConfigStore.resolve(
            config.style, hasHardwareNotch: screen.safeAreaInsets.top > 0
        )
        face.style = style
        face.cornerRadius = config.cornerRadius
        face.contentPadding = config.contentPadding
        face.expandedWidth = config.expandedWidth
        face.expandedMinHeight = config.expandedMinHeight
        face.displayID = screen.displayID
        // hasPhysicalNotch used to be written here too; it is now
        // derived from style (IslandFace.hasPhysicalNotch), so a screen
        // change can no longer update one and leave the other holding a
        // stale answer.

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
        face.notchSize = notchSize
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
        // Built once. A second call would re-register every observer
        // and timer without releasing the first set.
        guard !started else { return }
        // At login, or waking from a closed lid, the screen list can
        // still be empty here. This used to return and never come
        // back: no panel, no start(), no timers, no hover, and since
        // the app has no Dock icon the only symptom was Chalant simply
        // not being there. `rebuildIslands()` carries the same retry
        // forward now that there is no single screen to wait for.
        showRetry?.cancel()
        showRetry = nil
        guard !NSScreen.screens.isEmpty else {
            let retry = DispatchWorkItem { [weak self] in self?.show() }
            showRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        started = true

        viewModel.start()
        rebuildIslands()

        // A slider moved in settings has to reach every island now, not
        // only the one it happened to be measured against.
        viewModel.displays.onChange = { [weak self] in
            self?.rebuildIslands()
        }
        viewModel.onDebugDropDock = { [weak self] in
            guard let self, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            self.dockPinnedUntil = Date().addingTimeInterval(3)
            self.showDropDock(on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.hideDropDock()
            }
        }
        // "debug droptarget" flashes the drop highlight for a
        // screenshot; isDropTargeted lives on each face now, so this
        // flashes whichever one is open, or the first, as a stand-in —
        // there is no single "the" island to ask any more.
        viewModel.debugSetDropTargeted = { [weak self] targeted in
            guard let self else { return }
            let id = self.viewModel.expandedDisplayID ?? self.faces.keys.first
            id.flatMap { self.faces[$0] }?.isDropTargeted = targeted
        }

        // When the island expands, take key focus so typing works
        // without pulling the user's current app out of focus. Resolved
        // through `expandedDisplayID` at call time, never a captured
        // panel, so the display that just opened is always the one
        // that gets it (EC-5).
        viewModel.onExpandChange = { [weak self] expanded in
            guard expanded, let self, let id = self.viewModel.expandedDisplayID else { return }
            self.panels[id]?.makeKeyAndOrderFront(nil)
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

        // Displays come and go; every island follows. Without this a
        // panel stayed on a screen layout that no longer existed.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildIslands() }
        })
        // Waking is not a screen-parameters change. A display that
        // slept, or a monitor switched off and on, often comes back
        // without posting one at all, and a panel would wake sized for
        // a geometry that no longer applied or ordered behind whatever
        // came up in front of it. Nothing re-fronted it after show(),
        // so it stayed behind.
        for name: NSNotification.Name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.rebuildIslands()
                        self.panels.values.forEach { $0.orderFrontRegardless() }
                    }
                }
            )
        }
    }

    /// Which displays wear an island, and where each panel sits.
    ///
    /// Static and screen-free so the rule can be checked with nothing
    /// plugged in — the same reason `wearsBead` was (it is gone: there
    /// is no bead to decide about any more, every display that is not
    /// Off gets a real island).
    ///
    /// An Off display gets no panel rather than an invisible one. An
    /// island at opacity 0 still hit-tests its contentShape, so the
    /// top centre of an Off display could start a voice session with
    /// nothing on screen ever appearing (EC-10, 2026-08-02).
    static func islandFrames(
        for screens: [(id: CGDirectDisplayID, frame: CGRect, style: DisplayConfigStore.Style)],
        panelSize: CGSize
    ) -> [CGDirectDisplayID: CGRect] {
        var frames: [CGDirectDisplayID: CGRect] = [:]
        for screen in screens where screen.style != .off {
            frames[screen.id] = CGRect(
                x: screen.frame.midX - panelSize.width / 2,
                y: screen.frame.maxY - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        }
        return frames
    }

    /// The three-way diff between the panels that exist and the panels
    /// that should: which displays are new, which are gone, and which
    /// are staying but moved. Static so EC-7 — never tearing down a
    /// panel that is only being re-placed, which would kill an open
    /// island's `WKWebView` mid-conversation or a voice session
    /// mid-capture — is checkable with nothing plugged in. A display
    /// present in both with an unchanged frame appears in none of the
    /// three sets.
    static func diffPanels(
        current: [CGDirectDisplayID: CGRect], wanted: [CGDirectDisplayID: CGRect]
    ) -> (added: Set<CGDirectDisplayID>, removed: Set<CGDirectDisplayID>, moved: Set<CGDirectDisplayID>) {
        let currentIDs = Set(current.keys), wantedIDs = Set(wanted.keys)
        let kept = currentIDs.intersection(wantedIDs)
        let moved = kept.filter { current[$0] != wanted[$0] }
        return (
            added: wantedIDs.subtracting(currentIDs),
            removed: currentIDs.subtracting(wantedIDs),
            moved: Set(moved)
        )
    }

    private var rebuildRetry: DispatchWorkItem?

    /// Add, remove and re-place panels to match the current screen
    /// list — never tear down and rebuild what is only being moved
    /// (EC-7). Called on every screen-parameter change, wake, Displays
    /// pane edit and state change; the diff makes repeated calls with
    /// nothing new to do cheap.
    func rebuildIslands() {
        rebuildRetry?.cancel()
        rebuildRetry = nil
        // Mid-transition (lid closing, display waking) the screen list
        // can be briefly empty; treating that as "remove every panel"
        // once tore down an open island's hosting view for nothing
        // better to show in its place (EC-19, 2026-08-02).
        guard !NSScreen.screens.isEmpty else {
            let retry = DispatchWorkItem { [weak self] in self?.rebuildIslands() }
            rebuildRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        let screens = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, screen: NSScreen, style: DisplayConfigStore.Style)? in
            guard let id = screen.displayID else { return nil }
            return (id, screen, viewModel.displays.resolvedStyle(for: screen))
        }
        let wanted = Self.islandFrames(
            for: screens.map { (id: $0.id, frame: $0.screen.frame, style: $0.style) },
            panelSize: panelSize
        )
        let diff = Self.diffPanels(current: panels.mapValues(\.frame), wanted: wanted)

        for id in diff.removed {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            faces.removeValue(forKey: id)
            viewModel.forgetHover(on: id)
        }
        // A display the expansion was open on just lost its panel;
        // there is nowhere left to show it (EC-6).
        if let expanded = viewModel.expandedDisplayID, wanted[expanded] == nil {
            viewModel.collapse()
        }

        for entry in screens {
            guard let frame = wanted[entry.id] else { continue }
            if diff.added.contains(entry.id) {
                makeIsland(on: entry.screen, frame: frame)
            } else if let face = faces[entry.id] {
                let before = islandGeometry(of: face)
                apply(entry.screen, to: face)
                if diff.moved.contains(entry.id) {
                    panels[entry.id]?.setFrame(frame, display: true)
                }
                if diff.moved.contains(entry.id) || before != islandGeometry(of: face) {
                    viewModel.objectWillChange.send()
                }
            }
        }
    }

    /// One new panel and its face for a display that just started
    /// wanting an island. `id` is captured by value in every closure
    /// below, so a drag or drop on this panel always names the display
    /// it actually happened on, never whichever the controller
    /// currently thinks is "the" one.
    private func makeIsland(on screen: NSScreen, frame: CGRect) {
        guard let id = screen.displayID else { return }
        let face = IslandFace(model: viewModel)
        apply(screen, to: face)
        faces[id] = face

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

        let hosting = DropHostingView(rootView: NotchRootView(model: viewModel, face: face))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.enableDrops()
        hosting.onTargeted = { [weak face] targeted in
            face?.isDropTargeted = targeted
        }
        hosting.acceptsDrop = { [weak viewModel] in
            viewModel?.state != .listening
        }
        hosting.onDragEntered = { [weak self, weak face] in
            guard let self, let face, self.viewModel.state == .collapsed else { return }
            face.dragExpanded = true
            self.viewModel.expand(on: id, takeKey: false)
        }
        hosting.onDragExited = { [weak self, weak face] in
            guard let self, let face, face.dragExpanded else { return }
            face.dragExpanded = false
            self.viewModel.collapse()
        }
        hosting.onDrop = { [weak self, weak face] items in
            face?.dragExpanded = false
            self?.viewModel.receiveDrop(items)
        }
        panel.contentView = hosting
        panel.orderFrontRegardless()
        panels[id] = panel
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        if let hostScreen = NSScreen.screens.first(where: { $0.frame.contains(location) }),
           let hostID = hostScreen.displayID, let hostFace = faces[hostID] {
            senseDrag(at: location, on: hostScreen, face: hostFace)
        }
        switch viewModel.state {
        case .collapsed:
            // Any display's top edge is a door; every one already has
            // its own island, so a hit here needs no travel, only its
            // own face's hover lit.
            let hit = NSScreen.screens.first { collapsedZone(on: $0).contains(location) }
            let hitID = hit?.displayID
            if let hit, let hitID, let hitFace = faces[hitID] {
                publishPointerUnit(location, zone: collapsedZone(on: hit), face: hitFace)
            }
            // The light and the hover follow the hit as it moves; every
            // other face's must clear.
            for (id, face) in faces where id != hitID {
                if face.pointerUnit != nil { face.pointerUnit = nil }
                if face.pointerNear { face.pointerNear = false }
            }
            // Set before the dwell, not after: a hidden island has to
            // arrive as someone reaches for it, or they reach for
            // nothing and it opens under a pointer that had given up.
            if let hitID, let hitFace = faces[hitID], !hitFace.pointerNear {
                hitFace.pointerNear = true
            }
            if let hitID {
                guard Date().timeIntervalSince(lastCollapseAt) > reopenCooldown,
                      openIntentWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openIntentWork = nil
                    // Still there after the dwell, still collapsed?
                    guard self.viewModel.state == .collapsed,
                          let hitScreen = NSScreen.screens
                              .first(where: { $0.displayID == hitID }),
                          self.collapsedZone(on: hitScreen)
                              .contains(NSEvent.mouseLocation)
                    else { return }
                    self.lastOpenAt = Date()
                    self.faces[hitID]?.isHovering = true
                    self.viewModel.hoverChanged(true, on: hitID)
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
                    if let hovered = viewModel.lastHoveredDisplayID {
                        faces[hovered]?.isHovering = false
                        viewModel.hoverChanged(false, on: hovered)
                    }
                }
            }
        case .expanded:
            // Only one face is ever expanded; its own display is the
            // only one hover has anything to say about here.
            guard let ownerID = viewModel.expandedDisplayID,
                  let ownerScreen = NSScreen.screens.first(where: { $0.displayID == ownerID }),
                  let ownerFace = faces[ownerID]
            else { return }
            publishPointerUnit(
                location, zone: expandedZone(on: ownerScreen, face: ownerFace), face: ownerFace)
            for (id, face) in faces where id != ownerID {
                if face.pointerUnit != nil { face.pointerUnit = nil }
            }
            openIntentWork?.cancel()
            openIntentWork = nil
            let inside = expandedZone(on: ownerScreen, face: ownerFace).contains(location)
            guard inside != pointerInside else { return }
            // Freshly opened islands don't close; kills any fast cycle.
            if !inside, Date().timeIntervalSince(lastOpenAt) < minimumOpen { return }
            pointerInside = inside
            ownerFace.isHovering = inside
            viewModel.hoverChanged(inside, on: ownerID)
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
    private func senseDrag(at location: NSPoint, on screen: NSScreen, face: IslandFace) {
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
        if face.isDropTargeted {
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
            // The dock is every island's other mouth, and a drag that
            // opened one of them can end here without that island ever
            // seeing an exit. `receiveDrop` used to clear this for
            // every path at once; now that the flag lives on each face,
            // every mouth clears it, and a stale true would let the
            // next unrelated drag-exit collapse an island the user had
            // opened on purpose (2026-08-02). Only one drag is ever in
            // flight, so at most one face is actually true here.
            self?.faces.values.forEach { $0.dragExpanded = false }
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
    private func publishPointerUnit(_ location: NSPoint, zone: NSRect, face: IslandFace) {
        guard zone.contains(location) else {
            if face.pointerUnit != nil { face.pointerUnit = nil }
            return
        }
        let raw = (location.x - zone.minX) / zone.width
        let unit = min(max((raw * 24).rounded() / 24, 0), 1)
        if face.pointerUnit != unit {
            face.pointerUnit = unit
        }
    }

    /// Any state change, hover-driven or not (tap, file drop, click-away
    /// collapse), resets hover bookkeeping to match reality.
    private func stateChanged(_ newState: NotchViewModel.IslandState) {
        openIntentWork?.cancel()
        openIntentWork = nil
        // An expansion can change which islands draw (a pill with
        // nothing to say renders differently collapsed than open on
        // it), so re-derive; the diff makes this cheap when a display
        // did not actually change.
        rebuildIslands()
        // The light never survives a state morph; it fades back in on
        // the next poll if the pointer is still there.
        faces.values.forEach { $0.pointerUnit = nil }
        switch newState {
        case .collapsed:
            pointerInside = false
            lastCollapseAt = Date()
        case .expanded:
            lastOpenAt = Date()
            if let id = viewModel.expandedDisplayID,
               let screen = NSScreen.screens.first(where: { $0.displayID == id }),
               let face = faces[id] {
                pointerInside = expandedZone(on: screen, face: face).contains(NSEvent.mouseLocation)
            }
        case .listening:
            break
        }
    }

    /// The door's size on a pill display: the same fixed size the
    /// resting bead used to occupy before every display grew its own
    /// island (W-C, 2026-08-02) — named rather than left inline so the
    /// number survives that deletion.
    private static let pillDoor = CGSize(width: 116, height: 20)

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
            // A small door, because a small door is right for a pill —
            // not because a bead once lived here at exactly this size.
            // The island opens only when the cursor touches the thing
            // the eye can see. The old notch-wide invisible strip kept
            // catching runs at browser tabs on maximized windows and
            // blooming uninvited (user, 2026-07-23).
            return hoverZone(
                on: screen,
                width: Self.pillDoor.width,
                height: Self.pillDoor.height
            )
        case .notch, .auto:
            // .auto never reaches here — resolvedStyle always resolves
            // it — but the switch has to be whole. Sized from THIS
            // screen's own notch via `notchMetric(of:)`, never a
            // single shared field: a shared "the notch size" once
            // belonged to whichever display was measured last, so
            // every other display's door inherited the wrong width
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

    /// Width from the owner's own config, not the measured size: a
    /// door sized from `viewModel.expandedSize` lands one layout pass
    /// after a width-slider drag re-lays the content out, so for one
    /// frame the door is still the old width and the pointer can fall
    /// outside it and collapse the island mid-drag (EC-11). Height has
    /// no such door, it only ever grows from content or a floor, both
    /// already reflected in `expandedSize` by the time this runs, so
    /// it still reads the measurement.
    private func expandedZone(on screen: NSScreen, face: IslandFace) -> NSRect {
        let chatFull = UserDefaults.standard.object(forKey: "chatFull") as? Bool ?? false
        let width = NotchViewModel.expandedWidth(
            configWidth: face.expandedWidth, tab: viewModel.tab, pane: viewModel.pane,
            chatFull: chatFull)
        let height = viewModel.expandedSize.height
        return hoverZone(on: screen, width: width + 28, height: height + 16)
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
        rebuildRetry?.cancel()
        if let napActivity {
            ProcessInfo.processInfo.endActivity(napActivity)
        }
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
