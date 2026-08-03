# Evidence: Cursor and Codex can notify the island

Gathered 2026-08-02 on this machine. Backlog B8.

The founder: "add the notifications and the hooks for when questions or
anything arrive for cursor and also codex instructions etc."

Earlier evidence recorded that **Codex has no session store** - `~/.codex`
held only config and tmp - and that conclusion was used to defer Codex. That
was true of the *store* and is the wrong test for this feature. Both agents
have a **hook** surface, which is all a notification needs.

## Codex: confirmed

`~/.codex/hooks.json` exists and is live. Its shape is Claude Code's exactly:

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "..." } ] } ] } }
```

Events present here: `SessionStart`, `UserPromptSubmit`, `Stop`.

## Cursor: confirmed, and richer

`~/.cursor/hooks.json`, `"version": 1`, a flatter shape - one array of
`{ "command": "..." }` per event, no inner `hooks` key:

```json
{ "version": 1, "hooks": { "stop": [ { "command": "..." } ] } }
```

Events present: `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `stop`,
**`beforeShellExecution`**, **`beforeMCPExecution`**.

The last two are the interesting ones. They fire when Cursor is about to do
something that needs permission, which is the closest thing any of the three
agents has to "a question arrived" as a first-class event. Claude Code
approximates it with a Notification matcher; Cursor names it.

## The constraint that matters most

**Both files are already in use.** Every event above currently points at
`~/.superset/hooks/`, a third-party tool the founder already runs.

So Chalant must **add itself alongside**, never replace the file. Writing
either of these wholesale would silently disable a tool the founder depends
on, and they would have no reason to connect the two events. This is also
why the existing decision holds: Chalant hands over a snippet and shows
whether it is installed, and does not write anyone's config.

## Three shapes, one script

`scripts/chalant-hook` is written for Claude Code's payload: it reads JSON on
stdin and pulls `session_id`, `cwd` and `stop_hook_active`. Codex and Cursor
will not use the same field names, and Cursor passes its event as an argv
(`cursor-hook.sh Stop`) rather than only in the payload.

What is **not** established, and must be before anything is built on it:

- The exact stdin payload each one sends, and what a session is called in it.
- Whether either supports blocking or injecting text back, the way Claude
  Code's Stop hook does with `hookSpecificOutput.additionalContext`. **Do not
  assume they do.** Notifications need no such thing; messaging does, and
  messaging to Cursor and Codex is out of scope until this is answered.
- Whether Cursor's permission events expect a structured reply. A hook that
  answers wrongly on `beforeShellExecution` could block the founder's own
  work, so this one is read-only until proven otherwise.

## What this changes

B8's notification half is buildable for both, today. `SessionStore.Agent`
already carries `.cursor`, `CursorDiscovery` already finds Cursor sessions,
and the island already renders per-agent marks. The missing piece is the
hook script learning two more dialects and the pane offering two more
snippets.

Messaging stays Claude-only until the injection question above is answered
with documentation rather than a guess. `canReceiveMessages` already
enforces exactly that.
