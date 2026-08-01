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

        // The island itself
        let controller = NotchWindowController()
        controller.show()
        notchController = controller
        controller.viewModel.installUpdate = { [weak self] in
            self?.updater.checkForUpdates(nil)
        }

        // Tiny menu bar item so the agent app can be quit
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The house mark, drawn by hand: the notch wearing two half-lidded
        // eyes, punched through. Even-odd fill keeps the eyes open. Matches
        // the app icon exactly; no capsule, so it can't read as a toggle.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Same 240 x 140 proportions as ChalantMarkShape, in AppKit's
            // y-up space: the flat edge on top, the rounded corners below.
            let w: CGFloat = 16, h = w / ChalantMark.aspect
            let x0 = (18 - w) / 2, x1 = x0 + w
            let yBot = (18 - h) / 2, yTop = yBot + h
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            let r = ChalantMark.underRadius * w
            path.move(to: NSPoint(x: x0, y: yTop))          // the flat top edge
            path.line(to: NSPoint(x: x1, y: yTop))
            path.appendArc(from: NSPoint(x: x1, y: yBot), to: NSPoint(x: x0, y: yBot), radius: r)
            path.appendArc(from: NSPoint(x: x0, y: yBot), to: NSPoint(x: x0, y: yTop), radius: r)
            path.close()

            // At 18pt the brand eye proportion is a sub-pixel slit, so the
            // lids thicken and the eyes move apart, as in the small icons.
            let ew = ChalantMark.eyeWidth * w
            let eh = ChalantMark.eyeHeight * h * 1.9
            let gap = ChalantMark.eyeGap * w * 1.3
            let cy = yTop - ChalantMark.eyeCentreY * h     // y-up: measured down from the top
            let rt = min(ChalantMark.lidRadius * eh, ew / 2)
            let rb = min(ChalantMark.underEyeRadius * eh, ew / 2)
            for side in [CGFloat(-1), CGFloat(1)] {
                let cx = 9.0 + side * (gap / 2 + ew / 2)
                let ex0 = cx - ew / 2, ex1 = cx + ew / 2
                let ey0 = cy - eh / 2, ey1 = cy + eh / 2   // ey1 is the lid, y-up
                path.move(to: NSPoint(x: ex0 + rt, y: ey1))
                path.line(to: NSPoint(x: ex1 - rt, y: ey1))
                path.appendArc(from: NSPoint(x: ex1, y: ey1), to: NSPoint(x: ex1, y: ey0), radius: rt)
                path.appendArc(from: NSPoint(x: ex1, y: ey0), to: NSPoint(x: ex0, y: ey0), radius: rb)
                path.appendArc(from: NSPoint(x: ex0, y: ey0), to: NSPoint(x: ex0, y: ey1), radius: rb)
                path.appendArc(from: NSPoint(x: ex0, y: ey1), to: NSPoint(x: ex1, y: ey1), radius: rt)
                path.close()
            }
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
        Task { @MainActor in
            guard let model = self.notchController?.viewModel else { return }
            model.expand()
            model.pane = .settings
        }
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
