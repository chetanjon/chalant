import AppKit
import ChalantDictationCore

/// The impure shell, kept as thin as Part 2 §2 demands. Nothing here yet:
/// setup step 8 stops before any milestone, so this exists only to prove the
/// target builds, links the core, and launches as an LSUIElement agent.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // M0 gives this a real menu. For now it is proof of life, and proof
        // that the app target links the pure core.
        let item = NSStatusBarItem.system()
        item.button?.title = "◉"
        item.menu = NSMenu()
        item.menu?.addItem(
            NSMenuItem(title: "Chalant Dictation (scaffold)", action: nil, keyEquivalent: "")
        )
        item.menu?.addItem(.separator())
        item.menu?.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        self.item = item
    }
}

/// Tiny shim so the line above reads as intent rather than boilerplate.
private enum NSStatusBarItem {
    static func system() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
