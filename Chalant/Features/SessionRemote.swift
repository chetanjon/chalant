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
    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    /// Where a session's keystrokes would have to go, if anywhere.
    static func target(for session: SessionStore.Session) -> Target? {
        let table = SessionLocator.processTable()
        let apps = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        // The registry's pid when it has one, else the process actually
        // working in this folder. Same resolution `reveal` already does.
        let agent = session.pid
            ?? SessionLocator.agentProcess(
                forCwd: session.cwd, in: table, agentNames: SessionLocator.agentNames)
        guard let agent,
              let tty = SessionLocator.tty(of: agent),
              let ownerPID = SessionLocator.owningApplication(
                of: agent, in: table, applications: apps),
              let owner = NSRunningApplication(processIdentifier: ownerPID),
              let bundleID = owner.bundleIdentifier
        else { return nil }
        return Target(
            tty: tty, bundleID: bundleID,
            appName: owner.localizedName ?? bundleID)
    }

    /// Whether this target is one this app can address exactly.
    static func canType(into target: Target) -> Bool { terminals.contains(target.bundleID) }

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
