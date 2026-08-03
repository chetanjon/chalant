# Chalant backlog

The single list. Every item traces to something the founder said, with the
date. Kept honest: an item moves to Done only once it has been **seen on a
screen**, not when it compiles.

Status: `[ ]` not started · `[~]` in flight · `[x]` done and seen · `[!]` done but unseen

---

## A. The notch has to look like a notch (2026-08-02)

> Planned: `notch-geometry-plan-2026-08-02.md`. **Blocked on verification:**
> this Mac is in clamshell, so no notched screen is attached and A1, A2 and
> A3 cannot be seen until the lid is open. Measuring also corrected the
> scope: hardware sizing already ships, and what looks wrong is the island
> drawing deliberately bigger than what it measured.


- [!] **A1. Match the real hardware by default.** Default size and shape should
  be the machine's actual notch, not invented numbers, unless the user changes
  them. Today `Config` ships 196x38 for everything.
- [!] **A2. Hide under the physical notch at rest, expand on hover.** On a
  MacBook the collapsed island should be indistinguishable from the cutout.
- [!] **A3. Remove the arc at the bottom edge.** Use the MacBook notch's own
  corner radius. "make it clean and proper."
- [!] **A4. Padding, margins and type inside the island.** Content sits too
  close to the borders. Needs a proper spacing pass, not a nudge.
- [!] **A5. Expanded size is adjustable from the dashboard.** Separate from the
  collapsed size: a pill's collapsed shape is dynamic, but the opened panel
  should be sizeable so it can be given more room.

## B. Sessions (2026-08-02)

- [!] **B1. Sessions move into their own tab.** Out of the always-on island
  body, into the switcher beside Today / Clipboard / Shelf.
- [!] **B2. Rows stop reshuffling.** They change places on every update. Order
  must be stable unless something meaningful changed.
- [!] **B3. Sessions appear fast.** A second of blank on open is too slow.
- [x] **B4. Clicking a row opens the composer**, never Finder. `bd0e9a2`.
- [x] **B5. The mark carries state**, rings removed. `4e6d0af`.
- [x] **B6. Queue behaves like Claude Code's**, one message per turn. `4e6d0af`.
- [x] **B7. A session that wants you announces itself**, and its pill opens the
  session when clicked. `6dc36db`.
- [!] **B8. Cursor and Codex** get the same notifications and hooks as Claude
  Code. **Feasibility settled, and the earlier answer was wrong.** Both have a
  live `hooks.json`: Codex in Claude Code's exact shape (`SessionStart`,
  `UserPromptSubmit`, `Stop`), Cursor in a flatter one with the richer event
  set (`stop`, `beforeShellExecution`, `beforeMCPExecution` - a named
  permission-request event neither of the others has). "Codex has no session
  store" was true and was the wrong test: a notification needs a hook, not a
  store. Evidence: `cursor-codex-hooks-evidence-2026-08-02.md`.
  Both files are already in use by a third-party tool the founder runs, so
  Chalant adds itself alongside and never rewrites either. Messaging stays
  Claude-only until injection is documented rather than guessed.
- [!] **B9. Not-installed hook banner** at the top of the Sessions tab, and the
  installed state should use colour (green) rather than grey.

## C. Clipboard (2026-08-02)

- [!] **C1. Keep the whole history.** "so I dont lose anything that I copied."
  Currently capped and in memory.
- [!] **C2. Pagination** through that history.
- [!] **C3. Search across all of it**, not just what is loaded.

## D. Dashboard (2026-08-02)

- [x] **D1. Sidebar toggle pinned** at the leading edge. `a299f64`.
- [x] **D2. A stray vertical line** appears beside the sidebar; the pane also
  misbehaves until the sidebar is closed and reopened.
- [!] **D3. Arrangement drag** - FIXED, not labelled. The gesture was never
  the problem: the window was movable by its background, so AppKit began a
  window drag on mouse-down and pre-empted the row's own. Property off, drag
  restored unchanged. Needs one real drag to confirm; worst case is the rows
  do not reorder, never that the window jumps.
- [!] **D4. Update button** that downloads, installs and relaunches.
  **The premise was wrong and worth recording.** Sparkle has been fully
  wired since 1.2.13 - signed appcast on Pages, real key, six shipped
  releases. Only the button's location was wrong: it sat in About as plain
  tinted text rather than in General beside the update switch. Moved and
  made a real button. `docs/RELEASING.md` records the step nobody had
  written down: appcast.xml must reach `main`, because Pages serves `main`
  whichever branch cut the release.

## H. From using it, 2026-08-02 evening

- [!] **H1. Remove the media-row microphone.** Founder decided: remove, not
  move. "not needed near the spotify." Voice keeps the `.talk` hotkey and the
  collapsed long-press.
- [!] **H2. The scrollbar in the sessions list** is visible and "messing with
  the UI". Hide the indicator; keep the scrolling.
- [!] **H3. Say whether a message actually went.** "how do I know if the
  request is being sent or not is it actually working". Today a queued message
  shows Next/Queued, then Delivered for 2.5s. That is easy to miss entirely,
  and nothing says it reached the model rather than merely leaving.
- [!] **H4. A way to test notifications.** "I want to test the notification and
  everything." A button in the Sessions pane that fires a real one through the
  real path, so it proves the wiring rather than faking a pill.
- [!] **H5. Old pills cannot be acted on.** A needs-input pill never expires by
  design, so one can sit for hours after its session has gone; clicking it can
  only report that the session is missing. When a session ends, its pill should
  resolve rather than linger as something that looks actionable and is not.
  (Two of the three the founder hit were the assistant's own uncleaned test
  pills, since cleared.)

## E. Media (2026-08-02)

- [!] **E1. The wrong app icon.** Audio playing from Dia shows Chrome's icon.
- [x] **E2. The media-row microphone** - decided: remove. See H1.

## F. Bigger, already agreed

- [ ] **F1. Drag and drop inside the island.** Decided 2026-08-02: **one
  shared arrangement**, a drag anywhere applies everywhere. No per-display
  copy, no migration.
  Likely root cause of the dashboard's version already found: the dashboard
  window sets `isMovableByWindowBackground = true`, so a drag on a row is a
  drag on the window. That would make D3 a real fix rather than a label, and
  the same mechanism is what the island needs.
- [~] **F2. The logo.** Three directions sent 2026-08-02: the island solid,
  the island as an open stroke, and the island with a glance in it. Each at
  icon and menu-bar size and on a light Dock. Awaiting a pick, then the full
  icon set, menu-bar template and in-app mark.
- [x] **F3. Comment sweep.** The code still argues content cannot go on
  external monitors, a position withdrawn twice.
- [!] **F4a. Liquid glass and the calendar.** Clarity floored so it cannot
  reach unreadable, the pre-macOS-26 blur pinned dark, calendar permission
  picked up without a relaunch.
- [x] **F4b. Accessibility labels.** `label:` is required on both glyph
  buttons now, so the compiler asks at every new call site.
- [!] **F4c. Icon audit and shortcuts.** Done. One mechanical fault in 47 call
  sites (the sidebar toggle was off the icon scale entirely). Chat and Sessions
  gained shortcuts; the clipboard's existing one now opens with search focused,
  rather than adding a second binding and breaking the one-per-destination
  rule. **Six glyph collisions are recorded and deliberately unfixed** - the
  same symbol carrying two ideas in Shortcuts/Tools, Island/app-picker, and
  focus-streak/ambience. Each needs a chosen replacement, which is a design
  call, not an audit's.

## G. NotchBox parity - assessed 2026-08-02, and two of three are blocked

Scoped properly rather than assumed. What NotchBox has that Chalant does not:

- **Translate.** Not buildable as a native panel today. Apple's Translation
  framework is macOS 15, this app targets 14.0, and raising the floor drops
  every macOS 14 user for one panel. A webview pointed at a translation site
  would work and would be worse than the Ask surface already here. **Blocked
  on a deliberate decision to raise the deployment target.**
- **Web view.** Largely already here twice: the Chat tab IS a `WKWebView`, and
  the Links tab is an app and shortcut launcher. A third general browser panel
  would be a fourth door onto the same job. **Recommend not building.**
- **Battery panel.** Genuinely buildable and small: `SystemStatsController`
  already publishes level and charging, and time-to-empty is one IOKit call
  away. It is currently a glance, not a panel. **The only one of the three
  worth doing, and nobody has asked for it specifically.**
- **Snippets** already exist in the clipboard store.

## Later, explicitly

- Notion integration. Not in this branch.

## Verification owed

**`WHEN-THE-LID-OPENS.md`** is the checklist. Almost everything above shipped
without being seen: this machine was in clamshell for the whole build, so
there was no cutout to check the notch work against and the displays slept
through most of the rest.

## Not buildable as asked

- **Subscription OAuth** for Claude / ChatGPT / Gemini. Consumer subscriptions
  are not API entitlements.
- **OTA / hot update** in the React Native sense. A signed native macOS binary
  cannot be patched in place; it is replaced. D4 is the real version of this.
- **Different content per display.** One Spotify, one set of sessions. Same
  content, per-display shape.
- **Two islands expanded at once.** One WKWebView, one keyboard, one voice.
