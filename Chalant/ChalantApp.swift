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
            .clipboard: { [weak controller] in
                guard let model = controller?.viewModel else { return }
                // Straight to the pane, not merely open: the shortcut
                // exists to skip the switcher, and landing on Today
                // would leave the user one click from where they asked
                // to be.
                model.tab = .clipboard
                model.expand()
            },
            .openSettings: { [weak self] in
                self?.showDashboard(section: nil)
            },
        ]
        hotKeys.reload()

        // Tiny menu bar item so the agent app can be quit
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The house mark, drawn by hand: the little watcher. A floating
        // bar over a tapered body with one eye, its ember punched
        // through. Even-odd fill keeps the eye open. Matches the app
        // icon exactly; no capsule, so it can't read as a toggle.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // The brand-SVG emblem (512 space) mapped into 18pt, y
            // flipped (AppKit is y-up): the bar sits high, the flared
            // body hangs below, eye low. Same geometry as the app icon.
            let s = 15.6 / 272.0
            func P(_ x: Double, _ y: Double) -> NSPoint {
                NSPoint(x: 9.0 + (x - 256) * s, y: 9.0 + (256 - y) * s)
            }
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            let bar0 = P(148, 188), bar1 = P(364, 120)  // flipped: bottom-left, top-right
            path.appendRoundedRect(
                NSRect(x: bar0.x, y: bar0.y, width: bar1.x - bar0.x, height: bar1.y - bar0.y),
                xRadius: 34 * s, yRadius: 34 * s
            )
            let corners = [P(172, 202), P(340, 202), P(387.95, 392), P(124.05, 392)]
            let radii = [0.0, 0.0, 20 * s, 20 * s]
            for i in 0..<4 {
                let cur = corners[i], prev = corners[(i + 3) % 4], next = corners[(i + 1) % 4]
                let r = radii[i]
                if r <= 0 {
                    if i == 0 { path.move(to: cur) } else { path.line(to: cur) }
                    continue
                }
                func unit(_ f: NSPoint, _ t: NSPoint) -> (Double, Double) {
                    let dx = t.x - f.x, dy = t.y - f.y, L = max((dx * dx + dy * dy).squareRoot(), 0.0001)
                    return (dx / L, dy / L)
                }
                let up = unit(cur, prev), un = unit(cur, next)
                let p1 = NSPoint(x: cur.x + up.0 * r, y: cur.y + up.1 * r)
                let p2 = NSPoint(x: cur.x + un.0 * r, y: cur.y + un.1 * r)
                path.line(to: p1)
                path.curve(to: p2, controlPoint1: cur, controlPoint2: cur)
            }
            path.close()
            let eye = P(256, 330), er = 28 * s
            path.appendOval(in: NSRect(x: eye.x - er, y: eye.y - er, width: er * 2, height: er * 2))
            NSColor.black.setFill()
            path.fill()
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
