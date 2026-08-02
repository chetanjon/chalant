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
