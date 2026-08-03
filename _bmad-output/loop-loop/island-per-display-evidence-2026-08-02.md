# Evidence: one island that travels, versus an island on every display

Gathered 2026-08-02 against the build launched from `47dc060`, seen on screen.

## What the founder reported

With screenshots: "the pills show up but only one monitor and not on all 3 of
them", "these three notches show up in the middle of nowhere on the screen",
"the pill collapsed should show the activity like claude session if that is
active and spotify songs if that is active", and separately "weirdly the notch
and the pill both show up".

## First, what was NOT real

The founder's Displays screenshot showed Width at 420pt under a style resolving
to Pill, with nothing changing. That control was deleted in `7ffcafc`. The
running process had been launched at **15:28**, before that commit landed at
roughly 16:15 and before the messaging work at 17:38. They were driving a build
three commits stale. Rebuilt and relaunched before anything else was judged.

## What is real, seen on screen after the relaunch

Three displays captured with `screencapture -D`, cropped to the top centre.

- **DELL (d2)**: one dark island shape, top centre. Correct, and only one shape
  - the two-shape defect fixed in `56cd56c` is gone here.
- **Built-in (d1)**: a small bead, sitting over the title bar of a window
  reading "SKILL.md - offseason_workspace". No menu bar under it, so it reads
  as a black lozenge floating on somebody's document.
- **P2718EC (d3)**: the same small bead.

So the app is behaving exactly as designed, and the design is the complaint.

## The architecture, and why the report follows from it

There is **one** island `NSPanel`. It lives on `notchScreen` and travels
between displays on hover. Every other display gets a `sliverPanel` - a bead
116x20 - whose entire job is to be a findable handle that summons the island
over. `NotchWindowController.sliverRoom` and `rebuildSlivers()` are that
mechanism, and `wearsBead` decides which displays get one.

Every part of the report falls out of that single fact:

- "only one monitor" - correct, by construction. One panel exists.
- "in the middle of nowhere" - the bead is deliberately small and content-free.
  On a display whose top edge is covered by a window rather than a menu bar, a
  small black lozenge with nothing in it has no context and reads as debris.
- "the collapsed pill should show the Claude session and the Spotify song" -
  the bead cannot. It is 116 points wide and renders `SliverHint`, which draws
  no content at all. Only the island renders rows, and the island is elsewhere.

## The decision this forces

This is not a bug to patch. It is a design the founder has now rejected twice,
and the fix is architectural: **an island per display rather than one island
that travels.**

That means `sliverPanels` stops being a different kind of thing and becomes N
island panels, each with its own collapsed state, its own resolved style from
`DisplayConfigStore`, and its own content. `travel(to:)`, `travelDisplayID`,
`notchScreen` and `homeScreen` largely dissolve: there is no "the island's
display" any more, so the "island here" badge and the "Move island here" button
built in `7ffcafc` become meaningless and must come out.

Costs to be honest about, because the current design exists for stated reasons:

1. **"We can't show anything on external monitors"** (user, 2026-07-22) - the
   original reason content was stripped on monitors was that it sat on top of
   somebody's window. That objection was about a screen pretending to be a
   MacBook. The founder has since asked twice for the opposite, most recently
   naming the exact content they want there. The old constraint is withdrawn,
   and the code comments asserting it need withdrawing with it.
2. **N panels cost N hosting views.** Each island is a SwiftUI hierarchy
   observing the same controllers. Four displays means four live views
   re-rendering on every music tick.
3. **Which display owns the expanded island?** Hovering one must not expand
   four. Expansion has to become per-panel state rather than the single
   `viewModel.state` everything currently reads.

That third point is the real work. `NotchViewModel.state` is one value read by
every view, and per-display expansion means it can no longer be one value.

## Also reported, separately, and not part of the above

| # | Report | Nature |
|---|---|---|
| R1 | Arrangement should be drag-and-drop **inside the island itself**, not only a list in the dashboard | The dashboard list shipped; the founder wants direct manipulation on the real surface |
| R2 | Remember the last opened tab and reopen to it | Small, additive. NotchBox has the same switch |
| R3 | Dashboard sidebar toggle sits left in one place and right in another | Real inconsistency, seen in the founder's own screenshots |
| R4 | The notch and the pill both showing | Fixed in `56cd56c`; confirmed single-shape on d2 after relaunch. Needs re-checking on the built-in |
| R5 | NotchBox feature parity (clipboard with snippets, web view, translate, battery, per-style pickers, shortcuts for everything) | A backlog, not a defect |

## Founder feedback on the W-A pill, 2026-08-02, with two screenshots

Two captures of the same feature on different displays, and the contrast is
the whole point.

- **Rejected**: a bare 28pt waveform, nothing else.
- **Approved, verbatim "this version is good"**: `... The Cat and the Dra... 2`
  - the song title beside the wave, plus the agent count.

The difference is not a setting. `leftWingNeed` returns 156 when
`showsSongBeside` holds and 28 for the bare wave, and `showsSongBeside`
requires `islandStyle == .pill`. So the approved version is what a **pill**
already does and the rejected one is what everything else does. The founder's
own words alongside it - "rendering in the monitors should be according to the
settings" - are the same request from the other end: W-C is what puts a real
pill on every display that resolves to one, and the approved content follows
automatically.

**So the collapsed content rules are now signed off and must not be changed.**
Anything that alters what a resting pill shows is a regression against an
explicit approval.

Two adjustments remain, and both are presentation only:

| # | Feedback | Change |
|---|---|---|
| F1 | "the pill placement is too top" | A pill floats and should clear the top edge; a notch dresses hardware and must touch it. A small top gap for `.pill` only, never for `.notch`. |
| F2 | "add a little very very little bit height to the default" | `DisplayConfigStore.Config.height`, currently 34. A small bump, still inside `heightRange` 20...60, and the per-display slider still overrides it. |

F2 is a **default**, so it only moves displays with no stored height. Anything
already tuned by hand keeps its value, which is correct and worth stating
because it means the founder's own displays may not visibly change.

## What has NOT been established

- Whether per-display expansion can reuse `NotchViewModel` with a keyed state
  map, or needs a view model per panel. This is the crux of the estimate.
- Whether four hosting views cost anything measurable. Nothing has been
  profiled; the concern above is reasoning, not measurement.
