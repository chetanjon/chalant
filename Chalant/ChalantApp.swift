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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time inheritance from the Moai era: the rename changed
        // the bundle id, which changed the defaults domain, which
        // would have orphaned every setting, note, and focus streak.
        migrateFromMoai()
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
        // The house mark, drawn by hand: a thin, quiet c. The letter
        // of the name as an almost-circle, open on one side.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: NSPoint(x: 9, y: 9),
                radius: 6.1,
                startAngle: 42,
                endAngle: -42,
                clockwise: false
            )
            arc.lineWidth = 2.1
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
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
