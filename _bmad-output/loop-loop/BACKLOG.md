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


- [ ] **A1. Match the real hardware by default.** Default size and shape should
  be the machine's actual notch, not invented numbers, unless the user changes
  them. Today `Config` ships 196x38 for everything.
- [ ] **A2. Hide under the physical notch at rest, expand on hover.** On a
  MacBook the collapsed island should be indistinguishable from the cutout.
- [ ] **A3. Remove the arc at the bottom edge.** Use the MacBook notch's own
  corner radius. "make it clean and proper."
- [ ] **A4. Padding, margins and type inside the island.** Content sits too
  close to the borders. Needs a proper spacing pass, not a nudge.
- [ ] **A5. Expanded size is adjustable from the dashboard.** Separate from the
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
- [~] **B8. Cursor and Codex** get the same notifications and hooks as Claude
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
- [!] **D3. Arrangement drag is broken** - dragging a row moves the whole
  window. Mark the feature "coming soon" for users for now, then build the
  real thing (see F1).
- [ ] **D4. Update button** that downloads, installs and relaunches. GitHub
  Releases is the source of truth; the daily check already exists.

## E. Media (2026-08-02)

- [!] **E1. The wrong app icon.** Audio playing from Dia shows Chrome's icon.
- [ ] **E2. The media-row microphone** has no obvious purpose where it sits. It
  drives Chalant's own voice commands (reminders, timers, notes, dictated
  texts). Either move it beside Ask where speaking makes sense, or remove it
  and leave the hotkey and long-press. Founder to decide; recommendation is
  move.

## F. Bigger, already agreed

- [ ] **F1. Drag and drop inside the island.** The founder corrected me twice:
  arrangement should happen on the real surface, not only as a list in the
  dashboard. Needs one decision first: does a drag on one display rearrange
  that display, or all of them? Recommendation: all, shared.
- [ ] **F2. The logo.** "looks ugly", wants minimal and smooth.
- [ ] **F3. Comment sweep.** The code still argues content cannot go on
  external monitors, a position withdrawn twice.
- [ ] **F4. Icon audit, shortcuts for everything, liquid glass, calendar and
  the other panels raised to the same bar.**

## G. Later, explicitly

- Notion integration.
- NotchBox parity: snippets, web view, translate, per-style pickers.

## Not buildable as asked

- **Subscription OAuth** for Claude / ChatGPT / Gemini. Consumer subscriptions
  are not API entitlements.
- **OTA / hot update** in the React Native sense. A signed native macOS binary
  cannot be patched in place; it is replaced. D4 is the real version of this.
- **Different content per display.** One Spotify, one set of sessions. Same
  content, per-display shape.
- **Two islands expanded at once.** One WKWebView, one keyboard, one voice.
