import AppKit
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

    /// **On, and the precondition for that is `LearnedTermsList`, not this
    /// file.**
    ///
    /// Part 0 §0.15 requires every learned pair to be inspectable and
    /// reversible in UI. That is not a nicety to add afterwards: a wrong pair
    /// rewrites one of the user's words on every future utterance, so without a
    /// way to see it and delete it the feature is a permanent bug nobody can
    /// reach. This shipped off until that screen existed, and the day it landed
    /// is the day the default changed.
    ///
    /// Still a visible switch rather than a silent default, which is the same
    /// exception `CorpusCapture` claims: everything else in this app goes out
    /// of its way not to keep what you said, and anything that watches you type
    /// says so out loud.
    static let enabledKey = "dictationLearnCorrections"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// How long a correction stays interesting. Part 8 §3 said ~20 seconds.
    /// **45 now, measured 2026-08-16:** the founder reads a message back before
    /// fixing it, and 20 was gone before the fix landed.
    private static let window: Duration = .seconds(45)
    private static let interval: Duration = .milliseconds(750)

    /// One watch PER APP, not one watch. Measured 2026-08-16 in the founder's
    /// own hands: they dictate in bursts, Slack, then a word to the terminal,
    /// then Chrome, and a single "the next dictation cancels the watch" rule
    /// meant Slack was never observed once in five minutes of trying. A new
    /// insertion replaces the watch for THAT app only; the others keep looking,
    /// and each only reads the field while its own app is in front, so a
    /// dictation elsewhere cannot be mistaken for an edit here.
    private var watching: [String: Task<Void, Never>] = [:]

    /// Which apps this has ever managed to read, so coverage is measurable
    /// rather than assumed. Process-lifetime only; it is a diagnostic, not a
    /// record of what the user did.
    private var readable: Set<String> = []
    private var unreadable: Set<String> = []

    func watch(inserted: String, in bundleID: String?) {
        guard Self.isEnabled(), !inserted.isEmpty else { return }

        // A second dictation into the SAME app means the user has moved on
        // there; watches on other apps are still live.
        let key = bundleID ?? ""
        watching[key]?.cancel()
        watching[key] = Task { [inserted, bundleID] in
            await self.poll(inserted: inserted, bundleID: bundleID)
        }
    }

    func stop() {
        for task in watching.values { task.cancel() }
        watching = [:]
    }

    private func poll(inserted: String, bundleID: String?) async {
        let deadline = ContinuousClock.now + Self.window
        var sawAnything = false

        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }

            // Only this watch's own app. The focused field belongs to whatever
            // is in front, and a burst of dictation elsewhere must not be
            // diffed against words that went somewhere else.
            if let bundleID, Self.frontmostBundleID() != bundleID { continue }

            guard let field = Self.focusedFieldValue() else { continue }
            sawAnything = true

            let pairs = Correction.learnings(inserted: inserted, nowReads: field)
            guard !pairs.isEmpty else { continue }
            for pair in pairs {
                let isWord = await Self.isDictionaryWord(pair.heard)
                await LearnedTerms.shared.record(pair, heardIsWord: isWord)
            }
            note(bundleID, readable: true)
            // One round of corrections per insertion. A further edit to the
            // same text is the user writing, not fixing.
            return
        }

        note(bundleID, readable: sawAnything)
    }

    /// Whether the system spell checker knows this as an English word.
    /// "challenge" yes; "Kisu", "Shalan", "Kiesel" no. It decides whether a
    /// learned exact rewrite is trusted from the first sighting: a name
    /// misheard as a real word must not start rewriting that real word after
    /// one fix (2026-08-16, "challenge" for Chalant on the first live run).
    @MainActor
    static func isDictionaryWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
