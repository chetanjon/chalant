import Foundation
import os

/// Chalant comes back when macOS stops it.
///
/// **Built because it happened twice in five days and nobody noticed either
/// time.** On 2026-09-05 the founder reported "chalant isnt working"; the app
/// was simply not running. macOS RunningBoard had terminated it the previous
/// evening (`explanation:"com.apple.frontboard.after-life.interrupted"`,
/// originated by MenuBarAgent) on a Mac at 88% swap after two weeks of uptime.
/// It was relaunched by hand. On 2026-09-10 it was found dead again, with no
/// log entries for three days: the founder had gone that long without
/// dictation, and the only reason anyone found out was that someone happened to
/// check.
///
/// A crash reports itself. A background app that macOS quietly reclaims does
/// not, and an LSUIElement has no Dock icon to look wrong, no window to
/// vanish, and no menu bar item once the process is gone. Holding the
/// microphone key and getting nothing is the only symptom, which reads as
/// "dictation is broken" rather than "the app is not there".
///
/// **The mechanism is launchd's, not ours**, because a dead process cannot
/// restart itself and a watchdog process would be one more thing to be killed.
/// `KeepAlive` with `SuccessfulExit: false` is exactly the distinction that
/// matters: a kill is an unclean exit and launchd starts us again, while
/// choosing Quit is a clean one and launchd lets us stay gone. A user who
/// quits an app expects it to be quit.
///
/// **It replaces the login item rather than joining it.** `RunAtLoad` covers
/// what `SMAppService.mainApp` covered, and running both would have two
/// launchers racing at every login. `AppDelegate` refuses a second instance,
/// so a duplicate is survivable rather than the doubled-text bug of
/// 2026-08-13, but the belt is better than the braces here.
enum StayRunning {
    static let log = Logger(subsystem: "com.cj.chalant", category: "stayrunning")

    static let label = "com.cj.chalant.keepalive"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Whether launchd is currently watching us.
    static var isOn: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The plist launchd reads. `Program` rather than `ProgramArguments` with
    /// `open`: launchd has to own the process it is watching, and `open` exits
    /// immediately, which would look like a clean exit every time.
    static func plist(executable: String) -> [String: Any] {
        [
            "Label": label,
            "Program": executable,
            "RunAtLoad": true,
            // The whole point. Terminated by the system: come back. Quit by
            // the user: stay gone.
            "KeepAlive": ["SuccessfulExit": false],
            // Ten seconds between attempts is launchd's floor anyway; saying
            // it out loud means a genuinely broken build cannot spin.
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    @discardableResult
    static func enable() -> Bool {
        guard let executable = Bundle.main.executableURL?.path else { return false }
        let url = plistURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist(executable: executable), format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("could not write the launch agent: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Replace any older definition before loading the new one, so an
        // upgrade that moved the bundle does not leave launchd watching a
        // path that is no longer there.
        _ = launchctl(["bootout", domain + "/" + label])
        let ok = launchctl(["bootstrap", domain, url.path])
        if !ok {
            log.error("launchctl refused the agent")
            try? FileManager.default.removeItem(at: url)
            return false
        }
        log.notice("launchd is watching Chalant now")
        return true
    }

    static func disable() {
        _ = launchctl(["bootout", domain + "/" + label])
        try? FileManager.default.removeItem(at: plistURL)
        log.notice("launchd is no longer watching Chalant")
    }

    private static var domain: String { "gui/\(getuid())" }

    /// `launchctl` rather than `SMAppService.agent`, and the reason is that
    /// this one can be watched working: the plist is a file a person can read,
    /// `launchctl print` says what launchd thinks, and killing the app proves
    /// the whole thing in one command. The supported API hides all three
    /// behind a status enum.
    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            log.error("launchctl failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
