# Sessions becomes a control room

Design, 2026-08-03. Chalant 1.5.0 is the first build where "control the
agents on your Mac from the notch" is true. This is the surface that
claim rests on, and today it is the least finished thing in the app.

## The problem, in pixels

Driven against the running 1.5.0 build, two sessions live:

- **Focused Sessions is mostly void.** The panel is 480pt tall and holds
  about 140pt of content. Two rows sit at the top of a room built for
  eight and the rest is black. It reads as a bug, not as room to grow
  into.
- **The glance gives Sessions a sliver.** Music, activity and ambience
  hold roughly 190pt above the switcher whether or not they have
  anything to say. Spotify was paused and the music row still took the
  top third of the island.
- **The agent's last words float.** `lastWord` renders outside the row's
  card at a different indent with no rule and no attachment. The
  composer already quotes the same text properly; the row does not.
- **Two rows, one treatment.** A headless background task and a session
  you can talk to look identical. State lives only in an 11pt mark's
  rotation, which is invisible in a still frame and near invisible in
  motion.
- **Both rows say "now."** The one number on the row carries no
  information most of the time.
- **One verb.** You can message. You cannot open the terminal from the
  row, stop a turn, or see what finished while you were away.

## What this spec is not

Two sibling specs, deliberately out of scope here:

- **B, the island only shows what has something to say.** Glance chrome,
  the collapsed pill's urgency ladder, empty states in other tabs.
- **C, the Dashboard pass.** A different surface, a different design
  language, and the home of approval rules.

Also out of scope: Cursor or Codex sessions (no hook contract exists),
multi-select or bulk action on sessions, and any form of search or
filter. With a cap of 20 tracked sessions and a rail that groups by
state, search solves a problem this surface does not have yet.

## 1. The room

`focused` Sessions stops being a strip in a fixed 480pt box and becomes
a two-pane room.

**Width.** A floor on the user's own dial, never an override:

```
focusedRoom ? max(configWidth, 820) : configWidth
```

This is the exact shape of the existing `chatFull` floor
(`NotchViewModel.expandedWidth`, `max(configWidth, 680)`), so it inherits
a pattern the hover-zone arithmetic in `expandedZone(on:)` already
computes correctly. 820 is inside the configured range (420...840) and
inside the 1000pt panel with 90pt of air each side.

**The split.** The rail is a fixed 280pt. The detail pane takes the
remainder. A sidebar does not grow when the window does, so a user who
runs an 840pt island gets a wider reading column, not a wider list.
`contentPadding` is itself a user dial (`paddingRange` 8...36, default
20), so the detail column at the 820 floor is:

| padding | content width | detail column |
|---|---|---|
| 8 (minimum) | 804 | 512 |
| 20 (default) | 780 | 488 |
| 36 (maximum) | 748 | 456 |

456 at `Theme.Fonts.caption` is about 68 characters, which is still a
real measure. No configuration crushes the reading column.

**Height.** `Theme.Panel.room`, replacing `Theme.Panel.focused = 480`
for this destination. It is computed rather than constant, because every
input to it is a user dial, and a fixed number safe for the worst of them
would then leave room unused on every ordinary Mac:

```swift
// Theme.Panel
static let panel: CGFloat = 720          // the window every island lives in
static func room(topReserve: CGFloat, padding: CGFloat) -> CGFloat {
    let chrome = topReserve + Theme.Space.notchClearance + headerBlock + padding
    return min(620, max(420, panel - chrome))
}
```

The 720 currently lives as a private `panelSize` in
`NotchWindowController` while comments in three other files reason about
it. It moves here and the controller reads it, so there is one number.

Worked through: on this machine's built-in display (notch 32, padding
20) the room is 620, capped. On the worst configuration anyone can dial
in (emulated notch at `heightRange` maximum 60, padding 36) the chrome
is 142 and the room is 578. Today's number is 480 in both cases. The
clamp floor of 420 exists so that a future panel change can never
produce a negative or absurd room; nothing in today's ranges reaches it.

Both panes scroll independently inside whatever this resolves to.

**The empty room does not open at full height.** With nothing running and nothing
in the record, the room is not two panes with a void in them. It
collapses to a short invitation (section 9). This is the one case where a
fixed height would reproduce exactly the bug this spec exists to fix.

## 2. The rail

Four groups, in this order, each with a count, and only the non-empty
ones drawn:

| Group | Membership |
|---|---|
| **Needs you** | an approval held, or an unanswered `ask`, or `state == .needsInput` |
| **Working** | `state == .working` |
| **At its prompt** | `state == .idle` |
| **Finished** | the record (section 3) |

"At its prompt" is the app's own existing phrasing, already in the
accessibility label. "Idle" is accurate and reads like a complaint.

Within a group, the existing rule holds unchanged: `startedAt`
descending, never `updatedAt`. Discovery rewrites `updatedAt` on every
sweep and sorting by it made rows trade places on a five second clock
(founder, 2026-08-02: "just dont make them change places").

Grouping is derived from the state the store already keeps. Nothing in
`SessionStore.sort()` changes, because its rank order and this group
order agree by construction; the rail reads the already-sorted `sessions`
array and cuts the first three groups out of it rather than sorting
again. Finished is the exception: it comes from a different array
entirely (section 3), is always last, and is sorted by `finishedAt`
descending on its own.

**A rail row** is: state dot, title (one line, middle truncation), and a
subtitle of `folder · branch`. Not the activity. Activity changes every
few seconds and belongs in the detail pane where it is the point; in a
rail it is a line of text that never stops moving next to the thing you
are trying to click.

**The state dot** replaces the load the `AgentMark` currently carries
alone. The mark stays as the "whose session is this" signal at the row's
head. The dot is a separate 6pt shape with four readings that survive a
still frame: filled accent for needs-you, filled and breathing for
working, hollow for at-its-prompt, and a hairline ring drained of colour
for finished.

**Selection is keyed by session id, never by index.** The store re-sorts
the instant a state changes, and a session moving from Working to Needs
you would otherwise pull a different session under the user's cursor.
When the selected id leaves the list entirely, selection falls to the
first row of the highest-ranked non-empty group rather than to nothing:
an empty detail pane next to a full rail is the void bug again in
miniature.

**The room opens** on the first row in Needs you, else the first Working,
else the first row of the first non-empty group.

### 2a. The number that means nothing

Both rows in the screenshot say "now," and they will almost always say
"now," because the row renders `RelativeAge.short(updatedAt)` and
discovery rewrites `updatedAt` on every sweep. The trailing column of
every session row is therefore reporting how recently this app looked,
not anything about the session. It has been decorative since it was
written.

The fix needs a timestamp that moves when something happens rather than
when a timer fires. `Session` gains `stateSince: Date`, written in the
one place state is assigned and only when the value actually changes.
The row then reads what its state measures: `4m` under working means the
turn has run four minutes, `12m` under at-its-prompt means it has been
waiting that long, `30s` under needs-you means that is how long it has
been blocked on a human.

This is the only change section B does not get to make later, and it
belongs here rather than there: it lands on both the rail row and the
glance row, and both of those are this spec's surface. Everything else
about the glance (the chrome above it, the collapsed pill) stays with
spec B.

The state dot from the section above lands on the glance row too, for the
same reason it exists in the rail: an 11pt mark's rotation is not a state
indicator, and today a background task with no terminal and a session
mid-turn are drawn identically.

## 3. The record: bounded history

Today a `.done` or `.failed` session is deleted from the store 60 seconds
after it finishes (`finishedTTL`), and a session the registry loses is
marked `.stale` and filtered out of the strip. Nothing survives to be
caught up on.

`AgentSessions.swift` currently carries a law against exactly this:

> Only sessions that are actually going appear: a developer's machine
> carries months of history, and listing all of it would push a wall of
> finished work into a surface whose whole premise is calm.

That law is right and it is kept. What changes is that a bounded record
is not a wall. Three bounds, and the first is the one that matters:

**1. Only sessions this app watched finish.** The record is appended from
exactly two places, both of which are observed transitions out of a live
state:

- `markGone(_:)`, where the registry reported a process alive last sweep
  and does not report it now.
- `upsert(...)`, where `previousState.isLive` and the incoming state is
  `.done` or `.failed`.

Both append only when the state being left behind was live. `markGone`'s
caller in `reconcile` already filters to `state.isLive`, but the check
belongs inside `markGone` alongside the append rather than in the one
caller that happens to do it today: `markGone` is not private, and a
second caller passing an already-dead id must not be able to put a
duplicate row in the record.

A session discovered from a cold transcript file is never live in this
store's eyes and therefore never transitions, so it can never enter the
record. History means "what happened while I was watching," not
"everything on this disk." This is what keeps a machine carrying months
of transcripts from carrying months of rows.

**2. Two hours, eight rows, whichever runs out first.** Evicted oldest
first on append and on a read that finds an expired entry, so a room left
open overnight does not show yesterday.

**3. Never in the glance.** `AgentSessionsStrip`'s `live` filter is
untouched. The calm surface is exactly as calm as it was. The record
exists only in the room you deliberately clicked into.

**Shape.** A separate `SessionStore.finished: [Finished]` rather than
extending `finishedTTL` and letting `sessions` hold the dead. Three
reasons: `sessions` goes on meaning "what I am tracking now," which every
other consumer already relies on; the record needs to survive
`clear(id:)`, which is the very call that would delete it; and it stores
only what a record needs.

```swift
struct Finished: Identifiable, Equatable {
    let id: String              // the session id, deduped on append
    var title: String
    var cwd: String
    var branch: String?
    var agent: Agent
    var outcome: Outcome        // .done | .failed | .lost
    var lastMessage: String?    // its final words, for the rail's subtitle
    var transcriptPath: String? // so the detail pane can still be read
    var finishedAt: Date
}
```

`transcriptPath` is what makes a finished row worth selecting rather than
only worth counting. `SessionDiscovery` already knows the path (its
`jsonlFiles(in:)` returns one per session) and today throws it away after
reading; it is carried onto `Session` and from there into the record. Nil
means the file has since been rotated away, and the detail pane says so
rather than showing an empty column.

`.lost` rather than `.done` for the `markGone` path, because this store
does not claim outcomes it cannot know. That rule is already written into
`markGone`'s own comment ("a killed session did not finish, and claiming
an outcome this store cannot know is the kind of lie it does not tell
anywhere else") and the record must not be where it starts lying.

**Finished rows show a wall clock** (`8:41`), not a relative age. For
something that already happened, when it happened beats how long ago.
Live rows keep `RelativeAge.short` unchanged.

**Selecting a finished row** shows its detail pane read-only: the
conversation as scraped, the outcome and time, and no composer. Where the
transcript is still on disk, the record's rows read exactly as richly as
live ones; where it has been rotated away, the pane falls back to the
`lastMessage` the record kept and says that the rest is gone. What a
finished row always loses is the ability to be written to, and that is
stated rather than implied: the composer is replaced by one line saying
the session ended, beside a button that opens its folder.

## 4. The detail pane

**Header line.** The agent mark, the title, and under it
`folder · branch · <state and duration>`. Duration is what the state
actually measures: "running 4m" for working, "at its prompt 12m" for
idle, "waiting on you 30s" for needs-input, "finished 8:41" for the
record.

**Body**, scrollable, oldest at the top, pinned to the bottom when new
content arrives unless the user has scrolled up (a view that yanks itself
down mid-read is worse than one that does not follow at all):

- **Your turns** and **its turns** as quoted blocks with a 2pt leading
  rule, the same treatment `ComposeCard.lastWord` already uses, with a
  `you · 6m` or `Claude · 2m` label above each. Markdown rendered through
  the existing `ComposeCard.rendered`, which keeps the line breaks an
  agent wrote.
- **Tool calls** threaded between them as single dotted lines: a filled
  dot, the verb, and the object. `Read AgentSessions.swift`,
  `Ran git rebase origin/main`, `Edited SessionStore.swift`.
- **The in-flight call** at the bottom with a hollow dot and its elapsed
  time: `Running xcodebuild test… 1m`. This is the whole reason a working
  session stops being an opaque spinner.

**Pinned below the scroll, never scrollable away, in this order:**

1. The **approval card**, when a call is held. It has an agent standing
   still on the other side of it and a countdown running; it may not be
   something you can scroll past.
2. The **ask card**, when a question is outstanding.
3. The **composer**.
4. The **action row**.

Both cards keep their current behaviour and copy exactly. They move
files (section 8) and gain a wider column; they do not change.

## 5. Reading the conversation

Verified against a real transcript
(`~/.claude/projects/<slug>/<session-id>.jsonl`, 2026-08-03) rather than
assumed. Record shapes actually present:

| Record | Meaning |
|---|---|
| `type: "user"`, `message.content` a **string** (or a list of `text` blocks), no `tool_result` block | a human turn |
| `type: "user"`, `message.content` a list holding `tool_result` blocks | a tool returning, not a turn |
| `type: "assistant"`, block `type: "text"` | what it said |
| `type: "assistant"`, block `type: "thinking"` | never shown |
| `type: "assistant"`, block `type: "tool_use"` with `name`, `input`, `id` | an activity line |
| `isSidechain: true` on any record | a subagent's turn, never shown |
| `attachment`, `system`, `file-history-snapshot`, `ai-title`, `agent-name`, `mode`, `last-prompt`, `permission-mode` | not conversation |

`timestamp` is ISO 8601 with a `Z` suffix, present on every user and
assistant record and absent from the metadata record types.

The human-turn test is the absence of a `tool_result` block, not the
presence of `promptSource: "typed"`. Typed input does carry that value
(observed), but a message this app queued through the outbox and Claude
Code collected is equally the user's turn and must not be filtered out
for arriving by another door. `promptSource` is worth reading to label a
turn, never to decide whether it is one.

**The reader runs for one session, on demand, and never on the sweep.**
This is the load-bearing decision in this section. The obvious design is
to extend `parseMetadata`, which already reads the tail and already walks
these blocks, so that the same fold also accumulates turns. That would be
wrong: discovery sweeps up to twelve transcripts every five seconds, and
building a 60-entry turn list for each of them means doing the expensive
part of this work for eleven sessions nobody is looking at. This app has
an audited 0.35%-core idle baseline and it is worth more than the
convenience.

So turns are their own pass, over one file:

```swift
// SessionDiscovery
func turns(atTranscript path: String) -> [Turn]?

enum Turn: Equatable {
    enum Speaker { case you, agent }
    case said(who: Speaker, text: String, at: Date)
    case did(tool: String, detail: String, at: Date, id: String, finishedAt: Date?)
}
```

It reuses the tail machinery exactly (the same `tailBytes`, the same
seek-to-end, the same discard of the first mid-line line, the same
skip-the-unparseable-line discipline) and shares the block-walking
helpers with `parseMetadata`, but it is called by the room for the
**selected session only**.

Refresh rules, so a live conversation still feels live without paying for
it:

- On selection change, immediately.
- While the selected session is `.working`, every 2 seconds.
- Otherwise every 10 seconds, since a session at its prompt is not
  writing.
- Every one of those gated on the transcript's `mtime` having moved. A
  `stat` is free; re-reading and re-parsing 256KB because a timer fired
  is not.
- Never at all while the room is closed.

The parse cost is therefore bounded to one file at a time, and only while
a human is looking at that file. The `mtime` check is the caller's, held
in the room's poller rather than inside `turns(atTranscript:)`, so the
reader stays a pure function of a path and a test can call it without a
clock.

**A tool call's `detail`** is one short line derived per tool, never the
raw input JSON: `command` for Bash truncated at the first newline,
the last two path components for Read/Edit/Write, `pattern` for
Grep/Glob, `description` for Task and Agent, and the tool name alone for
anything unrecognised. Bounded at 80 characters. An unrecognised tool
showing only its name is the correct failure: this is a glance at what an
agent is doing, and a wrong guess about a tool's shape is worse than no
detail.

**`finishedAt` on a `.did`** comes from the `tool_result` record carrying
the same `tool_use_id`, which is the existing mechanism
`parseMetadata` already uses to resolve a pending `AskUserQuestion`.
A call with no matching result in the tail is the live one.

**Bounds.** The tail is kept at 256KB and the turn list at the last 60
entries. A session mid-compaction or one whose last turn is enormous
cannot make this list unbounded, and 60 entries against a column this wide is
already more scroll than anyone reads in the notch.

**Sidechains are dropped, not summarised.** A `Task` call in the main
thread already produces a `.did` line saying a subagent was dispatched.
Threading a subagent's own turns into the parent conversation would make
the pane unreadable in exactly the sessions where reading it matters
most.

## 6. Actions

A single row under the composer, three items, each of which says what it
will actually do:

**Open terminal.** `SessionLocator.reveal(cwd:)`, which already returns
`Bool` and already falls back to Finder in `AgentSessionsStrip.go(to:)`.
What changes is the label: "Open terminal" when the locator can find one,
"Open folder" when it cannot. One label that is sometimes a lie is worse
than two that are each true.

**Copy id.** One line, and it ends the "which session was that" hunt when
someone wants to reach it from a script or the CLI.

**Stop.** Sends `SIGINT` to the pid, which is what Ctrl-C sends, and is
meant to interrupt the current turn rather than kill the session. Two
step, in place, no modal: the button becomes "Stop it?" with "Yes" and
"No" beside it, which is how the approval card already takes the only
other decision in this app that changes what a running agent does.
Offered only when `pid` is known, which is only when the registry has
vouched for the process.

**Stop does not ship on assertion.** Whether Claude Code treats an
out-of-band `SIGINT` the way it treats Ctrl-C in its own terminal has to
be proven against a real throwaway session, in both directions, before
this is wired to a button. That is the same bar the `PreToolUse`
approval hook was held to on 2026-08-02, and it is the bar because the
failure mode here is destroying somebody's work in progress. If the
proof comes back "this kills the session," the button does not ship and
the action row carries two items. Section 12 records this as a gate, not
a task.

## 7. Keyboard

The panel is already `canBecomeKey`, and a room entered by a click is
already allowed to take the keyboard (the guard added in `873a373` is
against an island that opens *on its own* taking focus, which this is
not).

| Key | Does |
|---|---|
| `↑` / `↓` | move selection through the rail, across group boundaries |
| `⏎` | focus the composer |
| `⌘⏎` | send |
| `esc` | leave the composer if it has focus, else leave the room |

Nothing here is the only way to reach anything. Every one of these has a
visible control, which is this app's standing rule about not hiding
answers in gestures.

## 8. The files

`AgentSessions.swift` is 1003 lines and this work would roughly double
it. Three files, split along the seam that already exists:

| File | Holds |
|---|---|
| `Views/AgentSessions.swift` | `AgentSessionsStrip` (the glance) and its row |
| `Views/SessionRoom.swift` | the room, the rail, the detail pane, the turn views |
| `Views/SessionCards.swift` | `ApprovalCard`, `AskCard`, `ComposeCard` |

The cards move because both surfaces use them and neither owns them.
They are currently `private` to `AgentSessions.swift`; they become
internal, which is the smallest visibility that lets the room reach them.

`ExpandedView.focusedPanel` routes `.sessions` to `SessionRoom` instead
of `AgentSessionsStrip(focused: true)`. The `focused` parameter on
`AgentSessionsStrip` and its `lastWord` helper are deleted rather than
left unreachable, and with them goes the floating unattached text this
spec opened by complaining about.

Also touched: `SessionStore` (the record, `Finished`, grouping,
`stateSince`), `SessionDiscovery` (turns, `transcriptPath`), `Theme`
(`Panel.panel`, `Panel.room`, and `Panel.focused` retired),
`NotchWindowController` (reads `Theme.Panel.panel` instead of its own
private `panelSize`), `NotchViewModel` (`expandedWidth` floor,
`selectedSessionID`).

## 9. Empty states

Three, and none of them apologises:

**Nothing has ever run.** "No agents yet. Start Claude Code in any
terminal and it appears here." Plus, when `HookInstall.status() !=
.installed`, one line and a button: the hook is what makes messaging and
approvals work at all, and the empty room is the one place there is
space to say so without nagging.

**Nothing running, but the record has rows.** The room opens two-pane
normally with only the Finished group in the rail. This is the "catch
up" case working exactly as designed and needs no special text.

**A session with no readable transcript.** The detail pane says what it
knows (title, folder, state) and one line: "Nothing readable in this
session's transcript yet." Never an empty column.

## 10. Testing

Pure functions first, because that is what this store has done well
before (296 tests, `SessionStoreTests` at 2704 lines):

- **Grouping.** Every state lands in the right group; an approval or an
  unanswered ask pulls a `.working` session into Needs you; empty groups
  are absent, not empty.
- **The record.** Appended on `markGone`; appended on a live→done and a
  live→failed upsert; **not** appended for a session first seen already
  dead; deduped by id; capped at eight; expired at two hours; surviving
  `clear(id:)`.
- **Selection.** Survives a re-sort that moves the selected session
  between groups; falls to the first row of the highest non-empty group
  when its session leaves; never lands on nothing while rows exist.
- **`stateSince`.** Moves on a real state change; does **not** move when
  a rescan re-asserts the same state, which is the entire bug it exists
  to fix; survives the registry and the scraper both writing the session
  in the same sweep.
- **The turn reader.** Ordering; a tail beginning mid-line; a human turn
  read from a string `content`; a `tool_result` not mistaken for a turn;
  `thinking` blocks excluded; `isSidechain` records excluded; a
  `tool_use` resolved to finished by a later `tool_result` with the same
  id; an unresolved call reported live; the 60-entry bound; a malformed
  line skipped without taking the file down (the existing law).
- **Tool details.** One case per recognised tool plus an unrecognised one
  falling back to its name; the 80 character bound.
- **The refresh gate.** An unchanged `mtime` produces no re-read; a
  working session polls faster than an idle one; a closed room polls not
  at all. Driven through an injectable clock and a stubbed file, the way
  `finishedTTL` is already a constructor argument so a test does not have
  to wait 60 real seconds.
- **Geometry.** `Theme.Panel.room` at the default configuration, at both
  ends of `paddingRange`, at `heightRange` maximum, and the clamp holding
  at both ends. The width floor at and above 820. The rail fixed while
  the detail pane grows. The empty room not opening at full height.

The 296 existing tests stay green. No test starts a real session, and no
test writes to a real install's Application Support (the `outboxDir`
seam already enforces this).

## 11. Edge cases

- **EC-1.** The selected session's state changes while its detail pane is
  open. The pane updates in place; selection does not move; the rail
  re-groups under it.
- **EC-2.** The selected session disappears (registry loses it) while
  open. It moves to Finished with outcome `.lost` and stays selected, so
  the pane the user was reading does not vanish out from under them. The
  composer is replaced by the ended line.
- **EC-3.** An approval arrives on a session that is not selected. The
  rail's Needs you group gains it and its count changes. Selection does
  **not** jump: a countdown running on one session is not permission to
  move somebody's cursor off the one they were typing into. The existing
  `onSessionWantsYou` notification is what carries the urgency.
- **EC-4.** The room is open and the display configuration changes (a
  monitor is unplugged). The existing island travel behaviour applies
  unchanged; the room's width floor is recomputed for the new display's
  config.
- **EC-5.** A transcript is rotated or compacted between sweeps. The tail
  read simply returns fewer turns. The pane shows what it has; it never
  shows a partial line.
- **EC-6.** A session with 60+ tool calls and no text. The pane is a list
  of activity lines with no quoted blocks, which is an honest picture of
  a session that has not said anything yet.
- **EC-7.** Two sessions in the same folder on the same branch. The rail
  subtitle is identical for both; the title (`aiTitle`) is what separates
  them, and where that is also identical the record is genuinely
  ambiguous. Not solved here; noted so nobody later thinks it was missed.
- **EC-8.** The user's width dial is already above 820. The floor does
  nothing and the detail pane is wider. No case where the floor shrinks
  an island.

## 12. Gates before this ships

1. **SIGINT semantics proven** against a real throwaway Claude Code
   session, in both directions, or Stop does not ship (section 6).
2. **The computed room measured in pixels** on both a real notched
   display and an emulated one at `heightRange` maximum with padding at
   `paddingRange` maximum, since the arithmetic is a prediction until
   pixels agree with it.
3. **The full suite green** before any Release build, which is this
   project's standing ritual.

## 13. Why this is the right work now

1.5.0 is the first version whose unusual capability is real: an island
that can hold an agent at the door and let you answer it. That capability
currently lives in a surface with a 340pt hole in it. The room is also
the demo: it is what a screenshot of this app should be, and the app's
own owner has 100+ releases against 73 downloads. Making the one
differentiated surface excellent is the same work as making the pitch
showable.
