import ApplicationServices
import ChalantDictationCore
import Foundation
import os

/// Watches what the user does to the words Chalant just gave them.
///
/// **Polling, not `AXObserver`, and Part 2 §6 is the reason:** *"AXObserver is
/// unreliable for the correction observer. Many apps never emit
/// `AXValueChanged`."* An observer that silently never fires in Slack and VS
/// Code is worse than no observer, because it looks like it works. Reading the
/// value on a timer works wherever reading works at all, and `CursorContext`
/// already proves that primitive against real apps.
///
/// **Coverage is recorded per bundle identifier**, also per §2 §6, because the
/// honest question about this feature is not "does it work" but "where", and
/// that can only be answered from real use.
///
/// **What it reads and what it keeps are very different things.** It reads the
/// focused text field, which is the user's document. It keeps a pair of words,
/// or nothing. Nothing else is retained, logged or written, and `Correction`
/// refuses far more edits than it accepts.
actor CorrectionObserver {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "learn")

    static let shared = CorrectionObserver()

    /// **OFF until the pairs can be seen and deleted in the app.**
    ///
    /// Part 0 §0.15 is explicit that every learned pair must be inspectable and
    /// reversible in UI, and that screen does not exist yet. A feature that
    /// silently learns from someone who cannot see what it learned, or undo it,
    /// is the exact trust failure that requirement was written to prevent, and
    /// a wrong pair would then rewrite one of their words on every future
    /// utterance with no way out.
    ///
    /// The pairs live in readable JSON at `LearnedTerms.file`, which is enough
    /// for the founder to dogfood it deliberately. It is not enough to turn on
    /// for anyone else. **Building the settings list is what unblocks the
    /// default, not more evidence that the classifier works.**
    static let enabledKey = "dictationLearnCorrections"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// How long a correction stays interesting. Part 8 §3 says ~20 seconds:
    /// long enough for someone to notice a wrong name and fix it, short enough
    /// that the next thing they type is a different thought entirely.
    private static let window: Duration = .seconds(20)
    private static let interval: Duration = .milliseconds(750)

    private var watching: Task<Void, Never>?

    /// Which apps this has ever managed to read, so coverage is measurable
    /// rather than assumed. Process-lifetime only; it is a diagnostic, not a
    /// record of what the user did.
    private var readable: Set<String> = []
    private var unreadable: Set<String> = []

    func watch(inserted: String, in bundleID: String?) {
        guard Self.isEnabled(), !inserted.isEmpty else { return }

        // One watch at a time. A second dictation means the user has moved on
        // and the first correction is no longer the interesting one.
        watching?.cancel()
        watching = Task { [inserted, bundleID] in
            await self.poll(inserted: inserted, bundleID: bundleID)
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
    }

    private func poll(inserted: String, bundleID: String?) async {
        let deadline = ContinuousClock.now + Self.window
        var sawAnything = false

        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }

            guard let field = Self.focusedFieldValue() else { continue }
            sawAnything = true

            guard let pair = Correction.learning(inserted: inserted, nowReads: field) else {
                continue
            }
            await LearnedTerms.shared.record(pair)
            note(bundleID, readable: true)
            // One correction per insertion. A second edit to the same text is
            // the user writing, not fixing.
            return
        }

        note(bundleID, readable: sawAnything)
    }

    private func note(_ bundleID: String?, readable ok: Bool) {
        guard let bundleID else { return }
        let known = ok ? readable.contains(bundleID) : unreadable.contains(bundleID)
        guard !known else { return }
        if ok { readable.insert(bundleID) } else { unreadable.insert(bundleID) }
        Self.log.info(
            "correction observer \(ok ? "can" : "cannot", privacy: .public) read \(bundleID, privacy: .public)")
    }

    /// The whole value of the focused text field, or nil where the app will not
    /// say. Same primitive `CursorContext` uses, and it fails the same way: in
    /// Electron and web content there is often no focused element at all, which
    /// Part 1 §1 established while removing Accessibility from the insertion
    /// path. Here that costs a learning opportunity and nothing else.
    private static func focusedFieldValue() -> String? {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return nil }

        var valueRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                unsafeBitCast(element, to: AXUIElement.self), kAXValueAttribute as CFString,
                &valueRef) == .success,
            let text = valueRef as? String
        else { return nil }

        return text
    }
}
