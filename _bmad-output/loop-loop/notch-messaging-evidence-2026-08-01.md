# Evidence: messaging an agent session from the notch

INNER-loop step 2. Gathered 2026-08-01 against Claude Code **2.1.220**. Records
only what was **observed on this machine**, and marks plainly where it stops.

## The ask

Founder: "we can also choose the agent session and send mesages right from the
notch move the microphone button to over there so the users can just speak and
send mesages or text messages to the agnet sessions see if thats possible or
there is a way to do that".

Two halves, and they have very different answers:

1. **Choose a session** - list the live ones, show what each is doing.
2. **Send it a message** - put text into a session that is already running.

## Half one: choosing a session. Confirmed, and better than what we ship.

`claude agents --json` prints every live session and exits. Its own help says
"Print active sessions (interactive and background) as a JSON array and exit
(for scripting; does not require a TTY)". Run here, it returned six:

| sessionId | name | cwd | kind | status |
|---|---|---|---|---|
| 53db8ee8… | chalant-f1 | ~/github/chalant | interactive | busy |
| cf2c3487… | offseason-workspace-38 | ~/github/offseason_workspace | interactive | busy |
| 09032b60… | offseason-workspace-e0 | ~/github/offseason_workspace | interactive | idle |
| 796a9441… | offseason-workspace-92 | ~/github/offseason_workspace | interactive | busy |
| 9511d4d8… | Explore Figma MCP capabilities | ~/github/offseason_workspace | background | blocked |
| f49b704b… | Check if new studio includes classes | ~/github/offseason_workspace | background | blocked |

It is backed by `~/.claude/sessions/<pid>.json`, one file per live session:

```
pid, sessionId, cwd, startedAt, procStart, version, peerProtocol: 1,
kind: interactive|background, entrypoint, name, nameSource,
status: busy|idle, updatedAt, statusUpdatedAt, bridgeSessionId
```

This matters beyond this feature. Chalant currently discovers sessions by
scraping `~/.claude/projects/**/*.jsonl` and walking parent process chains to
guess the owning app. This registry gives, directly and cheaply:

- the **live** set, not "a transcript was written recently"
- `pid`, which is what the click-through-to-terminal feature needs anyway
- `status: busy | idle` - the live-activity signal Phase 3 item 10 asks for
- `state: blocked` on background agents - a session waiting on input
- a human `name` already derived

The registry is a plain directory of JSON files, so it is watchable with the
`DispatchSource` file-system watch Chalant already uses, and needs no polling.

## Half two: sending. No supported local path found.

Searched for a way in, and did not find one:

- **No named socket, no port.** `lsof` on every live session pid shows only
  anonymous unix socketpairs (`unix 0x… -> 0x…`), no bound path. No process is
  listening on TCP. `peerProtocol: 1` in the registry names a protocol whose
  transport is not reachable from outside the process tree.
- **No send subcommand.** `claude agents` manages background agents through an
  interactive TUI; `--json` prints and exits. There is no
  `claude agents send`, no `claude send`, nothing that takes a session id and a
  message.
- **The daemon is not a public surface.** `~/.claude/daemon/` holds
  `control.key`, `roster.json` and an empty `dispatch/`. Suggestive, entirely
  undocumented, and the supervisor had already idle-exited. Building on it
  would be building on another program's internals at a pinned version.
- **`--remote-control` proves the capability exists, elsewhere.** Sessions
  carry a `bridgeSessionId` (`session_01…`), the same id claude.ai uses. So
  "type at a running session from another device" is a real, shipping feature -
  but it routes through Anthropic's bridge, not a local API a menu-bar app can
  call.

### The Stop hook works. Confirmed against the documentation.

Checked directly at `code.claude.com/docs/en/hooks` rather than taken on
report. The hooks reference lists which events may add context for Claude, and
where that context lands:

> **Stop and SubagentStop: at the end of the turn. The conversation continues
> so Claude can act on the feedback.**

So a Stop hook returning `hookSpecificOutput.additionalContext` puts text in
front of the model and keeps the turn going. That is the injection path, and it
is documented rather than inferred.

```json
{
  "decision": "block",
  "reason": "shown when blocking",
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "the queued message"
  }
}
```

Two notes on the contract, because they are easy to get backwards:

- **`additionalContext` is the field that reaches the model.** `reason`
  accompanies `decision: "block"`; the documentation separates the two, and
  only `additionalContext` is described as feedback the conversation continues
  on. Use `additionalContext` and do not rely on `reason` carrying the payload.
- **Exit code 2 is the other blocking route.** For Stop it "prevents Claude
  from stopping, continues the conversation", and on exit 2 "stderr text is fed
  back to Claude as an error message". That works, but it arrives framed as an
  error. A user's message is not an error, so prefer the JSON path.

Chalant already ships `scripts/chalant-hook` on Notification and Stop, and a
local HTTP API. The hook gains one call: ask the app whether anything is queued
for this `session_id`, and hand it over if so.

### The shape this forces on the product

Delivery is at the **end of a turn**, never mid-run. No hook fires while the
model is thinking. Speaking into the notch queues a message that the session
picks up when it next comes to rest, so latency is however long the current
turn has left - seconds if it is finishing, minutes if it is deep in a build.

That is a different product from "interrupt it now", and the interface has to
say which one it is. A message that sits silently until a long turn ends will
read as broken. An `idle` session, by contrast, has already stopped: its Stop
hook has been and gone, so a message queued now waits for the **next** turn,
which may never come. Both cases need an honest answer in the design, and the
`status` field from the registry above is what distinguishes them.

### There is no official API, and the gap is known

Two feature requests ask for exactly this - #27441 "Inter-agent message
injection" and #53049 "External message injection API for active Claude Code
sessions". Both are closed, and it is worth being precise about why, since
"closed" could have meant "shipped": both were auto-closed by a bot as
duplicates (of #24947 and #35072 respectively), with no implementation. The
third-party `sstraus/claude-commander` wraps Claude Code in a socket API for
the same purpose, which confirms the need and is not something we would adopt -
it requires the user to launch Claude through someone else's wrapper.

### Explicitly out

Synthetic keystrokes into the terminal, or writing another process's stdin.
Both need Accessibility, which this app has deliberately avoided (the global
shortcuts use Carbon precisely so no prompt appears and no keystrokes are
read). A feature that surrenders that is not worth having.

## What has NOT been established

- Whether a Stop hook can inject text back into the model, and its exact JSON.
- Whether any hook can originate a turn rather than decorate one.
- Whether `--resume` can append to an existing transcript non-interactively
  without starting a second process that fights the first for the session.
- Whether the registry is a stable contract or an implementation detail. It is
  undocumented; the CLI flag that reads it is not.

Anything past this line is for the architect to plan against, not to assert.
