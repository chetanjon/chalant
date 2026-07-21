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
    private var napActivity: NSObjectProtocol?
    private var summon: HotkeySummon?
    private var pointerInside = false
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
    /// User-tunable ("openDelay" in settings).
    private var openDwell: TimeInterval {
        UserDefaults.standard.object(forKey: "openDelay") as? Double ?? 0.12
    }

    func show() {
        // Prefer the built-in display with a notch. Fall back to main.
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen else { return }

        // Measure the physical notch; notch-less displays keep the default pill.
        viewModel.hasPhysicalNotch = screen.safeAreaInsets.top > 0
        var notchSize = NotchViewModel.defaultNotchSize
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(
                width: screen.frame.width - left.width - right.width,
                height: screen.safeAreaInsets.top
            )
        }
        viewModel.notchSize = notchSize

        // The panel is a fixed transparent region at the top of the screen.
        // The island animates inside it, so the window never resizes. Its
        // height must clear the tallest island (Full + a session strip +
        // the Settings pane measures ~640pt); clear areas hit-test through,
        // so the extra room costs nothing.
        let panelSize = CGSize(width: 820, height: 720)
        let frame = NSRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )

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
            viewModel.expand()
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

        // Voice from anywhere: the summon key toggles a listening
        // session without the mouse ever visiting the notch.
        summon = HotkeySummon { [weak self] in
            self?.viewModel.summon()
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
            Task { @MainActor in self?.pointerMoved() }
        }
        // Common modes so menu/event tracking doesn't pause the poll.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer

        // Whenever the island changes state, for any reason, hover or
        // not, re-sync hover bookkeeping so a stale flag can never
        // block the next open.
        stateSub = viewModel.$state.sink { [weak self] newState in
            Task { @MainActor in self?.stateChanged(newState) }
        }
    }

    /// Resolved fresh every time: AppKit recreates NSScreen objects at
    /// will, so holding one weakly goes nil and kills hover silently.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private func pointerMoved() {
        guard let screen = notchScreen else { return }
        let location = NSEvent.mouseLocation
        switch viewModel.state {
        case .collapsed:
            publishPointerUnit(location, zone: collapsedZone(on: screen))
            if collapsedZone(on: screen).contains(location) {
                // Level-triggered on entry: presence in the zone is enough.
                // No stale-flag path may block a fresh hover from opening.
                guard Date().timeIntervalSince(lastCollapseAt) > reopenCooldown,
                      openIntentWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openIntentWork = nil
                    // Still there after the dwell, still collapsed?
                    guard self.viewModel.state == .collapsed,
                          let screen = self.notchScreen,
                          self.collapsedZone(on: screen).contains(NSEvent.mouseLocation)
                    else { return }
                    self.lastOpenAt = Date()
                    self.viewModel.hoverChanged(true)
                }
                openIntentWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + openDwell, execute: work)
            } else {
                openIntentWork?.cancel()
                openIntentWork = nil
                if pointerInside {
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
        // The light never survives a state morph; it fades back in on
        // the next poll if the pointer is still there.
        viewModel.pointerUnit = nil
        switch newState {
        case .collapsed:
            pointerInside = false
            lastCollapseAt = Date()
        case .expanded:
            lastOpenAt = Date()
            if let screen = notchScreen {
                pointerInside = expandedZone(on: screen).contains(NSEvent.mouseLocation)
            }
        case .listening:
            break
        }
    }

    /// Generous reach in both directions: skimming the top edge near
    /// the notch is enough, and pointing at the island's visible body
    /// or just under its lip also counts, users aim at what they see,
    /// not at the strip above it.
    private func collapsedZone(on screen: NSScreen) -> NSRect {
        hoverZone(
            on: screen,
            width: viewModel.notchSize.width + 160,
            height: viewModel.notchSize.height + 26
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
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        hoverTimer?.invalidate()
    }
}
