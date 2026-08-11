import AppKit
import Foundation
import os

/// Whether the last run ended badly, and why.
///
/// Nothing in the app knew it had ever crashed. A build shipped that any
/// local process could kill with one line, and the only signal was the
/// owner eventually saying it "feels unstable". Everything else about
/// stability is guesswork until this exists.
///
/// macOS already writes a full report for every crash. This reads the
/// newest one, says so once, and offers it for copying. Nothing is sent
/// anywhere, nothing new is written to disk, and the reports are left
/// exactly where the system put them.
///
/// Two crash families reach here, and it matters that both do:
/// Objective-C exceptions (`AVAudioEngine` raising on a second tap) and
/// Swift runtime traps (a negative length, an overflowed multiply). An
/// uncaught-exception handler only ever sees the first kind, because a
/// Swift trap is a SIGTRAP and never travels through it. Reading the
/// report afterwards is the only thing that catches both.
@MainActor
final class CrashWatch: ObservableObject {
    static let log = Logger(subsystem: "com.cj.chalant", category: "crash")

    struct Report: Equatable {
        var date: Date
        /// One line, in the framework's own words. No user content
        /// passes through here: a Swift trap message is a compiler
        /// string and an exception reason is AppKit's.
        var reason: String
        var path: URL
    }

    /// The crash the user has not been told about yet.
    @Published private(set) var unreported: Report?

    /// The newest report already shown, so a crash is mentioned once
    /// and not on every launch afterwards.
    private static let seenKey = "chalant.crashSeenAt"

    /// The activity row's id, so acknowledging can clear it.
    static let activityID = "chalant.crash"

    /// Where macOS keeps them, and where it moves them afterwards.
    ///
    /// Reports do not sit in the top directory for long: the system
    /// rotates them into `Retired` on its own schedule, and a crash from
    /// twenty minutes ago was already in there when this was first
    /// tested. Scanning only the top level found nothing at all, which
    /// would have shipped as "we never crash".
    private static var reportDirectories: [URL] {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask).first
        else { return [] }
        let root = library.appendingPathComponent("Logs/DiagnosticReports")
        return [root, root.appendingPathComponent("Retired")]
    }

    /// Look for a crash newer than the last one mentioned.
    ///
    /// Every step here is optional-guarded on purpose. This runs at
    /// launch, on a directory owned by the system, holding files written
    /// by a process that was in the act of dying: the one thing it must
    /// never do is take the app down while explaining why the app went
    /// down.
    func check() {
        let seenAt = UserDefaults.standard.object(forKey: Self.seenKey) as? Date
            ?? .distantPast
        guard let newest = Self.newestReport(after: seenAt) else { return }
        unreported = newest
        Self.log.notice(
            "last run ended in a crash: \(newest.reason, privacy: .public)")
    }

    /// The user has been told. Do not mention this one again.
    func acknowledge() {
        if let date = unreported?.date {
            UserDefaults.standard.set(date, forKey: Self.seenKey)
        }
        unreported = nil
    }

    /// The report has been put in front of the user (the card pushed,
    /// the glance flashed): record that, so the next launch stays
    /// quiet, but keep `unreported` for this session so "crash report"
    /// can still read it out. The card's X never called acknowledge(),
    /// which is how one August crash greeted every launch for days.
    /// `defaults` is injectable so tests get their own domain: this
    /// bundle runs inside the app, so `standard` here is the founder's
    /// real preferences, and a test that erases this key re-arms a
    /// crash banner on their machine.
    static func markSeen(_ date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: seenKey)
    }

    func markSeenNow() {
        if let date = unreported?.date { Self.markSeen(date) }
    }

    /// The whole report on the pasteboard, for pasting into an issue.
    /// Explicit action only: these files name paths and loaded
    /// libraries, so nothing copies itself.
    @discardableResult
    func copyReportToPasteboard() -> Bool {
        guard let path = unreported?.path,
              let text = try? String(contentsOf: path, encoding: .utf8)
        else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// What to say about it, in one line.
    var summary: String {
        guard let report = unreported else {
            return "No crash on record since the last time you asked."
        }
        let when = DateFormatter.localizedString(
            from: report.date, dateStyle: .none, timeStyle: .short)
        return "Chalant quit unexpectedly at \(when). \(report.reason)"
    }

    // MARK: - Reading what the system wrote

    private static func newestReport(after date: Date) -> Report? {
        var best: Report?
        for directory in reportDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path)) ?? []
            for name in names where isOurs(name) {
                let url = directory.appendingPathComponent(name)
                guard let written = modifiedAt(url), written > date else { continue }
                if let current = best, current.date >= written { continue }
                best = Report(date: written, reason: reason(in: url), path: url)
            }
        }
        return best
    }

    private static func isOurs(_ name: String) -> Bool {
        // The bundle writes reports named for the executable. Both
        // extensions appear across macOS versions.
        (name.hasPrefix("Chalant-") || name.hasPrefix("Chalant_"))
            && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
    }

    private static func modifiedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func reason(in url: URL) -> String {
        // Bounded on purpose: a report is normally tens of kilobytes,
        // and anything wildly larger is not worth reading at launch.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard size ?? 0 <= 4 * 1024 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "Reason unavailable." }
        return reason(inReportText: text)
    }

    /// The most useful single line the report contains.
    static func reason(inReportText text: String) -> String {
        // A Swift trap writes its message straight into the frame
        // symbols, and it names the bug outright: "Can't take a prefix
        // of negative length from a collection" is the whole diagnosis.
        for marker in ["Swift runtime failure: ", "Fatal error: "] {
            if let found = firstLine(after: marker, in: text) {
                return marker + found
            }
        }
        // An Objective-C exception carries its own reason instead.
        if let found = firstLine(after: "\"reason\":\"", in: text) {
            return found
        }
        // Otherwise the signal is still worth naming.
        if let found = firstLine(after: "\"indicator\":\"", in: text) {
            return "Ended on \(found)."
        }
        return "No reason recorded in the report."
    }

    /// Text following `marker`, up to the first quote or newline, capped
    /// so a malformed report cannot hand back a screenful.
    private static func firstLine(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].prefix(300)
        let line = tail.prefix { $0 != "\"" && $0 != "\n" && $0 != "\\" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}
