import AppKit
import ChalantDictationCore

/// The impure shell, as thin as Part 2 §2 asks for.
///
/// M0's whole UI is a menu bar item: it shows whether the language model is
/// ready, whether the key is being held, and the last measured latency. Part 3
/// calls M0 deliberately ugly, and the point is to prove the seam between
/// audio, ASR and insertion before any logic exists to obscure a failure.
@main
enum ChalantDictationApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let controller = DictationController()
    private var monitor: EventTapMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu()
        self.item = item

        controller.onStateChange = { [weak self] in self?.render() }
        render()

        // Part 2 §5: permissions are requested lazily, one at a time, never at
        // launch. The tap below is what raises the Accessibility ask, and the
        // microphone ask comes with the first capture.
        let monitor = EventTapMonitor { [weak self] down in
            guard let self else { return }
            Task { down ? await self.controller.keyDown() : await self.controller.keyUp() }
        }
        self.monitor = monitor
        if !monitor.start() {
            render(accessibilityMissing: true)
        }

        Task { await controller.warmUp() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    private func render(accessibilityMissing: Bool = false) {
        guard let item else { return }

        item.button?.title = controller.isListening ? "◉" : "○"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: statusLine(accessibilityMissing), action: nil, keyEquivalent: ""))

        if let latency = controller.lastLatency {
            menu.addItem(
                NSMenuItem(
                    title: String(format: "Last: %.2fs to visible", latency),
                    action: nil,
                    keyEquivalent: ""
                )
            )
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hold left Option to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu
    }

    /// The asset state machine rendered as a real UI condition rather than an
    /// error, which is what Part 0 §0.6 asks for and what M0's acceptance
    /// criterion turns on.
    private func statusLine(_ accessibilityMissing: Bool) -> String {
        if accessibilityMissing {
            return "Needs Accessibility in System Settings"
        }
        switch controller.assetState {
        case .checking:
            return "Checking the language model…"
        case .downloading(let fraction):
            return "Downloading the language model… \(Int(fraction * 100))%"
        case .available:
            if controller.micPermission == .denied { return "Microphone access is off" }
            if !AccessibilityPermission.isTrusted { return "Needs Accessibility to paste" }
            return controller.isListening ? "Listening" : "Ready"
        case .unsupported(let requested):
            return "No language model for \(requested)"
        case .failed(let reason):
            return "Speech unavailable: \(reason)"
        }
    }
}
