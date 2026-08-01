# Chalant — island, sessions, displays

Living plan for `feat/island-sessions-displays`. Updated as work lands;
the PR description mirrors it.

## Standing rules for this branch

- **Design**: Apple's own bar. Load `better-design` guidance before any
  UI work (`get-ui-principle`, `get-ux-principle`), self-review against
  `get-review-rules` before presenting. Icons, spacing, margins,
  padding, drag feel — all held to the same standard as macOS itself.
- **Code**: ponytail. Climb the ladder, reuse before writing, shortest
  diff that actually works, one runnable check behind non-trivial logic.
- **Verification**: a visual change is not done until it has been seen.
  `screencapture -D <n>` per display; `screencapture -v` for motion.
  Never claim a UI fix from a green build alone.
- **Git**: atomic conventional commits on this branch, PR description
  kept current.

## Shipped

- Session discovery from Claude Code transcripts (no setup, no hooks)
- Settings moved out of the island into a dashboard window
- Four silent-data-loss bugs: stale voice result, ambience double-duck,
  activity question eviction, listener bind failure
- Global shortcuts (Carbon, no Accessibility prompt) + recorder UI
- Per-display config store (UUID-keyed) wired into `placement(on:)`
- Island expand animation, top-edge cusp, tab transition, text contrast

## Phase 1 — the island is wrong on monitors (highest priority)

The user's monitors still show a notch cutout where they want an island,
and nothing is adjustable.

1. **Rounded notch corners.** Remove the sharp points at top-left and
   top-right; follow the real MacBook notch curve. The eave meniscus is
   the mechanism; the corner treatment needs its own radius rather than
   a hard join.
2. **Displays pane.** Screen picker, style (Auto / Notch / Pill / Off),
   width, height, corner radius, inner padding. Store and geometry are
   already wired; `DisplayConfigStore.onChange` must call the window
   controller's `reposition()` or a slider will appear to do nothing.
3. **Island, not notch, on external displays.** `.auto` resolves a
   notchless screen to `.pill` today, but nothing uses the freed width.
   Full-width / true dynamic-island behaviour per screen.
4. **Bottom margin/padding of the island.** Called out specifically.
5. **Collapsed design.** New resting shape, plus what shows there.

## Phase 2 — layout the user owns

6. **Grid layout engine.** Rows/columns, drag-and-drop placement of
   elements inside the island. Define the element set (media, sessions,
   ambience, switcher, input, battery, calendar…) as placeable units.
7. **Presets.** Four favourites, saved and switchable.
8. **Collapsed priority.** User picks what shows when collapsed and in
   what order — per display, since displays already differ.
9. **Resize re-flow.** Changing island size lets the user rearrange
   rather than silently reflowing.

## Milestone in flight (loop-loop)

Running under `/loop-loop`: Opus architects, Sonnet composes, ponytail governs
code and review, and no product code is written before the founder approves a
plan doc. Artifacts live in `_bmad-output/loop-loop/`.

- **Displays not applying** — SHIPPED 2026-08-01, `56cd56c` + `7ffcafc`.
  Reviewed, 178 tests green. **Not yet seen on a screen** — the machine was
  in use, so the app was never relaunched. Summary:
  `_bmad-output/loop-loop/displays-not-applying-summary-2026-08-01.md`.
  Plan: `_bmad-output/loop-loop/displays-not-applying-plan-2026-08-01.md`.
  Three real faults: Width/Height are read by nothing in Pill mode (they feed
  `notchSize`, whose consumers are gated on `hasPhysicalNotch`, which is
  `style == .notch`); the island lives on one display and the pane marks none;
  and the collapsed island draws two shapes because the island's "should I
  draw" rule and the bead's "should I yield" rule are separate. Plus clamshell
  (lid shut, on power) as a first-class case: every screen resolves to pill.

- **Message an agent session from the notch** — feasibility CONFIRMED,
  architect drafting the plan. Pick a running session in the island, speak or type, and have
  that session act on it. The microphone moves to serve this. Whether an
  external process can put text into a *running* session is the open question;
  the Stop hook carries it: `hookSpecificOutput.additionalContext` lands at
  the end of a turn and the conversation continues so Claude acts on it
  (verified against the hooks reference). Delivery is turn-boundary only,
  never mid-run, which the interface has to be honest about. Session
  discovery also gets better: `claude agents --json` and `~/.claude/sessions/`
  give the live set with busy/idle, replacing transcript scraping.

## Phase 3 — sessions become useful

10. **Live activity per session** — what each one is doing right now,
    not just that it is alive.
11. **Click through to the session.** Focus the terminal/IDE window it
    is running in. Must handle VS Code and Cursor integrated terminals,
    not just Terminal.app.
12. **Codex and Cursor agent discovery** alongside Claude Code.
    Feasibility to be established before design.
13. **Claude logo on Claude sessions**; per-agent marks generally.
14. **Answer from the notch.** A stopped session asking a question
    surfaces in the island and is answerable there. The store already
    carries `Ask` with options; the write path back is missing.
15. **Live Claude animation** on the notch while sessions run, click to
    jump to them.

## Phase 4 — surfaces and polish

16. **Dashboard UI pass** against better-design. Current panes are
    functional, not beautiful.
17. **Calendar view** and every other panel raised to the same bar.
18. **Icon audit.** Every icon correct, meaningful and working.
19. **Shortcuts for everything**, clipboard history especially.
20. **Clipboard**: open from shortcut, searchable history.
21. **Liquid glass.**
22. **Logo.** Minimal, smooth, considered — replacing the current mark.

## Known bug

- A stray light/gradient terminates awkwardly under the album artwork
  in the media row (`MusicRow` radial gradient, `IslandRows.swift`).

## Later

- Notion integration: Notion AI agent for meeting capture and task
  creation. Not in this branch.

## Not buildable as asked

Claude / ChatGPT / Gemini **subscription** OAuth. Consumer subscriptions
are not API entitlements and no third-party flow bills against them. The
Chat tab already uses the real subscription through a logged-in webview;
inline island answers need a user-supplied API key.
