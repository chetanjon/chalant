# Chalant — state of the repo audit

Audited 2026-08-09 at commit `f20b05e` (v1.8.2, build 140). Read-only: no code was changed.

---

## Repo map

**Targets** (xcodegen, `project.yml`)
- `Chalant` — macOS 14+ app, SwiftUI, LSUIElement (menu-bar/notch app). Sparkle 2.9.4 for self-updates. Hardened runtime, Apple Development signing (team WV59PZX4A3). Version/build live in `project.yml:53-54` (1.8.2 / 140), not Info.plist.
- `ChalantTests` — unit test bundle. 14 files, 556 `func test` cases.

**Folders**
- `Chalant/` — app root. `ChalantApp.swift` is the entry point (`@main`, `AppDelegate`); `NotchViewModel.swift` (1787 lines) is the app-wide model; `NotchWindowController.swift` owns the per-display panels.
- `Chalant/Features/` (45 files) — all non-view logic. Relevant here: `ActivityServer.swift` (HTTP server), `HookGate.swift` (decision stores + wire codecs), `HookInstall.swift` (settings.json writer), `PolicyEngine.swift` (policy + grants), `SessionStore.swift` (2105 lines, session/approval/ask model), `SessionDiscovery.swift` (transcript reader, native AskUserQuestion detection), `SessionRegistry.swift` (~/.claude/sessions pid registry), `CursorDiscovery.swift` (Cursor chat scanner), `JobsReader.swift` (background-agent roster), `SessionActivity.swift` (status-line ladder), `TranscriptTurns.swift`.
- `Chalant/Views/` (25 files) — UI. Relevant: `ExpandedView.swift`, `NotchRootView.swift`, `SessionRoom.swift`, `SessionCards.swift`, `AgentSessions.swift`, `Dashboard*.swift`, `IslandFace.swift` (in Features but view-facing).
- `scripts/` — `chalant-hook` (Claude Code command hook, bash), `chalant-gate` (Cursor/Codex shim, bash+python), `chalant-ask-mcp` (MCP server, python), `chalant` (CLI), `chalant-hook-selftest`, `dev`, `devlog`, `make-icon.py`. The first three are bundled into the app as resources (`project.yml:28-41`).
- `ChalantTests/` — unit tests. `docs/` — Pages site, appcast, RELEASING.md, PLAN.md, two design specs. `_bmad-output/loop-loop/` — 12 historical evidence/plan markdown files (working notes, not code). `Vendor/MediaRemoteAdapter/` — media framework, unrelated to agents.

**Entry points**
- App: `Chalant/ChalantApp.swift:4` → `AppDelegate.applicationDidFinishLaunching` → `NotchWindowController` → `NotchViewModel`.
- Server start: `NotchViewModel.swift:729` — `activityServer.start(store:sessions:policy:)`.
- Agent → app: HTTP on `127.0.0.1:4242` (below). App → agent config: `HookInstall` writes `~/.claude/settings.json`, `~/.cursor/hooks.json`, `~/.codex/hooks.json`.

---

## 1. HTTP server

**File**: `Chalant/Features/ActivityServer.swift` (1294 lines). No framework — raw `Network.framework` (`NWListener`/`NWConnection`) with a hand-written HTTP/1.1 parser (`parse(_:)` at `ActivityServer.swift:384`) and responder (`respond(_:status:body:)` at `ActivityServer.swift:1282`, always `Connection: close`).

**Binding / port**
- Default port 4242, overridable via `defaults write com.cj.chalant activityPort -int <port>` (`ActivityServer.swift:33-36`).
- If taken, walks 4243…4252 (`portCandidates`, `ActivityServer.swift:118-123`).
- Bound to `127.0.0.1` explicitly via `requiredLocalEndpoint` (`ActivityServer.swift:206`), not wildcard + loopback interface. Comment at 198-205 notes the shipped 1.7.1 listened on `*:4242`.
- Resolved port + token published to `~/Library/Application Support/Chalant/server.json` (0600) on every `.ready` (`publish(port:)`, `ActivityServer.swift:254-275`). Publishing also refreshes the settings.json hook entries if already armed (`ActivityServer.swift:273-274`).

**Auth**
- Token minted once to `~/Library/Application Support/Chalant/api-token`, 0600 (`loadOrCreateToken`, `ActivityServer.swift:67-83`).
- Accepted headers: `X-Chalant-Token: <token>` or `Authorization: Bearer <token>` (`ActivityServer.swift:38-45`, `offeredToken` at 440-451). Constant-time compare (`tokenMatches`, 87-93). Every route including `/health` requires it (401 otherwise, `ActivityServer.swift:477-481`).
- Browser requests (any `Origin:`/`Sec-Fetch-Mode:` header) get 403 on all non-GET plus the three consuming GETs `/outbox/<id>`, `/ask/<id>`, `/permission/<id>` (`ActivityServer.swift:466-473`).

**Limits / timeouts**
- 5-second deadline for a request to *arrive* complete; explicitly not a deadline on being answered — a held hook request stays open for minutes (`ActivityServer.swift:297-316`).
- Body cap 512 KB (`maxBody`, 347); negative/oversized Content-Length rejected in `parse` (399-413). String caps: title 200, detail 400, id 128 (351-353).

**Routes** (all under `route(_:on:)`, `ActivityServer.swift:453-1060`)

| Method/path | Line | Request JSON | Response JSON |
|---|---|---|---|
| `POST /activity` | 483 | `{"id","title","detail","state"}`; state ∈ `working\|needs-input\|done\|failed\|clear` | `{"ok":true}` / 400 |
| `GET /activities` | 1034 | — | `[{"id","title","state","updatedAt","detail"?}]` |
| `DELETE /activity/<id>` | 1051 | — | `{"ok":true}` |
| `POST /ask` | 516 | `{"session","question","id"?,"header"?,"options"?,"multiSelect"?}` | `{"ok":true}` / 404 `no such session` |
| `GET /ask/<session>` | 701 | — | `{"ok":true,"answered":false}` until answered; then `{"ok":true,"answered":true,"answer":[...]}` and the ask is cleared (single-question asks only, 717) |
| `POST /outbox` | 550 | `{"session","message"}` | `{"ok":true}` / 404 |
| `GET /outbox/<session>` | 734 | — | `{"ok":true,"message":<text or null>}`; read-clear-respond, never 404 |
| `POST /prompt` | 584 | `{"session","tool"?,"detail"?}` | `{"ok":true}` — records a terminal prompt (report-only) |
| `DELETE /prompt/<session>` | 600 | — | `{"ok":true}` |
| `POST /permission` | 616 | `{"session","id","tool","detail"?,"cwd"?}` | `{"ok":true,"gate":true}` if held (approval rules matched), else `{"ok":true,"gate":false}` |
| `GET /permission/<id>` | 643 | — | `{"ok":true,"decision":null}` until decided; then `{"ok":true,"decision":"allow"\|"deny"}` (cleared on read) |
| `PUT /permission/<id>` | 676 | `{"decision":"allow"\|"deny"}` | `{"ok":true}` |
| `DELETE /permission/<id>` | 694 | — | `{"ok":true}` (hook gave up; card withdrawn) |
| `GET /permissions` | 661 | — | `{"ok":true,"held":[{"id","session","tool","detail"}]}` |
| `POST /hook/permission-request` | 765 | Claude Code PermissionRequest payload | held (below); empty 200 = no opinion |
| `POST /hook/elicitation` | 878 | Claude Code Elicitation payload | held; `{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"accept","content":{...}}}` etc. |
| `POST /hook/stop`, `POST /hook/session-end` | 784 | reads only `session_id` | empty 200 immediately; then releases held cards for that session |
| `POST /hook/gate` | 806 | normalized PreToolUse-shaped payload (from `chalant-gate`) | PolicyEngine verdict or held; PreToolUse-shaped answer |
| `POST /hook/pre-tool-use` | 888 | PreToolUse payload | PolicyEngine verdict only, never holds |
| `GET /debug/pending` | 908 | — | `{"ok":true,"held":[...]}` (the HTTP-held gate, incl. `event`, `permissionMode`, `askedAt`) |
| `GET /debug/audit` | 928 | — | `{"ok":true,"decided":[...]}` last 100 policy decisions |
| `GET /debug/asks` | 947 | — | `{"ok":true,"asking":[...]}` |
| `POST /debug/answer` | 969 | `{"ask","index"?,"choices"?,"decline"?}` | `{"ok":true}` etc. |
| `POST /debug/resolve` | 1000 | `{"id","decision":"allow"\|"deny"\|"abstain"}` | `{"ok":true,"resolved":bool}` |
| `GET /health` | 1026 | — | `{"ok":true,"app":"Chalant","version":"1.8.2"}` (token required) |

**How a request is held open** (`hold(_:on:event:)`, `ActivityServer.swift:1105-1182`)
- The connection callback returns immediately; a Swift `Task` awaits `gate.hold(call)` (a `CheckedContinuation` inside the `PendingDecisionStore` actor). No thread is blocked. The HTTP response is written onto the same still-open `NWConnection` whenever the continuation resumes — minutes later if needed.
- Order of operations: check grants only (`PolicyEngine.evaluateGrantsOnly`, 1126-1141) → abandon a stale prior approval in the same session (1147-1156) → surface the card (`sessions.holdForPrompt`, 1161-1166) → *then* suspend (`gate.hold`, 1174). If the card cannot be surfaced, answer empty 200 immediately (1170-1172).
- Hang-up detection: `watchForHangup` (`ActivityServer.swift:1260-1280`) does a 1-byte read on the held connection; EOF/error → `gate.abandon(id)` + card withdrawn.
- `/hook/stop` / `/hook/session-end` (784-789) release held approvals and elicitations for the ended session via `releaseHolds(inSession:)` (1191-1203) — this is how a prompt answered on the phone/terminal takes the card down.

**Timeout behavior**
- The server itself never times out a held call. The timeouts are the hook's: `timeout` field from the payload (default 600, `ActivityServer.swift:1115`) is only used to display the countdown; the actual end comes from Claude Code killing the hook (connection drops → hangup path) or `/hook/stop`.
- The polling path (`chalant-hook`) times itself out after `CHALANT_APPROVAL_WAIT` (default 25 s, `scripts/chalant-hook:234`) then `DELETE /permission/<id>` and exits 0.

---

## 2. Hook installation

**File**: `Chalant/Features/HookInstall.swift` (952 lines). Writer safety (all writes): refuse unparseable JSON, merge never replace, dated backup copy first (`backUpSettings`, `HookInstall.swift:789-800` → `settings.chalant-backup-<stamp>.json`), atomic write, write through symlinks (`commit`, 735-751).

**What is auto-written to `~/.claude/settings.json`**

a) `armPrompts()` (`HookInstall.swift:372-429`) — the "answer prompts on the island" switch; also silently refreshed on every server bind if already armed (`ActivityServer.swift:273-274`). Writes four **http-type** entries, one per event, each shaped by `entry(path:port:token:timeout:)` (`HookInstall.swift:302-320`):

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*",
        "hooks": [ { "type": "http",
                     "url": "http://127.0.0.1:4242/hook/permission-request",
                     "timeout": 600,
                     "headers": { "Authorization": "Bearer <literal token>" } } ] }
    ],
    "Elicitation": [
      { "matcher": "*",
        "hooks": [ { "type": "http", "url": "http://127.0.0.1:4242/hook/elicitation",
                     "timeout": 600, "headers": { "Authorization": "Bearer <token>" } } ] }
    ],
    "Stop": [
      { "matcher": "*",
        "hooks": [ { "type": "http", "url": "http://127.0.0.1:4242/hook/stop",
                     "timeout": 10, "headers": { "Authorization": "Bearer <token>" } } ] }
    ],
    "SessionEnd": [
      { "matcher": "*",
        "hooks": [ { "type": "http", "url": "http://127.0.0.1:4242/hook/session-end",
                     "timeout": 10, "headers": { "Authorization": "Bearer <token>" } } ] }
    ]
  }
}
```
- Token is written literally, never `$VAR` (rationale at `HookInstall.swift:313-317`). Port is whatever the listener actually opened. Own entries identified by URL path containing `/hook/permission-request` etc. (`isOurs`, 322-326). `disarmPrompts` (434-463) removes exactly these four.

b) `arm()` (`HookInstall.swift:214-259`) — the PreToolUse gate (approval rules). Writes one **command-type** entry, **no matcher**:

```json
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command",
                     "command": "<app bundle>/Contents/Resources/chalant-hook",
                     "timeout": 40 } ] }
    ]
  }
}
```
- Detection: `holdsToolCalls` (124-134), any PreToolUse command containing `chalant-hook`. `disarm()` at 760-785.

c) `armRemoteControl()` / `disarmRemoteControl()` (`HookInstall.swift:699-712`) — writes/removes the top-level key `"remoteControlAtStartup": true` (not a hook).

**What is offered as paste-in snippets, never written** (`snippet(for:)`, `HookInstall.swift:893-951`)
- Claude Code: `Notification` + `Stop`, command-type, `chalant-hook`, no matcher, no timeout (897-908). This is the reporting half (pills, prompt subjects, outbox delivery). `status()` counts the app "installed" only when a `Stop` command entry contains `chalant-hook` (`HookInstall.swift:102-113`).
- Codex (`~/.codex/hooks.json`): `Stop` only, command `CHALANT_AGENT=codex <path>` (917-925), Claude-shaped file.
- Cursor (`~/.cursor/hooks.json`): flat shape, `{"version":1,"hooks":{"stop":[{"command":"CHALANT_AGENT=cursor <path> Stop"}],"beforeShellExecution":[...],"beforeMCPExecution":[...]}}` (934-949).
- MCP ask server: `claude mcp add chalant -- <bundle>/chalant-ask-mcp` is displayed, never written — registering means editing `~/.claude.json` (872-878).

**What is auto-written for the other two agents** (behind buttons)
- `armCursor()` (`HookInstall.swift:519-552`): adds to `beforeShellExecution` and `beforeMCPExecution` a flat entry `{"type":"command","command":"<bundle>/chalant-gate cursor gate","timeout":600}` (`cursorGateEntry`, 480-487; events list 488).
- `armCodex()` (610-636): nested Claude shape under `PreToolUse`: `{"hooks":[{"type":"command","command":"<bundle>/chalant-gate codex gate","timeout":600}]}` (`codexGateEntry`, 584-587). Marked UNVERIFIED in-code (578-583): no codex binary existed on the build machine.

**Events registered, summary**
- Command hooks: `PreToolUse` (auto, gate), `Notification` + `Stop` (manual snippet, reporting).
- HTTP hooks: `PermissionRequest`, `Elicitation`, `Stop`, `SessionEnd` (auto).
- Not registered anywhere: `UserPromptSubmit`, `SessionStart`, `PostToolUse`, `SubagentStop`, `PreCompact`. (`SessionStart` appears only as third-party fixture data in `ChalantTests/ArmingTests.swift:53`.)
- Matchers: `"*"` on the four http entries; every command entry has none.

---

## 3. PendingDecisionStore

**File**: `Chalant/Features/HookGate.swift:55-114`. An `actor`; twin `PendingAnswerStore` for elicitations at 160-190.

**Data model**
- `waiting: [String: Waiting]` where `Waiting = { call: HeldCall, continuation: CheckedContinuation<GateDecision, Never> }` (`HookGate.swift:56-61`).
- `HeldCall` (`HookGate.swift:12-35`): `id` (sanitized `tool_use_id`, the only id meaningful on both sides), `sessionID`, `tool`, `detail` (verbatim command/path, first non-empty of `["command","file_path","path","url","pattern","query"]`, `detailKeys` at 206), `cwd` (absolute only), `permissionMode`, `transcriptPath`, `event` (`PermissionRequest` vs `PreToolUse`), `agent` (claude/cursor/codex, added by the shim only), `askedAt`.
- `GateDecision` (38-46): `allow`, `deny`, `abstain` ("say nothing; the agent's own flow runs").

**Resolution**
- `hold(_:)` (69-82): registers and suspends via `withCheckedContinuation`. A duplicate id resumes immediately with `.abstain` rather than displacing the first waiter.
- `resolve(_:as:)` (91-96): remove-then-resume; removal is the idempotency, so a second tap or a tap-vs-hangup race finds nothing. Returns whether this call actually answered.
- `abandon(_:)` (101-104) = `resolve(id, as: .abstain)`. Callers: connection hangup (`ActivityServer.swift:1273`), `/hook/stop`/`session-end` (1197), stale-prompt replacement (1154).
- UI → store bridge: island buttons call `SessionStore.decide` → `onDecided` closure → `gate.resolve` (`ActivityServer.swift:152-155`, `SessionStore.swift:1677-1685`).

**On timeout**
- The store has no timer. Whichever comes first ends a hold: a decision, session end, or the agent's side dropping the connection (hook timeout). All non-decisions land as `.abstain`.

**Exact response to Claude Code** (`HookPayload.response(for:event:)`, `HookGate.swift:268-303`)
- Allow on `PermissionRequest`: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
- Deny on `PermissionRequest`: same with `"behavior":"deny"`.
- Allow/deny on `PreToolUse` (the `/hook/gate` path, `ActivityServer.swift:854-861`): `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny","permissionDecisionReason":"Allowed|Denied from the Chalant island."}}`
- No decision (`.abstain`): empty 200 body — explicitly "no opinion", the agent's own prompt proceeds (`HookGate.swift:270-273`).
- The comment block at `HookGate.swift:258-267` records that the two events do **not** share a schema (`decision.behavior` vs `permissionDecision`) and that the wrong one is accepted silently and does nothing.
- Polling path equivalent (the command hook): `chalant-hook` itself prints the PreToolUse JSON on stdout after `GET /permission/<id>` returns a decision (`scripts/chalant-hook:242-249`); on its 25 s timeout it deletes the hold and exits 0 with no output.

---

## 4. PolicyEngine

**File**: `Chalant/Features/PolicyEngine.swift` (307 lines). Two rule systems exist; this is one of them (see §8).

**Rule formats**
- Hardcoded must-ask list (`mustAsk`, `PolicyEngine.swift:66-102`): substring matches on the lowercased detail — sudo/doas, rm -rf variants, `push --force`/`-f `/`--force-with-lease`, `reset --hard`, credential paths (`.env`, `id_rsa`, `.pem`, `.aws/`, `keychain`, …), DB migrations (`prisma migrate`, `alembic`, `drop database`, …); plus any `Write/Edit/NotebookEdit/MultiEdit` to an absolute path outside `cwd` (96-99). Deliberately substring-blunt (comment at 68-71).
- Hardcoded auto-allow (`autoAllow`, 130-155): read-only tools `Read/Grep/Glob` (unless reading an absolute path outside cwd → no opinion); whole-command match against `readOnlyCommands` (119-124: `ls`, `git status`, `pytest`, `swift test`, …) only when the command contains no shell metacharacter (126-128) and no absolute-path argument escaping cwd (151-154).
- `Grant` (12-43): `{id, pattern, repo, grantedAt, expires}`. Pattern is Claude Code's own rule shape (`Bash(git *)`), matched via `SessionStore.rule(_:holds:_:)` (`SessionStore.swift:1441-1450`) + iterative glob (`SessionStore.swift:1457-1479`). Scope: exact repo or subfolder (`covers`, 32-38). Expiries offered: 15 min / 2 h / 8 h (`expiries()`, 40-42). Persisted to `~/Library/Application Support/Chalant/policy.json` 0600 by `PolicyStore` (201-307), expired grants dropped on load and on read.

**Evaluation order** (`evaluate`, `PolicyEngine.swift:158-175`) — first match wins:
1. `mustAsk` → `.ask` (grants can never widen into these; checked before grants on purpose)
2. `autoAllow` → `.allow`
3. live grant covering tool/detail/cwd → `.allow`
4. else `.silent` (no opinion; empty 200)

`evaluateGrantsOnly` (183-195) = mustAsk veto + grants, no auto-allow list — used on `PermissionRequest` because "Claude Code has decided this call needs somebody" (`ActivityServer.swift:1120-1141`).

**Where auto allow/deny short-circuits the UI**
- `/hook/gate` (Cursor/Codex + any HTTP PreToolUse): `.silent` → empty 200; `.allow` → answered instantly with the allow body; `.ask` → card surfaced and held (`ActivityServer.swift:815-869`). The engine never emits deny — `.ask` is deliberate (`settle`, `ActivityServer.swift:1087-1095`: "a deny here would take the choice away just as completely as an allow").
- `/hook/permission-request`: a covering grant answers allow without a card (`ActivityServer.swift:1126-1141`).
- Every non-silent verdict is recorded in the in-memory audit (`PolicyStore.note`, `PolicyEngine.swift:296-304`, cap 500, cleared on quit), readable at `GET /debug/audit`.

**The second rule system** (not PolicyEngine): the polling gate at `POST /permission` uses `SessionStore.approvalRules()` / `approvalExceptions()` — newline-separated Claude-shaped rules in **UserDefaults** (`SessionStore.swift:1420-1427`, 1496-1512), evaluated in `holdForApproval` (1564-1577): exceptions first, then rules, no PolicyEngine involvement. The "Always allow X" button writes an exception to UserDefaults (`SessionCards.swift:1051-1054`); the "Allow X for…" menu writes a Grant to policy.json (`AgentSessions.swift:88-90`).

---

## 5. UI

**Island states** (`NotchViewModel.swift:29-33`): `collapsed`, `listening` (voice), `expanded`. Per-display rendering via `IslandFace` (`Features/IslandFace.swift`); only one display expands at a time (`expandedDisplayID`, `NotchViewModel.swift:109`).

**Expanded form** (`Views/ExpandedView.swift`)
- Glance: layout-driven rows (`glanceContent`, `ExpandedView.swift:84-112`) — media, ambience, activities pills (`ActivitiesStrip`, `ExpandedView.swift:527`), sessions strip, tab switcher.
- Focused: one tab takes the whole panel (`focusedContent`, 121+). Tabs (`NotchViewModel.Tab`, `NotchViewModel.swift:37-73`): today, ask, clipboard, shelf, links, notes, focus, chat, sessions, battery. Only `.sessions` supports full-height focus (`canFocus`, line 55).
- Sessions focused = `SessionRoom` (`Views/SessionRoom.swift:15`): 280 pt rail (`railWidth`, line 25) + detail pane; arrow-key navigation; Return/Escape deliberately unhandled (NSPanel steals them, comment at 90-104).

**Rendered cards** (`Views/SessionCards.swift`)
- `ApprovalCard` (926-1079) — held tool call: tool name, verbatim detail (4-line cap), Allow / Deny, "Always allow <x>" (UserDefaults exception) or "Allow <x> for…" grant menu when a repo is known (1028-1059), live countdown on its own line (`TimelineView`, 1068-1073), "Also on screen in its own terminal" note when `alsoInTerminal` (1000-1006).
- `AskCard` (511-789) — three flavors from one struct: elicitation (buttons genuinely answer + "Not answering" decline, 611-621), native AskUserQuestion (banner "Chalant can't answer it there directly: tapping a choice queues it as a message", 591-598; answers go through the outbox), scripted `chalant ask` (answers via `/ask` polling). Bundles render one question at a time with "Question n of m" (576-580); multi-select and free-text "Something else" supported (622-707).
- `TerminalPromptCard` (811-924) — report-only prompt from the `Notification` hook: shows tool/detail, explains why this one can't be answered, offers the one-tap `armPrompts()` upsell when the gate is off (`offerToHold`, 837-873), "Open terminal" / "Open on your phone" buttons.
- `ComposeCard` (22+) — outbox composer.
- `DropStashCard`, `MicButton`, `TodayView` etc. — unrelated to agents.

**Card placement**
- Glance strip (`Views/AgentSessions.swift:72-116`): ApprovalCard above AskCard above ComposeCard, under the session row. Live sessions only (working / needsInput / idle, line 42-46).
- Room detail (`Views/SessionRoom.swift:438-481`): ApprovalCard (438), TerminalPromptCard (448), AskCard (453) above the transcript, ComposeCard (481) below — the 1.8.1 visibility fix.
- Rail/`FinishedDetail` (SessionRoom.swift:560-584): finished sessions show `Finished.lastMessage` (final transcript line, sourced from `SessionDiscovery.swift:522`, not from any Stop payload).

**Event types → rendered view**

| Event | View |
|---|---|
| PermissionRequest (http) | ApprovalCard (with countdown, `alsoInTerminal`) |
| PreToolUse held (command hook polling, or `/hook/gate`) | ApprovalCard |
| Elicitation (http) | AskCard (elicitation mode, answerable) |
| Native AskUserQuestion (transcript-read, `SessionDiscovery.swift:45-103, 510-580`) | AskCard (native mode, queue-only) |
| Scripted `chalant ask` | AskCard |
| Notification `permission_prompt` (command hook → `/prompt`) | TerminalPromptCard + needs-input pill |
| Notification (any other type) | Generic pill only ("<folder> wants you", `scripts/chalant-hook:265`) |
| Stop (command hook) | "finished" pill + prompt cleared + outbox delivery; session lands in Finished band |
| Stop / SessionEnd (http) | No view — releases held cards |
| `POST /activity` pills | `ActivitiesStrip` (`ExpandedView.swift:527`), states working / needs-input / done / failed |

**No rendered view exists for**: notification subtypes other than `permission_prompt`; Stop's `last_assistant_message` (never read); SubagentStop / PostToolUse / UserPromptSubmit / SessionStart (never registered); `/debug/*` surfaces (terminal-only by design).

---

## 6. Codex/Cursor shim

**Files**: `scripts/chalant-gate` (188 lines, installed by `HookInstall.armCursor`/`armCodex`); reporting also flows through `scripts/chalant-hook` with `CHALANT_AGENT=cursor|codex` (snippets only).

**How it works** (`scripts/chalant-gate`)
- Invoked as `chalant-gate <agent> <endpoint>` with the hook's JSON on stdin. Installed entries use endpoint `gate` → `POST /hook/gate` (`HookInstall.swift:541`, script line 133).
- Reads port+token from `server.json` (never hardcoded 4242, lines 34-39). One python3 process does config read, payload normalization, HTTP call, and answer translation (49-186).
- Normalization (71-105): session from `session_id|conversation_id|chat_id…`; cwd from `cwd|workspaceRoot|workspace_roots[0]`; a bare `command` with no tool name becomes `Bash`; Cursor's MCP arguments arrive as a JSON string and are re-parsed.
- Call id (110-118): neither agent promises a per-call id, and Cursor's `generation_id` repeats within a turn, so the id is `sha256(call_id|tool|tool_input)[:24]` — two identical commands in one generation dedupe intentionally.
- Blocks inside `urllib.urlopen` up to `CHALANT_GATE_WAIT` (default 600 s) while Chalant holds the call (132-143).
- Answer translation (155-185) — the stated reason the file exists: Chalant answers in Claude's `hookSpecificOutput` shape; Cursor reads only `{"permission":"allow"|"deny"|"ask"}` (printed with both camel and snake userMessage/agentMessage variants, 167-173). Passing Chalant's answer through untranslated would make every island Deny read as "no opinion" = allow on Cursor. Codex gets the Claude PreToolUse shape back (179-183).
- Failure is always silence: any error → exit 0, no stdout, agent's own flow runs (header 21-26).

**What it covers**
- Cursor: `beforeShellExecution` and `beforeMCPExecution` — shell and MCP calls, decided through PolicyEngine + island card, verdicts allow/deny/ask.
- Cursor session *visibility* separately via `CursorDiscovery.swift` (polls `~/.cursor/chats/*/*/meta.json` every 20 s, working/stale by 5-minute freshness, no pid, no branch, ids prefixed `cursor:`).
- Codex: `PreToolUse` in a Claude-shaped `~/.codex/hooks.json`.

**What it can't**
- Codex end-to-end is unverified: config shape from docs, decision shape a "reasoned guess", fails silent (`HookInstall.swift:578-583`, `chalant-gate:174-183`).
- No file-edit events for Cursor — only shell and MCP; a Cursor Edit never reaches the gate.
- No stable per-call id, no `permission_mode`, no transcript path; the digest id means the card can't be correlated to a specific repeated call.
- No outbox/message injection for either (explicitly Claude-only, `scripts/chalant-hook:349-359`); no elicitation, no native-question reading; Cursor sessions have no liveness beyond mtime and Codex has no session store at all (`HookInstall.swift:29-31`).
- `chalant-hook`'s fallback for a Cursor/Codex payload with no recognizable session id collapses all of that agent's sessions onto one `default` row (`scripts/chalant-hook:141-152`).

---

## 7. Gap analysis

**a) AskUserQuestion question cards (PreToolUse matcher, render options, answer via deny + reason) — PARTIAL**
- Exists: cards for native AskUserQuestion, read from the transcript (`SessionDiscovery.swift:45-103`, parser at 563-580; bundles supported), rendered by `AskCard`, "answered" only by queueing a message through the outbox for the next turn (`SessionCards.swift:591-598`, 522-527).
- Missing: the interception approach — no `PreToolUse` matcher for `AskUserQuestion`; the command hook fires unmatched on every tool and `HookPayload.detailKeys` (`HookGate.swift:206`) extracts none of AskUserQuestion's `questions` input, so a held AskUserQuestion would render an empty-detail ApprovalCard, not options; no answer-via-`deny`+`permissionDecisionReason` path anywhere.
- Would change: `HookGate.swift` (parse `tool_input.questions` into `HeldCall`/a new shape; a deny-with-reason response builder), `ActivityServer.swift` (`/hook/gate` + hold paths), `SessionStore.swift` (hold an ask-shaped approval), `SessionCards.swift` (card that renders options and answers via deny), `HookInstall.swift` (if a matcher-carrying PreToolUse entry is wanted), `scripts/chalant-hook` (if the polling path should carry it too).

**b) Stop summary card using `last_assistant_message` — MISSING**
- `last_assistant_message` appears nowhere in the repo (verified by grep). `/hook/stop` reads only `session_id` (`ActivityServer.swift:785-786`); the command Stop hook reads only `session_id` / `stop_hook_active` (`scripts/chalant-hook:91-130`).
- Nearest existing thing: `Finished.lastMessage` (`SessionStore.swift:354-356`) sourced from a transcript scan (`SessionDiscovery.swift:522`), shown in the rail and `FinishedDetail` (`SessionRoom.swift:584`) — transcript-derived, and only when the registry marks the session gone, not at every turn end.
- Would change: `ActivityServer.swift` (`/hook/stop` parse the field), `SessionStore.swift` (store a turn-end summary on the live row), a card in `SessionCards.swift` or a row treatment in `SessionRoom.swift`/`AgentSessions.swift`.

**c) Notification-driven attention pings (`agent_needs_input`, `agent_completed`) — PARTIAL**
- Exists: the `Notification` hook posts a `needs-input` pill for *every* notification (`scripts/chalant-hook:265`), and reads `notification_type` for exactly one value, `permission_prompt`, to fetch the prompt subject (`scripts/chalant-hook:292-296`).
- Missing: any distinction by type — `agent_needs_input` / `agent_completed` / idle-style types are not recognized; strings named in the target list appear nowhere in the repo. Everything renders as the same "wants you" pill.
- Would change: `scripts/chalant-hook` (branch on `notification_type`), `Chalant/Features/ActivityStore.swift` or `SessionStore.swift` (typed states), plus whatever surface differentiates them.

**d) Native http-type hooks instead of command shims — PARTIAL**
- Exists: `PermissionRequest`, `Elicitation`, `Stop`, `SessionEnd` are `type: "http"` (`HookInstall.swift:302-320, 401-412`).
- Still command: the `PreToolUse` gate (`arm()` writes a command hook; `chalant-hook` then does POST-and-poll against `/permission`, `scripts/chalant-hook:171-258`) and the `Notification`/`Stop` reporting hooks (manual command snippet). Notably `POST /hook/pre-tool-use` (`ActivityServer.swift:888-901`) already exists server-side and nothing registers or calls it — the http half of this migration is built and unwired (also unreferenced in tests).
- Would change: `HookInstall.swift` (`arm()` / `holdEntry()` to write an http `PreToolUse` entry, plus a Notification http entry and an endpoint for it), `ActivityServer.swift` (a `/hook/notification` route; `/hook/pre-tool-use` would need a hold path if it should gate rather than just settle), `scripts/chalant-hook` (shrinks to Cursor/Codex reporting).

**e) Async push to phone (ntfy or similar) — MISSING, by recorded decision**
- No push, relay, or ntfy code exists. The shipped answer is a switch that sets Claude Code's own `remoteControlAtStartup: true` (`HookInstall.swift:663-712`), with rationale at 685-693: a push relay "would be this app rebuilding, worse, something already in the tool it watches". `TerminalPromptCard` deep-links "Open on your phone" via `SessionStore.Session.phoneURL(bridgeID:)` (`SessionCards.swift:911-914`).
- If reversed, would change: a new sender in `Chalant/Features/`, call sites in `SessionStore`/`ActivityServer` where needs-input states are set, settings UI in `DashboardSections.swift`.

---

## 8. Fragile / duplicated / half-finished

- **Dead route**: `POST /hook/pre-tool-use` (`ActivityServer.swift:888`) has no installer, no script, and no test that targets it. Half-finished native-http PreToolUse.
- **Two parallel permission pipelines for one card**: (1) command-hook polling — `POST /permission` → `SessionStore.Approval` → `GET /permission/<id>`/`collectDecision`, 25 s patience; (2) http hold — `PendingDecisionStore` continuation, bridged back into the same `SessionStore.Approval` UI via `onDecided` (`ActivityServer.swift:152-155`). Decision state lives in two places (`Approval.decision` and the continuation), reconciled by convention ("resolve returning false means it was the polling shim's", `ActivityServer.swift:149-152`). Correct today, but every change to approvals has to be reasoned through both paths.
- **Two rule systems for "don't ask me again"**: UserDefaults `approvalRules`/`approvalExceptions` (SessionStore, drives the polling gate and the "Always allow" button) vs `policy.json` Grants + hardcoded lists (PolicyEngine, drives `/hook/gate` and grant-only PermissionRequest settling). Same Claude-rule syntax, different stores, different expiry semantics (exceptions are forever, grants expire). A user's "always allow" applies to one pipeline and not the other.
- **Stale contradictory comments about PermissionRequest**: `ActivityServer.swift:577-583` (on `/prompt`) still says "nothing here can answer it (proven 2026-08-06, a decision returned on PermissionRequest is ignored)", and `TerminalPromptCard`'s header comment (`SessionCards.swift:803-810`) repeats it — while `HookGate.swift:258-267` documents the corrected finding (the 2026-08-06 test used the PreToolUse field name; `decision.behavior` works) and `/hook/permission-request` answers prompts in production. The card's *body* text was corrected (889-903); the two comments were not.
- **`disarm()` asymmetry**: detection counts a `PreToolUse` entry as ours if *any* inner command contains `chalant-hook` (`HookInstall.swift:129-133`); removal only removes entries where *all* inner commands do (`allSatisfy`, `HookInstall.swift:768-771`). An entry mixing Chalant's hook with another tool's reads as armed forever and can never be disarmed from the app.
- **Duplicated wire constants**: the detail-key list `["command","file_path","path","url","pattern","query"]` exists three times — `HookGate.swift:206`, `scripts/chalant-hook:202`, `scripts/chalant-hook:326` — kept in sync by comment only. Likewise the "Allowed/Denied from the Chalant island" reason strings (`HookGate.swift:291-293`, `ActivityServer.swift:858-861`, `scripts/chalant-hook:247-248`, `scripts/chalant-gate:160`).
- **Codex path is declared unverified in its own code** (`HookInstall.swift:578-583`, `scripts/chalant-gate:174-183`): config shape from docs, decision shape guessed, deliberately fails silent — meaning if the guess is wrong, arming Codex does nothing and nothing will ever say so.
- **Cursor/Codex session collapse**: `chalant-hook` maps any payload without a recognizable session id to `SESSION="default"` per agent (`scripts/chalant-hook:141-152`) — concurrent Cursor sessions share one row. Flagged "ponytail" in the script itself.
- **Settings backups accumulate**: every changed write to settings.json/hooks.json drops a dated `settings.chalant-backup-*.json` beside it (`HookInstall.swift:789-800`); `armPrompts` runs on every launch/port change, and nothing prunes old backups.
- **Blunt must-ask substrings**: `mustAsk` matches `.env`, `credentials`, `secrets` anywhere in the detail (`PolicyEngine.swift:76-79`), so e.g. `cat README.env.example` or a path containing "secrets" always interrupts. Documented as deliberate (65-66), but it is the list most likely to generate nuisance prompts.
- **Audit is memory-only**: `PolicyStore.audit` (cap 500) dies with the process (`PolicyEngine.swift:210-213`) — the account of what was auto-decided does not survive a relaunch.
- **In-code TODO markers**: two "ponytail" notes in `scripts/chalant-hook` (89, 148-149) — guessed field-name lists and the per-tool session fallback, both awaiting a real payload capture.
- **Vestigial content in-repo**: `_bmad-output/loop-loop/` (12 dated evidence/plan files) and `docs/superpowers/specs/` are working notes shipped in the repo; `docs/RELEASING.md` still references an `ExportOptions.plist` that does not exist (known release gotcha).
- **Ambiguity, not verified here**: whether Claude Code's http `Stop` hook and the command `Stop` hook (both installable simultaneously — one auto, one pasted) interact in order-dependent ways at a turn boundary. Both are registered on this machine's shape of install; the code treats them as independent (`/hook/stop` releases cards; the command hook delivers the outbox). Nothing in the repo documents their relative firing order.
