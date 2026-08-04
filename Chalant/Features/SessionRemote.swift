import AppKit
import Foundation
import os

/// Putting what you typed into the running session, now.
///
/// The composer's original contract was an outbox: the words wait, and
/// the agent's Stop hook collects them at its next turn boundary. That
/// is honest and it is not control. The founder's own words for what
/// they wanted were "controlling the agents, like I control the chat on
/// my phone with remote control" (2026-08-03), and a note left for later
/// is not that.
///
/// So where the session is running in a real terminal, this types into
/// it, exactly as a person at that keyboard would. Claude Code is
/// holding the tty in raw mode and reading keystrokes, so text arriving
/// there goes into its input line and the newline submits it. If it is
/// mid-turn, Claude Code queues it itself, the same way it queues
/// anything typed while it is busy. Nothing about this is a private API
/// or a trick: it is the keyboard.
///
/// **Proven, not assumed** (2026-08-03, the same bar the approval hook
/// and the SIGINT question were held to). A Claude Code session was
/// started in a real Terminal tab and written to through the exact
/// script below: the text arrived in its input line, the newline
/// submitted it, and the agent answered. A second send arrived verbatim.
/// One false negative on the way is worth recording, because it will
/// happen to somebody else: the very first send into a *brand new*
/// directory is swallowed by Claude Code's own "do you trust this
/// folder" prompt, and a stray character from it can prefix the next
/// message. Sessions already running past that prompt, which is every
/// session this app can see, take text cleanly.
///
/// It is addressed by **tty**, never by "the frontmost window". That is
/// the whole safety story. A session's controlling terminal names one
/// tab in one window, Terminal and iTerm both publish that identifier on
/// their own tabs, and if no tab claims it nothing is typed at all. The
/// alternative, focusing an app and sending keystrokes into whatever has
/// focus, is how somebody's message ends up in the middle of their
/// source file.
@MainActor
enum SessionRemote {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// Off until somebody turns it on. The app typing on your behalf is
    /// not something to discover by accident, and the queue it replaces
    /// is a perfectly good default.
    static let straightToTerminalKey = "sendStraightToTerminal"

    static func sendsStraightToTerminal(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: straightToTerminalKey) as? Bool ?? false
    }

    /// A session that can actually be typed into: one terminal device,
    /// and one app known to be able to address it.
    struct Target: Equatable {
        var tty: String
        var bundleID: String
        var appName: String
    }

    enum Outcome: Equatable {
        /// It went in. The name is carried so the surface can say where
        /// rather than claiming a vague success.
        case typed(into: String)
        /// Nothing was typed, and this is why, in words meant for the
        /// person rather than for a log.
        case cannot(String)
    }

    /// Apps whose own scripting can address a single tab by its tty.
    ///
    /// Deliberately a short list rather than a general mechanism. An
    /// editor's built-in terminal (Cursor, VS Code) publishes no such
    /// identifier, so the only way in would be to focus the window and
    /// type blind, and a blind keystroke in an editor lands in whatever
    /// buffer is open. Those fall back to the queue, which is slower and
    /// cannot corrupt anything.
    ///
    /// Read by the row as well as by the sender, through `canAddress`
    /// below. Two copies of this list is exactly how a row ends up
    /// promising something the sender cannot deliver, which is the bug
    /// that let a message be typed into the island and quietly go
    /// nowhere.
    nonisolated static let addressableTerminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    /// Whether this app is one whose tabs can be named from outside.
    ///
    /// A negative answer about a *known* owner is real knowledge: VS Code
    /// owns the window, VS Code cannot be addressed, so nothing typed here
    /// would arrive. A missing owner is not knowledge at all, and callers
    /// must not treat it as one — see `SessionStore.Session.terminalApp`.
    nonisolated static func canAddress(bundleID: String) -> Bool {
        addressableTerminals.contains(bundleID)
    }

    /// Where a session's keystrokes would have to go, if anywhere.
    ///
    /// Two things here were wrong on the first attempt and both cost a
    /// real message (founder, 2026-08-03).
    ///
    /// It used to fall back to "the agent process working in this
    /// folder" when the registry had no pid. **A working directory is
    /// not an identity.** Three sessions in one repo share a cwd, so
    /// that fallback happily matched a completely different session,
    /// and a check meant to prove *this* session was alive proved that
    /// *some* session was. Only the registry's pid names one session.
    ///
    /// And it used to find the owning app by walking the process tree,
    /// which is how `reveal` picks a window to raise. For deciding
    /// whether a tab can be *written to* that is both too weak and too
    /// strong: a session launched detached has no app ancestor even
    /// though Terminal owns its tty, and a session under VS Code has an
    /// app ancestor that cannot address a tab at all. The question is
    /// simply "does Terminal or iTerm have a tab on this tty", so that
    /// is now the question asked, of them, directly.
    static func target(for session: SessionStore.Session) async -> Target? {
        guard let pid = session.pid, kill(pid, 0) == 0,
              let tty = SessionLocator.tty(of: pid)
        else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundleID, name) in [
            ("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm2"),
        ] where running.contains(bundleID) {
            guard await owns(tty: tty, bundleID: bundleID) else { continue }
            return Target(tty: tty, bundleID: bundleID, appName: name)
        }
        return nil
    }

    /// Ask an app whether one of its tabs is on this terminal device.
    private static func owns(tty: String, bundleID: String) async -> Bool {
        let script = bundleID == "com.apple.Terminal"
            ? """
              tell application "Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    try
                      if (tty of t) is "\(escaped(tty))" then return "yes"
                    end try
                  end repeat
                end repeat
              end tell
              return "no"
              """
            : """
              tell application "iTerm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      try
                        if (tty of s) is "\(escaped(tty))" then return "yes"
                      end try
                    end repeat
                  end repeat
                end repeat
              end tell
              return "no"
              """
        return await runScript(script) == "yes"
    }

    /// Whether this target is one this app can address exactly.
    static func canType(into target: Target) -> Bool { canAddress(bundleID: target.bundleID) }

    /// Is there actually a process behind this row, right now.
    ///
    /// The store's `state` is an inference: discovery reads an mtime,
    /// the registry reports on a sweep, and both can be a while behind.
    /// This asks the kernel. It exists because a message was queued for
    /// a session whose transcript had been cold for half an hour, and
    /// sat there forever with nothing left to collect it (founder,
    /// 2026-08-03: "I gave a text input in the island but I can't see it
    /// here"). A composer that accepts words it cannot deliver is worse
    /// than one that is greyed out, because it looks like it worked.
    /// The registry's pid and nothing else. `kill(pid, 0)` asks "does
    /// this process exist and may I signal it", and sends nothing.
    ///
    /// No cwd fallback. That fallback is what made this function lie:
    /// it answered "yes, running" for a session that had ended, because
    /// a *different* agent was working in the same folder. For "can this
    /// message be delivered", a confident wrong yes is the worst
    /// possible answer. Nil pid means nobody has vouched for this
    /// session, which is honestly not the same as knowing it is alive.
    static func isRunning(_ session: SessionStore.Session) -> Bool {
        // A pid is the only answer that is actually knowledge.
        if let pid = session.pid { return kill(pid, 0) == 0 }
        // Without one, fall back to what the store already inferred from
        // the transcript, and no further. There is a real window at the
        // start of a session where it is running and the registry has
        // not written its file yet (Claude Code registers after its own
        // trust prompt), and calling that "not running" would close the
        // composer on a session somebody just opened. What this must
        // never do is go looking for *some* process in the same folder:
        // that is what confused three sessions in one repo for each
        // other and swallowed a message.
        return session.state.isLive
    }

    // MARK: Starting one you can actually reach

    /// Which terminal new sessions are started in.
    ///
    /// The point of starting a session from here is that it lands
    /// somewhere addressable: an agent begun this way is remote
    /// controllable by construction, and nobody has to know that an
    /// editor's built-in terminal is a dead end before they choose where
    /// to work.
    static let startsInKey = "startSessionsIn"

    static func startsIn(_ defaults: UserDefaults = .standard) -> String {
        let choice = defaults.string(forKey: startsInKey) ?? "terminal"
        // Falls back rather than failing: somebody who chose iTerm and
        // has since removed it should still get a session.
        return choice == "iterm" && isInstalled("com.googlecode.iterm2") ? "iterm" : "terminal"
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Open a terminal in this folder and run the agent in it.
    ///
    /// `cd` and then `claude`, exactly what a person types, so there is
    /// nothing here that behaves differently from a session they started
    /// themselves. The path is single-quoted because folders have spaces
    /// and apostrophes in them and a broken `cd` would silently start
    /// the agent in the wrong place.
    static func newSession(in folder: URL) async -> Outcome {
        let quoted = "'" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "cd \(quoted) && claude"
        let iterm = startsIn() == "iterm"
        let script = iterm
            ? """
              tell application "iTerm2"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escaped(command))"
              end tell
              return "ok"
              """
            : """
              tell application "Terminal"
                activate
                do script "\(escaped(command))"
              end tell
              return "ok"
              """
        let name = iterm ? "iTerm2" : "Terminal"
        guard await runScript(script) == "ok" else {
            return .cannot("\(name) would not open a new session.")
        }
        return .typed(into: name)
    }

    /// One line, always.
    ///
    /// A newline inside the text would submit early and send the rest as
    /// a second message, which is the difference between one instruction
    /// and two half ones. Collapsed rather than rejected: somebody
    /// pasting two lines into the composer means one thing by it.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Type it, or say why not. Never both, and never silently neither.
    static func type(_ text: String, into target: Target) async -> Outcome {
        let line = oneLine(text)
        guard !line.isEmpty else { return .cannot("There was nothing to send.") }
        guard canType(into: target) else {
            return .cannot(
                "\(target.appName) has no way to name one of its terminals from outside, so "
                + "Chalant will not type into it blind. Queued instead.")
        }
        let script = target.bundleID == "com.apple.Terminal"
            ? terminalScript(line, tty: target.tty)
            : itermScript(line, tty: target.tty)
        let result = await runScript(script)
        switch result {
        case .some("ok"):
            return .typed(into: target.appName)
        case .some("notfound"):
            // The window went away between finding the tty and writing
            // to it, or the session is running inside a multiplexer this
            // app cannot see through.
            return .cannot(
                "That session's window isn't open in \(target.appName) any more. Queued instead.")
        case .some(let error):
            log.error("remote type failed: \(error, privacy: .public)")
            return .cannot("\(target.appName) refused: \(error). Queued instead.")
        case .none:
            return .cannot("\(target.appName) did not answer. Queued instead.")
        }
    }

    /// `do script ... in <tab>` writes to that tab's shell exactly as
    /// typing does, which is why the target is a tab and not a window:
    /// one window can hold many sessions and only one of them is this
    /// agent.
    private static func terminalScript(_ line: String, tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(escaped(tty))" then
                  do script "\(escaped(line))" in t
                  return "ok"
                end if
              end try
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func itermScript(_ line: String, tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s) is "\(escaped(tty))" then
                    tell s to write text "\(escaped(line))"
                    return "ok"
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    /// Its own serial queue, off the main actor, for the same reason
    /// `MessageCourier` has one: the first call can raise the
    /// automation consent dialog and block until somebody answers it,
    /// and an island frozen behind a system dialog reads as a crash.
    private static let scriptQueue = DispatchQueue(label: "chalant.sessions.remote")

    private static func runScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                let value = NSAppleScript(source: source)?
                    .executeAndReturnError(&error)
                if let error {
                    let message =
                        "\(error[NSAppleScript.errorNumber] ?? "") "
                        + "\(error[NSAppleScript.errorMessage] ?? "")"
                    continuation.resume(returning: message.trimmingCharacters(in: .whitespaces))
                    return
                }
                continuation.resume(returning: value?.stringValue)
            }
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
