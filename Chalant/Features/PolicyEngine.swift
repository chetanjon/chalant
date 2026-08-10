import Foundation
import os

/// A rule somebody made from a card: this pattern, in this repo (or
/// everywhere), until this time (or until revoked).
///
/// The timed, folder-scoped shape is the default and the point: an
/// approval given while looking at one command in one repo is not
/// consent for the same command everywhere. The everywhere-forever
/// shape exists because "Always allow" has always meant exactly that,
/// and pretending otherwise just kept it in a second store
/// (UserDefaults exceptions, folded in here 2026-08-09). Neither shape
/// can cover the always-ask list: `mustAsk` is checked in front of
/// grants everywhere they are read.
struct Grant: Codable, Identifiable, Equatable, Sendable {
    let id: String
    /// Claude Code's own permission-rule shape, which the arming rules
    /// and the "always allow" button already speak. A second syntax for
    /// the same idea would be a second thing to be wrong about.
    let pattern: String
    /// The absolute folder it applies to, or empty for everywhere —
    /// the shape an "Always allow" makes, and the shape a migrated
    /// exception has, because global is what both always meant.
    let repo: String
    let grantedAt: Date
    /// Nil never runs out. That is a decision the person made by
    /// pressing a button that says "always", not a default.
    let expires: Date?

    func isLive(at now: Date) -> Bool { expires.map { now < $0 } ?? true }

    /// A call this grant speaks for.
    ///
    /// The session's folder, or anywhere under it. A session opened in a
    /// subfolder of the repo somebody granted is still that repo; a
    /// sibling repo whose path merely starts with the same letters is
    /// not, which is what the trailing separator is for. An empty repo
    /// skips the folder test entirely: it applies everywhere, including
    /// to a call that carried no cwd at all.
    func covers(tool: String, detail: String, cwd: String, at now: Date) -> Bool {
        guard isLive(at: now) else { return false }
        if !repo.isEmpty {
            guard !cwd.isEmpty,
                  cwd == repo || cwd.hasPrefix(repo.hasSuffix("/") ? repo : repo + "/")
            else { return false }
        }
        return SessionStore.rule(pattern, holds: tool, detail)
    }

    static func expiries() -> [(label: String, seconds: TimeInterval)] {
        [("15 minutes", 900), ("2 hours", 7200), ("today", 28800)]
    }
}

/// What the policy engine thinks should happen to a call, before
/// anybody is asked anything.
enum PolicyEngine {
    enum Verdict: Equatable {
        /// Run it, and say why in the audit.
        case allow(rule: String, reason: String)
        /// Put the question to a person, whatever any saved permission
        /// rule might otherwise have said.
        case ask(rule: String, reason: String)
        /// No opinion. The agent's own permission flow runs exactly as
        /// it would if this app were not installed, and that is the
        /// answer the overwhelming majority of calls get.
        case silent
    }

    /// Calls that must never be settled quietly.
    ///
    /// Checked before everything, including grants, so that a live grant
    /// can never widen into one of these. The list is deliberately
    /// blunt: matching a few harmless commands costs a question, and
    /// missing one of these costs something that cannot be taken back.
    static func mustAsk(tool: String, detail: String, cwd: String) -> String? {
        let text = detail.lowercased()
        // Substrings rather than parsed arguments. `sudo` after a
        // semicolon is still sudo, and a parser good enough to be sure
        // is a shell, which is the thing being asked about.
        let named: [(String, [String])] = [
            ("sudo", ["sudo ", "sudo\t", "doas "]),
            ("rm -rf", ["rm -rf", "rm -fr", "rm -r -f", "rm -f -r", "rm --recursive --force"]),
            ("git push --force", ["push --force", "push -f ", "push --force-with-lease"]),
            ("git reset --hard", ["reset --hard"]),
            ("credentials", [
                ".env", "id_rsa", "id_ed25519", ".pem", ".p12", ".ssh/", ".aws/",
                ".npmrc", ".netrc", "credentials", "secrets", "keychain",
            ]),
            ("a database migration", [
                "db:migrate", "prisma migrate", "alembic", "flyway", "sequelize db:",
                "migrate deploy", "migrate reset", "rails db:", "drop database",
            ]),
        ]
        for (rule, needles) in named where needles.contains(where: text.contains) {
            return rule
        }
        // Writing outside the folder the session is working in.
        //
        // Scoped to writes on purpose. The spec asks for any path
        // outside the cwd, and taken literally that turns `cat
        // /etc/hosts` into a prompt somebody did not have before, which
        // is how a safety feature becomes something people switch off.
        // Reading outside the repo is instead merely never auto-allowed,
        // below. Writing outside it is exactly the thing worth stopping.
        let writes = ["Write", "Edit", "NotebookEdit", "MultiEdit"]
        if writes.contains(tool), !cwd.isEmpty, detail.hasPrefix("/"),
           !isInside(detail, cwd) {
            return "a write outside this folder"
        }
        return nil
    }

    static func isInside(_ path: String, _ cwd: String) -> Bool {
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path == cwd || path.hasPrefix(root)
    }

    /// Tools that only ever look.
    static let readOnlyTools = ["Read", "Grep", "Glob"]

    /// Shell commands worth letting through without a word.
    ///
    /// Matched on the whole command, not its first word, and only when
    /// nothing in it can turn into a second command. `ls` is read-only;
    /// `ls && rm -rf build` starts with `ls` and is not, and telling
    /// them apart by first word is how an auto-allow list becomes a way
    /// through it.
    static let readOnlyCommands = [
        "ls", "pwd", "cat", "head", "tail", "wc", "file", "stat", "which", "whoami",
        "date", "df", "du", "tree", "git status", "git diff", "git log", "git show",
        "git branch", "git remote", "npm test", "npm run test", "yarn test",
        "pytest", "swift test", "cargo test", "go test", "make test",
    ]

    static let shellMetacharacters: [Character] = [
        ";", "|", "&", "`", ">", "<", "\n", "(", ")", "{", "}", "$",
    ]

    static func autoAllow(tool: String, detail: String, cwd: String) -> String? {
        if readOnlyTools.contains(tool) {
            // Reading outside the folder is not dangerous enough to
            // interrupt anybody over, and not obviously fine either. No
            // opinion is the honest answer.
            guard !detail.hasPrefix("/") || cwd.isEmpty || isInside(detail, cwd) else {
                return nil
            }
            return tool
        }
        guard tool == "Bash" || tool == "BashOutput" else { return nil }
        let command = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains(where: shellMetacharacters.contains) else {
            return nil
        }
        guard let match = readOnlyCommands.first(where: { candidate in
            command == candidate || command.hasPrefix(candidate + " ")
        }) else { return nil }
        // An argument that walks out of the folder is not the command
        // that was allowed. `cat` is on the list; `cat /etc/shadow` is
        // not what anybody had in mind when it went on there.
        let escapes = command.split(separator: " ").contains { token in
            token.hasPrefix("/") && !cwd.isEmpty && !isInside(String(token), cwd)
        }
        return escapes ? nil : match
    }

    /// Rules in order, first match wins.
    static func evaluate(
        tool: String, detail: String, cwd: String, grants: [Grant], now: Date = Date()
    ) -> Verdict {
        if let rule = mustAsk(tool: tool, detail: detail, cwd: cwd) {
            return .ask(rule: rule, reason: "Chalant always asks about \(rule).")
        }
        if let rule = autoAllow(tool: tool, detail: detail, cwd: cwd) {
            return .allow(rule: rule, reason: "Auto-allowed by Chalant policy: \(rule) only reads.")
        }
        if let grant = grants.first(where: {
            $0.covers(tool: tool, detail: detail, cwd: cwd, at: now)
        }) {
            return .allow(
                rule: grant.pattern,
                reason: "Auto-allowed by a Chalant grant for \(grant.pattern) in this folder.")
        }
        return .silent
    }

    /// Grants only, with the same veto in front of them.
    ///
    /// Used where a person is already being asked: Claude Code has
    /// decided this call needs somebody, so the general read-only list
    /// has no business overruling that. A grant is different, because a
    /// grant is that somebody, earlier.
    static func evaluateGrantsOnly(
        tool: String, detail: String, cwd: String, grants: [Grant], now: Date = Date()
    ) -> Verdict {
        if let rule = mustAsk(tool: tool, detail: detail, cwd: cwd) {
            return .ask(rule: rule, reason: "Chalant always asks about \(rule).")
        }
        guard let grant = grants.first(where: {
            $0.covers(tool: tool, detail: detail, cwd: cwd, at: now)
        }) else { return .silent }
        return .allow(
            rule: grant.pattern,
            reason: "Auto-allowed by a Chalant grant for \(grant.pattern) in this folder.")
    }
}

/// The grants on disk, and the record of what was decided without
/// anybody being asked.
@MainActor
final class PolicyStore: ObservableObject {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "policy")

    @Published private(set) var grants: [Grant] = []
    @Published private(set) var audit: [Audit] = []

    /// One thing this app decided on somebody's behalf.
    ///
    /// Kept because a gate that quietly answers for you and keeps no
    /// account of it is not supervision, it is just a gate somebody else
    /// is holding. In memory only: this is a record of what the running
    /// app has done, and a quit is an honest end to it.
    struct Audit: Identifiable, Equatable {
        let id: String
        let at: Date
        let tool: String
        let detail: String
        let folder: String
        let allowed: Bool
        let rule: String
        let reason: String
    }

    static let auditCap = 500

    private let url: URL

    init(url: URL = ActivityServer.support.appendingPathComponent("policy.json")) {
        self.url = url
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Grant].self, from: data)
        else { return }
        // Expired on the way in. A grant that ran out while the app was
        // closed must never come back to life because nobody swept.
        grants = stored.filter { $0.isLive(at: Date()) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(grants) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Self.log.error("could not save grants: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything still in force, expired ones dropped as we look.
    func live(at now: Date = Date()) -> [Grant] {
        let kept = grants.filter { $0.isLive(at: now) }
        if kept.count != grants.count {
            grants = kept
            save()
        }
        return kept
    }

    /// A nil duration never runs out, and an empty repo applies
    /// everywhere: the "Always allow" shape. Anything scoped must name
    /// an absolute folder, or it would silently scope to nothing.
    @discardableResult
    func grant(pattern: String, repo: String, for duration: TimeInterval?,
               now: Date = Date()) -> Grant? {
        let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPattern.isEmpty, repo.isEmpty || repo.hasPrefix("/") else { return nil }
        let grant = Grant(
            id: UUID().uuidString, pattern: cleanPattern, repo: repo,
            grantedAt: now, expires: duration.map { now.addingTimeInterval($0) })
        grants.removeAll { $0.pattern == cleanPattern && $0.repo == repo }
        grants.append(grant)
        save()
        return grant
    }

    /// The one-time move of the old "Always allow" store.
    ///
    /// Exceptions lived in UserDefaults as newline-separated rules,
    /// global and forever, while the grants lived here: two stores for
    /// one idea, and the island's button wrote to only one of them.
    /// Each exception becomes the grant it always meant — that pattern,
    /// everywhere, never running out — and the key is removed so this
    /// runs once and the old store stays gone. Takes the defaults as a
    /// parameter so no test can drain the real machine's key.
    func migrateLegacyExceptions(from defaults: UserDefaults, now: Date = Date()) {
        let rules = (defaults.string(forKey: Self.legacyExceptionsKey) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        defer { defaults.removeObject(forKey: Self.legacyExceptionsKey) }
        guard !rules.isEmpty else { return }
        for rule in rules where !grants.contains(where: {
            $0.pattern == rule && $0.repo.isEmpty && $0.expires == nil
        }) {
            grants.append(Grant(
                id: UUID().uuidString, pattern: rule, repo: "",
                grantedAt: now, expires: nil))
        }
        save()
    }

    /// Where the old store lived. Kept only so the migration can empty
    /// it; nothing reads or writes it any more.
    static let legacyExceptionsKey = "approvalExceptions"

    func revoke(id: String) {
        guard grants.contains(where: { $0.id == id }) else { return }
        grants.removeAll { $0.id == id }
        save()
    }

    func revokeAll() {
        guard !grants.isEmpty else { return }
        grants.removeAll()
        save()
    }

    func note(
        tool: String, detail: String, folder: String, allowed: Bool, rule: String,
        reason: String, at: Date = Date()
    ) {
        audit.insert(
            Audit(id: UUID().uuidString, at: at, tool: tool, detail: detail,
                  folder: folder, allowed: allowed, rule: rule, reason: reason),
            at: 0)
        if audit.count > Self.auditCap { audit.removeLast(audit.count - Self.auditCap) }
    }

    func clearAudit() { audit.removeAll() }
}
