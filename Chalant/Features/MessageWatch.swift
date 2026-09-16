import AppKit
import ApplicationServices
import Foundation

/// Catches an incoming iMessage the moment macOS puts its banner on
/// screen, so a reply can be spoken at the island instead of hunting
/// for the Messages window.
///
/// **Why the banner, and not the obvious places.** Measured on macOS
/// 26 (2026-09-15, the probe behind this feature):
///
/// - Messages' automation dictionary cannot read a message at all.
///   The whole vocabulary is `send`, `login`, `logout` plus read-only
///   `account`, `chat`, `participant` and `file transfer`. There is no
///   message class, no text property, and no "message received" event.
///   Do not go looking again.
/// - `~/Library/Messages/chat.db` answers `Operation not permitted`
///   without Full Disk Access, the heaviest permission on the Mac.
/// - The banner reads out through Accessibility, which this app
///   already holds because that is how it types for you. No new grant,
///   no new dialog, nothing for anyone to approve.
///
/// **The property that will look like a bug.** No banner means no
/// card. A Focus mode, previews set to hidden, or Messages
/// notifications turned off all leave this silent by design: those
/// settings are the user's own filter and this adds no second one.
@MainActor
final class MessageWatch {
    /// Everything a banner will say about itself, flattened into
    /// strings so the reading of it can be tested without a live
    /// screen. The AX walk fills this in; ``sighting(from:)`` is the
    /// only thing that interprets it.
    struct Banner: Equatable {
        /// Every static text in the window, in tree order.
        var texts: [String] = []
        /// Every `AXIdentifier` found anywhere in the window. Measured
        /// 2026-09-15: these are generic layout names
        /// (`widgets-overlay-view`, `title`, `body`) plus the
        /// notification's own UUID. **The posting app is not here**,
        /// which is why identifiers alone cannot tell a Messages
        /// banner from a calendar one.
        var identifiers: [String] = []
        /// Every description and title in the window. **This is where
        /// the posting app names itself**, measured 2026-09-15: the
        /// banner carries one description shaped `App, title, body`,
        /// for example `Script Editor, Alpha Sender, First body`. The
        /// window itself describes as `Notification Center`.
        var descriptions: [String] = []
    }

    struct Sighting: Equatable {
        let sender: String
        let body: String
        let seen: Date
    }

    /// What Messages is called on this Mac, in this language. Asked of
    /// the system rather than hard-coded, because a banner names its
    /// app the way the user sees it: "Messages" here, "Nachrichten" on
    /// a German Mac, and a hard-coded English string would make this
    /// feature silently do nothing abroad.
    static let messagesAppName: String = {
        let path = "/System/Applications/Messages.app"
        let shown = FileManager.default.displayName(atPath: path)
        // displayName hands back the last path component when it knows
        // nothing, extension and all.
        return shown.isEmpty || shown.hasSuffix(".app") ? "Messages" : shown
    }()

    /// The reading, with no screen involved.
    ///
    /// The first line of a Messages banner is who, the rest is what
    /// they said. A banner with only one line is a notification with
    /// no message in it (previews hidden, most often), and that is not
    /// something anyone can reply to, so it is not a sighting.
    static func sighting(from banner: Banner, now: Date = Date()) -> Sighting? {
        guard isMessages(banner) else { return nil }
        let lines = banner.texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let sender = lines[0]
        let body = lines.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !body.isEmpty else { return nil }
        return Sighting(sender: sender, body: body, seen: now)
    }

    /// Did Messages post this banner?
    ///
    /// The test is the app's own name in the first field of a banner
    /// description, not a substring search: a text reading "Messages,
    /// have you seen this" would otherwise make a calendar alert look
    /// like a conversation.
    static func isMessages(_ banner: Banner, appName: String = messagesAppName) -> Bool {
        banner.descriptions.contains { described in
            guard let first = described.split(
                separator: ",", maxSplits: 1, omittingEmptySubsequences: false
            ).first else { return false }
            return first.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(appName) == .orderedSame
        }
    }

    /// What may be written about a banner: the name of the app that
    /// posted it, and for one this does not recognize, the identifiers
    /// that would explain why.
    ///
    /// **Never the title and never the body.** A description reads
    /// `App, title, body`, so only its first field may be logged; the
    /// rest is somebody's actual message, which is what this feature is
    /// for and never what its log is for. `MessageWatchTests` holds
    /// this to it.
    static func logMarkers(for banner: Banner, matched: Bool) -> [String] {
        let apps = banner.descriptions.map { described in
            described.split(
                separator: ",", maxSplits: 1, omittingEmptySubsequences: false
            ).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        var seen: [String] = []
        for field in apps + (matched ? [] : banner.identifiers)
        where !field.isEmpty && !seen.contains(field) && seen.count < 10 {
            seen.append(field)
        }
        return seen
    }

    // MARK: - The live watch

    /// Called on the main actor for every message that arrives while
    /// this is running.
    var onSighting: ((Sighting) -> Void)?

    /// Set while learning what a real banner carries: every banner
    /// seen is written to the wire log, matched or not, with the
    /// message body left out of it. Identifiers and the sender are
    /// enough to finish the classifier; the words somebody sent are
    /// nobody's debugging material.
    var logsEveryBanner = true

    private var observer: AXObserver?
    private var element: AXUIElement?
    private var lastSighting: (sender: String, body: String, at: Date)?

    /// A window announces itself before it has drawn its children, so
    /// the tree is read a beat later. Measured at 0.35 s on this Mac:
    /// shorter than a banner's life by an order of magnitude, longer
    /// than the gap between the window arriving and its text existing.
    private static let settleDelay: TimeInterval = 0.35

    /// The same banner can fire more than one window-created event.
    /// Two sightings with the same words this close together are one
    /// message.
    private static let dedupeWindow: TimeInterval = 3

    @discardableResult
    func start() -> Bool {
        guard observer == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        guard let center = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first, center.processIdentifier > 0
        else { return false }

        let app = AXUIElementCreateApplication(center.processIdentifier)
        var made: AXObserver?
        let created = AXObserverCreate(
            center.processIdentifier,
            { _, element, _, refcon in
                guard let refcon else { return }
                let watch = Unmanaged<MessageWatch>
                    .fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { watch.windowAppeared(element) }
            },
            &made
        )
        guard created == .success, let made else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = AXObserverAddNotification(
            made, app, kAXWindowCreatedNotification as CFString, refcon
        )
        guard added == .success else { return false }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(made),
            .defaultMode
        )
        observer = made
        element = app
        return true
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            if let element {
                AXObserverRemoveNotification(
                    observer, element, kAXWindowCreatedNotification as CFString
                )
            }
        }
        observer = nil
        element = nil
    }

    private func windowAppeared(_ window: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self else { return }
            let banner = Self.read(window)
            if logsEveryBanner {
                let mine = Self.isMessages(banner)
                // Nothing anybody wrote is logged, and neither is who
                // wrote it: a log that has to be sanitized before it can
                // be pasted is a log nobody pastes.
                // Only the FIRST field of each description, which is the
                // app's own name. The rest of that string is the title
                // and the body, meaning somebody's actual message: it
                // is what this feature is for, never what its log is
                // for. A banner this does not recognize brings its
                // identifiers along, because if a real Messages banner
                // ever fails to match, those are the next place to look.
                let seen = Self.logMarkers(for: banner, matched: mine)
                WireLog.note(
                    event: "banner",
                    ntype: seen.isEmpty ? "no-desc" : seen.joined(separator: "|"),
                    tool: mine ? "messages" : "other",
                    response: "lines=\(banner.texts.count) fields=\(banner.descriptions.count)"
                )
            }
            guard let sighting = Self.sighting(from: banner) else { return }
            guard !isRepeat(sighting) else { return }
            lastSighting = (sighting.sender, sighting.body, sighting.seen)
            onSighting?(sighting)
        }
    }

    private func isRepeat(_ sighting: Sighting) -> Bool {
        guard let last = lastSighting else { return false }
        guard last.sender == sighting.sender, last.body == sighting.body else {
            return false
        }
        return sighting.seen.timeIntervalSince(last.at) < Self.dedupeWindow
    }

    // MARK: - Reading a window

    /// Walk the window into a ``Banner``. Bounded on purpose: a
    /// runaway tree must never hold the main thread while somebody is
    /// mid-sentence.
    static func read(_ window: AXUIElement, limit: Int = 200) -> Banner {
        var banner = Banner()
        var queue: [AXUIElement] = [window]
        var seen = 0

        while !queue.isEmpty, seen < limit {
            let element = queue.removeFirst()
            seen += 1

            if let identifier = string(element, kAXIdentifierAttribute),
               !identifier.isEmpty {
                banner.identifiers.append(identifier)
            }
            if string(element, kAXRoleAttribute) == kAXStaticTextRole,
               let value = string(element, kAXValueAttribute),
               !value.isEmpty {
                banner.texts.append(value)
            }
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let described = string(element, attribute), !described.isEmpty {
                    banner.descriptions.append(described)
                }
            }
            queue.append(contentsOf: children(element))
        }
        return banner
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }
}
