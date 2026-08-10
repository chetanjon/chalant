# Chalant, the premium finish

**Date:** 2026-08-10
**Approved by:** the founder, via the mockup page
(claude.ai/code/artifact/34eeb99f-f6fc-4403-8209-2b7c17f069e2, version
"ambience-volume-comes-and-goes"). Their own reference mockup image set the
direction; four candidate directions were shown first and they chose this
blend: Still water's calm and air with Instrument's typographic discipline,
moved by Liquid morphs.

## Goal

Make the whole app feel premium without adding loudness: more air, typography
doing the work, one liquid motion signature, and every surface (island,
Settings, welcome tour) speaking the same language. One new feature rides
along: weather on Today.

## The look

All values land as named tokens in Theme.swift (no raw sizes outside it, the
existing grep rule). The island stays flat pure black: no borders, no glow, no
translucency (standing rule since 1.0.1).

- **Air separates zones.** The divider hairlines are GONE inside the island
  (founder's call). Section spacing roughly doubles; the expanded island uses
  ~30pt side padding and ~40pt corner radius.
- **No pills anywhere.** Active means white; inactive means dim. The ambience
  chip highlights, tab highlights and settings sidebar highlight all drop
  their background bubbles.
- **Type:** titles 18 semibold with slight negative tracking, body 15, dim
  secondary. Every number that aligns (times, dates, temperatures) is
  monospace with tabular digits.
- **Icons:** thin outlines (~1.3pt stroke), no filled variants except the
  transport glyphs.
- **Music zone:** art 56pt rounded 14; title over artist; thin transport
  (previous, pause/play, next) right of the titles; **media volume (speaker +
  thin slider) sits beside the transport and is always present while
  something plays.** The progress bar spans the full content width at 2pt,
  played portion bright; beneath it, elapsed on the left and **time remaining
  on the right as -M:SS**, both mono 13 dim.
- **Ambience:** text-only chips of the existing sounds (brown, white, pink,
  rain, fire, café), active chip white semibold, others dim. **The ambience
  volume (speaker + slider, right-aligned) exists only while a sound is
  playing** and pours in and out with the liquid signature. The mockup's
  "Ocean" chip was filler; no new sounds in this work.
- **Tab row:** thin outline icons only, no labels, exactly as the approved
  mockup: active is white, others faint, gear far right.
- **Today:** the date is the headline (18 semibold); **weather sits on the
  right of the same line** (thin sun/sky glyph, temperature, one word of
  sky), dim; reminders/calendar lines below in dim; empty state stays
  "Nothing due".

**Design laws** (apply to every future surface):
1. One symbol per meaning: the speaker icon is the only face of volume.
2. Active is white, never a pill.
3. Air separates; lines are a last resort.
4. Numbers are monospace.

## The liquid

One motion signature for the whole app: the island pours between sizes
(collapsed pill, expanded, per-tab heights) along one damped curve, content
fading in staggered during the pour. No popping, no bounce (damping >= 0.9
doctrine), tab switches pour between content heights.

Constraints carried from the app's own history:
- Respects the Feel setting (Serene default) and system Reduce Motion (clamps
  to still).
- Never animate `.frame` inside a high-rate TimelineView (the NowPlayingBars
  lesson). Fixed-size canvases or scale effects only.
- The island's height stays content-measured (`model.expandedSize` via the
  preference key) and must keep feeding the hover zones correctly mid-pour.
- Ships only after `sample Chalant 5` shows NSHostingView.layout() under 10%
  of main-thread samples and idle CPU stays at current levels (~0.6%).

## Weather on Today

- Source: Open-Meteo, keyless and free, called with approximate coordinates
  from CoreLocation. No account, no API key, no tracking.
- Refresh: on launch, on wake, then ~every 30 minutes. Offline, the cached
  reading shows until it is 3 hours old, then the line goes away.
- If location permission is declined or unavailable: the line simply is not
  there. No error states on the island.
- Unit follows the system locale (F/C).
- A "Weather" switch appears in Settings, What shows (full-customization
  doctrine); default on.
- The Privacy note gains one honest sentence: weather means asking a weather
  service for the sky above your approximate area; nothing else leaves the
  Mac.

## Settings and first-run, same skin

- The Settings window keeps its exact layout and sections; only the finish
  changes: boxed cards become hairline-separated rows (hairlines are allowed
  here, they are list furniture, not zone dividers), group labels go mono
  uppercase, sidebar selection becomes white-text-no-pill, toggles restyle
  thin and monochrome.
- The welcome tour cards adopt the same tokens.
- No settings move, appear or disappear (beyond the new Weather switch).

## Scope guards

- Sessions and Chat stay dark-shipped and untouched; their hidden views may
  inherit token changes passively but no work is spent on them.
- No new sounds, no new tabs, no layout rearranging.
- No version bump, merge or release without the founder's word.

## Build order and proof

Four rounds, each proven before the next starts:
1. **The look**: token pass + island restyle. Proof: side-by-side screenshots
   against the mockup page; full suite green.
2. **The liquid**: the pour. Proof: screen recording feel-check by the
   founder, CPU sample under the perf bar, hover zones verified mid-pour.
3. **Weather**: service + line + setting + privacy copy. Proof: TDD on
   decoding/caching/formatting; line appears/disappears correctly with
   permission states.
4. **Settings + welcome**: the re-dress. Proof: screenshots of every settings
   page against the mockup's settings section.

New logic gets tests first (remaining-time formatter, weather decode/cache,
ambience-slider visibility rule). All 587 existing tests stay green
throughout.
