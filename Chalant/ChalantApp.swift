import Sparkle
import SwiftUI

@main
struct ChalantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    /// Built once on first open and kept: the window closes, the app
    /// keeps running headless, and reopening shows this same one back
    /// where it was left.
    private var dashboardController: DashboardWindowController?
    private var statusItem: NSStatusItem?
    /// Sparkle, on a leash: its own scheduler is off (Info.plist
    /// SUEnableAutomaticChecks false; the island's quiet daily
    /// UpdateChecker remains the only detector). It acts when the
    /// user asks, and the app replaces itself and relaunches.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the media bridge stream so no perl child outlives us.
        notchController?.viewModel.music.shutdown()
        notchController?.viewModel.activityServer.stop()
        // And no recording of the last thing said.
        VoiceController.sweepRecordings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test bundle runs inside this app as its host, and a
        // host that starts the real thing is a second Chalant: it binds
        // a real port, and until 2026-08-09 it then "refreshed" the
        // real ~/.claude/settings.json to whatever fallback port it
        // got. A suite run beside the installed app rewrote every
        // armed hook to 4243, and the next Stop hook on the machine
        // died with ECONNREFUSED against a port nothing was listening
        // on. Tests build their own stores through the `at:` seams;
        // the host app stays inert.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        // One-time inheritance from the Moai era: the rename changed
        // the bundle id, which changed the defaults domain, which
        // would have orphaned every setting, note, and focus streak.
        migrateFromMoai()
        // Named in Console the moment it happens, which the system's own
        // report cannot do: this runs while the process is still alive.
        // It only ever sees Objective-C exceptions, the AVAudioEngine
        // family; a Swift trap is a SIGTRAP and never travels through
        // here, which is exactly why CrashWatch reads the report on the
        // next launch instead of relying on this.
        NSSetUncaughtExceptionHandler { exception in
            CrashWatch.log.critical(
                "uncaught \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)")
        }
        // A crash or a force quit skips applicationWillTerminate, so
        // the last session's audio can still be on disk from before.
        VoiceController.sweepRecordings()
        // Press-and-hold accent picker is a remote-view sheet that
        // crashes when it tries to attach to the borderless notch
        // panel (ViewBridge SIGABRT, 2026-07-19). Held keys repeat
        // instead, the same trade VS Code makes.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

        // Info.plist ships LSUIElement, so the app starts as an
        // accessory and only takes a Dock icon if the user asked for
        // one. Re-applied here because the policy is process state, not
        // a stored preference the system restores on its own.
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }

        // The island itself
        let controller = NotchWindowController()
        controller.show()
        notchController = controller
        controller.viewModel.installUpdate = { [weak self] in
            self?.updater.checkForUpdates(nil)
        }
        controller.viewModel.openDashboard = { [weak self] section in
            self?.showDashboard(section: section)
        }

        // System-wide shortcuts. Unbound until the user records one, so
        // this claims no combination on a fresh install.
        let hotKeys = HotKeyCenter.shared
        hotKeys.handlers = [
            .toggleIsland: { [weak controller] in
                guard let model = controller?.viewModel else { return }
                switch model.state {
                case .expanded: model.collapse()
                case .collapsed: model.expand()
                // A hold is in progress. `expand()` would set the state
                // straight to expanded with the microphone still
                // capturing and the room still ducked, stranding the
                // session — the shortcut is not a way to interrupt one.
                case .listening: break
                }
            },
            .talk: { [weak controller] in
                controller?.viewModel.toggleListening()
            },
            .openSettings: { [weak self] in
                self?.showDashboard(section: nil)
            },
        ]
        // Every shortcut that opens a panel is the same behaviour with a
        // different destination, so it is written once.
        for action in HotKeyCenter.Action.allCases {
            guard let tab = action.tab else { continue }
            hotKeys.handlers[action] = { [weak controller] in
                guard let model = controller?.viewModel else { return }
                // A tool switched off in settings is not somewhere to
                // land: the switcher would not show it, leaving the
                // panel open with no way back but Today. Both choices
                // were the user's, so this says which one won rather
                // than silently doing nothing.
                guard NotchViewModel.isAvailable(tab) else {
                    model.flashGlance("\(action.title) is switched off in settings")
                    return
                }
                // Straight to the panel, not merely open: the shortcut
                // exists to skip the switcher, and landing on Today
                // would leave the user one click from where they asked
                // to be.
                // Expand first, then choose. `expand()` runs
                // `restoreLastTabIfWanted()`, so setting the tab before
                // it meant "Remember last tab" immediately overwrote
                // the destination the shortcut had just asked for: with
                // that switch on, every one of these landed wherever
                // the island was last left instead (founder,
                // 2026-08-02, "cmd ctrl s should show sessions").
                // Ordering it this way also covers an island that is
                // already open, where expand() returns early and the
                // assignment is the only thing that happens.
                model.expand()
                model.tab = tab
                // A destination with a room lands in the room.
                //
                // Same reasoning as the comment above about skipping the
                // switcher, one step further on: a shortcut is a
                // deliberate act, exactly like clicking "Open full", and
                // a deliberate act should land where deliberate acts
                // land. Nothing is lost, because hovering the notch
                // still gives the glance for free. Written against
                // `canFocus` rather than `== .sessions` so a second
                // focusable destination inherits it rather than being a
                // second place to remember.
                if tab.canFocus { model.focus(on: tab) }
                // The clipboard's own binding covers both halves the
                // founder asked for: opening it, and searching within
                // it once open. A second destination just for search
                // would be two bindings pointed at the same panel,
                // which the one-binding-per-tab rule below exists to
                // rule out; firing the same shortcut again instead
                // moves focus straight to the search field.
                if action == .clipboard { model.wantsClipboardSearch = true }
            }
        }
        hotKeys.reload()

        // Tiny menu bar item so the agent app can be quit
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The house mark: the island with an echo around it, in the same
        // bold cut the in-app glyph uses and off the same constants, so
        // the two can never drift. Two fills rather than one, because the
        // echo is half opaque and the island is solid. A template image
        // keeps its alpha, so the half stays half.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let rect = CGRect(x: 0, y: 0, width: 18, height: 18)
            // AppKit counts y upward and the artwork counts it downward,
            // so every rect is flipped about the frame's middle.
            func placed(_ item: CGRect) -> NSRect {
                let fitted = ChalantMark.fitted(item, in: rect)
                return NSRect(
                    x: fitted.minX, y: rect.height - fitted.maxY,
                    width: fitted.width, height: fitted.height
                )
            }
            _ = bounds

            let ring = placed(ChalantMark.ring)
            let echo = NSBezierPath(roundedRect: ring, xRadius: ring.height / 2,
                                    yRadius: ring.height / 2)
            echo.lineWidth = ChalantMark.scaled(ChalantMark.ringStroke, in: rect)
            NSColor.black.withAlphaComponent(ChalantMark.ringOpacity).setStroke()
            echo.stroke()

            let pillRect = placed(ChalantMark.pill)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2,
                         yRadius: pillRect.height / 2).fill()
            return true
        }
        icon.isTemplate = true
        item.button?.image = icon
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Chalant",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        Task { @MainActor in self.showDashboard(section: nil) }
    }

    /// Opening an already-running accessory app — double-clicking it in
    /// Finder, hitting return on it in Spotlight — did nothing at all,
    /// because there was no window for the system to bring forward.
    /// Now it shows the one there is.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        showDashboard(section: nil)
        return true
    }

    @MainActor
    private func showDashboard(section: DashboardSection?) {
        guard let model = notchController?.viewModel else { return }
        // The island is a glance surface and settings is a window; both
        // lit at once is two places claiming the same job.
        model.collapse()
        let controller = dashboardController ?? DashboardWindowController(model: model)
        dashboardController = controller
        controller.present(section: section)
    }

    /// One-time inheritance from the app's earlier names. The newest
    /// era found wins (a Cove domain already carries what it took
    /// from Moai): its domain is copied wholesale, minus the keys
    /// that wore the old prefix, which are re-homed under chalant.
    /// Existing values are never overwritten; a fresh install finds
    /// nothing and moves on.
    private func migrateFromMoai() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "chalant.migrated") else { return }
        let eras = [("com.cj.plum", "plum."), ("com.cj.cove", "cove."), ("com.cj.moai", "moai.")]
        // Skip EVERY era's prefix, not just the current one: a Cove
        // domain still carried literal moai.* keys from its own
        // migration, and copying them wholesale littered the chalant
        // domain with dead keys (review-caught, harmless but untidy).
        let eraPrefixes = eras.map(\.1)
        for (domain, prefix) in eras {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old
            where defaults.object(forKey: key) == nil
                && !eraPrefixes.contains(where: key.hasPrefix) {
                defaults.set(value, forKey: key)
            }
            for key in ["onboarded", "lastMusicApp", "lastUpdateNudge",
                        "notes", "focusStats", "focusGoal"] {
                if let value = old[prefix + key],
                   defaults.object(forKey: "chalant." + key) == nil {
                    defaults.set(value, forKey: "chalant." + key)
                }
            }
            break
        }
        defaults.set(true, forKey: "chalant.migrated")
    }
}
