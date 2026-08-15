import AppKit
import os

/// Borrows the clipboard for one paste and gives it back.
///
/// **Part 0 §0.2 redesigned this.** macOS 26 can alert the user, or refuse
/// per-app, when an app programmatically READS the general pasteboard outside
/// a user-initiated paste. Our write plus a synthesized ⌘V is paste-adjacent
/// and low risk; the exposure is the snapshot read that preserves whatever the
/// user already had. §0.2's resolution is to design as if the mechanism is on,
/// and to make preservation a capability that degrades:
///
/// > if the read would prompt or is denied, skip preservation for that
/// > insertion, notify once, continue. **Never let a privacy prompt block the
/// > paste itself.**
///
/// So a denied clipboard costs the user their previous clipboard contents, and
/// never costs them their dictation.
actor PasteboardGuard {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    /// Community convention, honoured by every clipboard manager worth the
    /// name, so our transient value is not archived into someone's history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Whether the user has been told that preservation is off. Once, not once
    /// per utterance.
    private var warnedAboutPreservation = false

    struct Snapshot: Sendable {
        let items: [[String: Data]]
        let changeCount: Int
    }

    /// Everything currently on the clipboard, or nil when it cannot be read.
    ///
    /// Nil is a normal outcome, not an error: the paste proceeds either way.
    func snapshot() -> Snapshot? {
        let board = NSPasteboard.general

        // Ask about policy before touching contents. §0.2: never read contents
        // just to check something.
        //
        // `accessBehavior` arrived in macOS 15.4 and Chalant's floor is 15.0,
        // so this is still a real range. Below 15.4 the pasteboard privacy model
        // does not exist at all, so there is no policy to ask about and no
        // prompt to avoid: reading is unrestricted and preservation works.
        if #available(macOS 15.4, *) {
            if board.accessBehavior == .alwaysDeny {
                if !warnedAboutPreservation {
                    warnedAboutPreservation = true
                    Self.log.error("clipboard reads are denied; preservation is off for this app")
                }
                return nil
            }
        }

        var captured: [[String: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var byType: [String: Data] = [:]
            for type in item.types {
                // Reading our own transient marker back would be pointless, and
                // some promised types cannot be resolved without side effects.
                guard let data = item.data(forType: type) else { continue }
                byType[type.rawValue] = data
            }
            if !byType.isEmpty { captured.append(byType) }
        }
        return Snapshot(items: captured, changeCount: board.changeCount)
    }

    /// Put the dictated text on the clipboard, marked transient.
    /// Returns the change count afterwards, so a paste can be verified.
    @discardableResult
    func place(_ text: String) -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Empty data, not absent: the marker's presence is the signal.
        item.setData(Data(), forType: Self.transientType)
        board.writeObjects([item])
        return board.changeCount
    }

    /// Give the clipboard back.
    ///
    /// **1.5 seconds, not the 40-80ms the original spec guessed.** Part 1 §1
    /// corrects this: Chromium reads the pasteboard asynchronously, so
    /// restoring too quickly makes Chrome and every Electron app paste the
    /// user's OLD clipboard instead of the dictation. A competitor's own docs
    /// independently recommend 500ms to 2s.
    func restore(_ snapshot: Snapshot) async {
        try? await Task.sleep(for: .milliseconds(1500))

        let board = NSPasteboard.general
        board.clearContents()

        var restored: [NSPasteboardItem] = []
        for stored in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            restored.append(item)
        }
        if !restored.isEmpty {
            board.writeObjects(restored)
        }
        Self.log.info("clipboard restored (\(restored.count, privacy: .public) items)")
    }

    /// True when the pasteboard changed since `place`, which is the closest
    /// thing to proof that the target app actually consumed our paste.
    /// Part 0 §0.3: "event sent" is not "text landed".
    func wasConsumed(since changeCount: Int) -> Bool {
        NSPasteboard.general.changeCount != changeCount
    }
}
