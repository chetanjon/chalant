import AppKit
import ChalantDictationCore
import Foundation
import os

/// The full insertion ladder: System Events, then CGEvent, then the clipboard
/// floor, with per-app demotion learned from failures.
///
/// Part 3 M1 is the gate for the whole project: *"If this does not feel
/// invisible, stop the project here. Nothing downstream can compensate."*
///
/// Two rules shape every path through this type. Part 1 §2: never lose the
/// user's text, so the floor is always reachable and always leaves the words
/// somewhere recoverable. Part 0 §0.3: "event sent" is not "text landed", so
/// no tier reports success it has not verified.
/// macOS 15+, inherited from `AutomationPermission`'s `Mutex`. The ladder
/// itself, its tier policy and its demotion logic are all pure and live in
/// Core at the macOS 14 floor; only this shell carries the gate.
@available(macOS 15, *)
actor InsertionChain: TextInserter {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    private let pasteboard = PasteboardGuard()
    /// Per-app tier ceilings, learned. M4 moves this behind `TermRepository`
    /// and GRDB; in M1 it lives in memory and in UserDefaults so a demotion
    /// survives a relaunch without a schema.
    private var profiles: [String: AppProfile] = [:]

    private static let defaultsKey = "chalant.insert.profiles"

    init() {
        profiles = Self.loadProfiles()
    }

    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome {
        guard !text.isEmpty else { return .refused(reason: .noTarget) }

        // Dictating into a password field is an incident, not a bug. Part 1 §1:
        // IsSecureEventInputEnabled, never the AXSecureTextField role.
        if SecureInputProbe.isActive {
            let holder = SecureInputProbe.holderName()
            Self.log.error("refusing: secure input held by \(holder ?? "an unknown app", privacy: .public)")
            // The text still has to survive. Part 1 §2.
            await pasteboard.place(text)
            return .refused(reason: .secureInputActive(holder: holder))
        }

        // Part 2 §6: a synthesized ⌘V arrives corrupted if the user is still
        // holding the dictation key.
        await Self.waitForClearModifiers()

        let bundleID = target.bundleID ?? "unknown"
        let profile = profiles[bundleID] ?? AppProfile(bundleID: bundleID)
        let plan = TierPolicy.plan(for: profile)

        // Space it against what is already there. The context read is
        // best-effort and returns nil in Electron and web views by design;
        // `Spacing` treats nil as the safe default rather than a degraded one.
        let preceding = await MainActor.run { CursorContext.characterBeforeCursor() }
        let spaced = Spacing.pad(text, precededBy: preceding)

        // Preserve whatever the user had. Nil is fine and never blocks.
        let saved = await pasteboard.snapshot()
        let placedAt = await pasteboard.place(spaced)

        for tier in plan {
            // Re-check IMMEDIATELY before each attempt, not once at key-up.
            // Everything between capture and here is a window: the
            // modifier-clear wait alone runs up to 500ms, and the permission
            // checks, context read and pasteboard work all follow it. Global
            // case 2 of the M1 protocol, and observed live on 2026-08-12 when
            // an insertion aimed at Terminal landed in a browser.
            switch currentVerdict(for: target) {
            case .proceed:
                break
            case .changed(let from, let to):
                Self.log.error(
                    "target moved from \(from ?? "?", privacy: .public) to \(to ?? "?", privacy: .public); refusing"
                )
                // The words stay on the clipboard rather than being restored
                // away: refusing must not also discard what the user said.
                return .refused(reason: .targetChanged)
            case .unknown:
                Self.log.error("cannot identify the front app; refusing")
                return .refused(reason: .targetChanged)
            }

            let landed = await attempt(tier, text: spaced, placedAt: placedAt, bundleID: bundleID)
            if landed {
                record(success: tier, for: bundleID)
                if let saved { Task { await pasteboard.restore(saved) } }
                Self.log.info("inserted at tier \(tier.rawValue, privacy: .public) into \(bundleID, privacy: .public)")
                return .inserted(tier: tier)
            }
            record(failure: tier, for: bundleID)
        }

        // The floor. Part 0 §0.3 makes this "a first-class outcome with good
        // UX, not an apology": the words are on the clipboard and the user is
        // told in one sentence what to do about it.
        Self.log.error("all tiers failed for \(bundleID, privacy: .public); text left on clipboard")
        return .leftOnClipboard(reason: "Press ⌘V to paste it.")
    }

    /// What the system reports right now, compared against where the user aimed.
    private func currentVerdict(for target: InsertionTarget) -> TargetGuard.Verdict {
        let front = NSWorkspace.shared.frontmostApplication
        return TargetGuard.check(
            target: target,
            frontBundleID: front?.bundleIdentifier,
            frontPID: front?.processIdentifier
        )
    }

    // MARK: - Tiers

    private func attempt(
        _ tier: InsertionTier, text: String, placedAt: Int, bundleID: String
    ) async -> Bool {
        switch tier {
        case .systemEvents:
            guard AccessibilityPermission.isTrusted else {
                AccessibilityPermission.request()
                return false
            }
            guard case .granted = await AutomationPermission.ensureSystemEvents() else { return false }
            return SystemEventsPaste.run()

        case .cgEvent:
            CGEventInserter.sendPaste()
            // Part 0 §0.3: verify, because the events can be dropped silently.
            // A short grace period, because consumption is not instantaneous.
            try? await Task.sleep(for: .milliseconds(120))
            return await pasteboard.wasConsumed(since: placedAt)

        case .clipboardOnly:
            // Not an attempt at all: reaching it means the ladder is exhausted
            // and the loop should fall through to the floor.
            return false
        }
    }

    // MARK: - Demotion

    private func record(success tier: InsertionTier, for bundleID: String) {
        let profile = profiles[bundleID] ?? AppProfile(bundleID: bundleID)
        profiles[bundleID] = TierPolicy.recordingSuccess(of: tier, in: profile)
        saveProfiles()
    }

    private func record(failure tier: InsertionTier, for bundleID: String) {
        let profile = profiles[bundleID] ?? AppProfile(bundleID: bundleID)
        let updated = TierPolicy.recordingFailure(of: tier, in: profile)
        if updated.maxInsertionTier != profile.maxInsertionTier {
            Self.log.error("demoting \(bundleID, privacy: .public) past tier \(tier.rawValue, privacy: .public)")
        }
        profiles[bundleID] = updated
        saveProfiles()
    }

    // MARK: - Persistence (M4 replaces this with GRDB)

    private func saveProfiles() {
        let flat = profiles.mapValues { profile -> [String: Int] in
            var out: [String: Int] = [:]
            if let ceiling = profile.maxInsertionTier { out["ceiling"] = ceiling }
            for (tier, count) in profile.consecutiveFailures { out["f\(tier)"] = count }
            return out
        }
        UserDefaults.standard.set(flat, forKey: Self.defaultsKey)
    }

    private static func loadProfiles() -> [String: AppProfile] {
        guard let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Int]]
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            var failures: [Int: Int] = [:]
            for (key, value) in entry.value where key.hasPrefix("f") {
                if let tier = Int(key.dropFirst()) { failures[tier] = value }
            }
            result[entry.key] = AppProfile(
                bundleID: entry.key,
                maxInsertionTier: entry.value["ceiling"],
                consecutiveFailures: failures
            )
        }
    }

    private static func waitForClearModifiers(timeout: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = await MainActor.run { NSEvent.modifierFlags }
            if flags.intersection([.command, .option, .control, .shift]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}
