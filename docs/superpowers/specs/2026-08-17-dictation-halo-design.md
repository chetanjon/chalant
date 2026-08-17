# The dictation strip, lit: Halo

**Date:** 2026-08-17
**Status:** design approved by the founder against a live mockup ("c is good"),
round three of three; spec for review
**Supersedes:** the "What is on the strip" and "Motion" sections of
`2026-08-16-dictation-strip-design.md`. Everything else in that spec (the slim
strip, no words, which display, the `.dictating` state, the seam) stands.

## What this is

While you hold left Option and talk, the island is a low black strip. Today
that strip carries a small accent dot, two ghost-grey labels, and a rim glow
and base pool that follow the microphone level. The founder's verdict on it:
basic and bland. Their brief for the replacement, in their words: **clean and
premium, and the user should feel like talking more.**

Three rounds of mockups established what that means and what it does not:

- Round one (a dot given a home, a horizon line, the Chalant mark as the dot):
  rejected. One idea three ways.
- Round two (droplet, bubbles, light flowing into the app icon, a scrolling
  trace, the notch as a beacon): rejected. Mechanisms, not a feeling.
- Round three designed the feeling, "being listened to", as one idea in three
  renderings. **The founder chose C, Halo.**

## The design, as approved

**The strip's edge is the light. Inside stays black glass.**

Four rules, all shared by the round-three family and all binding here:

1. **Soft light, never a mark.** No dot, no line, no icon on the strip. The
   only drawn thing is light with soft edges.
2. **Quick to answer, slow to let go.** The level the light follows rises fast
   when the voice arrives and decays slowly when it stops, so the strip feels
   attentive rather than jittery.
3. **The longer you talk, the more it fills.** The lit portion of the edge
   starts around the strip's centre and spreads toward the ends as the sentence
   goes on. It eases back during a pause and empties on release. Talking is
   rewarded.
4. **Letting go is a small satisfaction.** On release, a soft point of light
   gathers at the strip's centre and slips up into the notch as the strip
   closes: sent.

### What is on the strip

| where | what | style |
|---|---|---|
| the edge | the halo (below) | accent, white core |
| bottom left | the app the words are going into (display name) | `Fonts.micro`, `textSecondary` |

**Removed:** the centre dot, the base pool, the microphone name. The mic name
only ever mattered when a mic was dead, and a dead mic is now visible as light
that never blooms. The app name lifts from `textGhost` (45%) to `textSecondary`
(55%): it is the only word on the strip.

The strip's body stays pure black (no lit-ink gradient, no material). Height
68, width the display's configured island width, corner radius
`Island.radiusExpanded`. Unchanged.

### The halo

Three concentric strokes of the island's own shape, all driven by one smoothed
level `l` in 0...1 (see Motion), all in the current accent (silver by default,
which reads as white light; the album colour when music plays):

| layer | what | at silence (l = 0) | at full voice (l = 1) |
|---|---|---|---|
| outer glow | the shape stroked in accent, then blurred, spilling outward and inward | width 1.5, blur 12, opacity 0.45 | width 4.5, blur 42, opacity 0.95 |
| edge core | a thin white stroke on the edge with a small accent shadow | width 1.0, opacity 0.50, shadow 3 | width 2.2, opacity 1.0, shadow 11 |
| inner bleed | the shape stroked wide in accent, blurred, clipped to the inside | blur 8, opacity 0.10 | blur 38, opacity 0.35 |

**Spread.** The three layers are masked by a horizontal gradient centred on the
strip: fully lit at the centre, fading to nothing at half-width `h` of the
strip's width on each side, where `h = 0.18 + 0.42 * fill` (`fill` in 0...1,
see Motion). At `fill = 0` roughly the middle third of the bottom edge is lit;
at `fill = 1` the whole edge is.

**Breath.** While the strip is open and `Theme.Feel.current.ambient` is on, the
whole halo breathes between 85% and 100% opacity on a 4.2 s cycle (2.1 s each
way, ease-in-out, autoreversing, on Core Animation). This is the "go ahead" at
rest. Under Still (or system Reduce Motion) there is no breath; the halo still
follows the level, because that is the meter.

### Motion

The 30 Hz meter delivers a raw normalized peak (`DictationStripLevel.normalize`,
unchanged, `peak * 3.2` clamped). Two derived numbers are computed per tick and
published by `NotchViewModel`, and the view draws only from them:

- **`level`** (smoothed): `level += (raw - level) * min(1, dt * k)`, with
  `k = 14` when rising and `k = 3.2` when falling. Attack about 70 ms, release
  about 300 ms to settle.
- **`fill`**: while dictating, `fill = min(1, fill + level * dt * 0.42)`; when
  `raw < 0.05` (a pause) it also eases back by `dt * 0.12`. Reset to 0 when
  the strip opens. Roughly: five seconds of ordinary talking fills the edge;
  a two-second pause gives back a quarter of it.

Open and close use `Theme.Motion.island` like every other change of the
island's size. The halo and the label arrive after the pour settles (insertion
delayed ~0.18 s, `.opacity`), not during it, so nothing tears mid-pour.

**Sent.** When the state leaves `.dictating`, a soft light (white heart, accent
edge, ~28 pt, blurred) starts at the strip's centre and rises to the top edge
over 0.45 s while fading out, on `.easeOut`. Once. It runs during the closing
pour and is gone before the pour is.

### Silence still tells the truth

With a dead microphone the halo sits at its resting values, breathing if
ambient, and never blooms. That is a picture you can read from across the room,
which is the reason the strip exists (the deaf-mic evenings of 2026-08-12 and
2026-08-13). Nothing here weakens that signal; the resting halo is dimmer than
the resting rim was, and full voice is brighter, so the gap is wider.

## Architecture

Small. The seam, the state, the display rule and the surface protocol are
untouched.

- `Features/DictationStripLevel.swift`: `rim`, `pool` and `dot` go (their
  formulas belong to the removed elements). `clamp` and `normalize` stay. New:
  `struct Voice` (the smoother and the fill, `mutating func step(raw:dt:)`,
  `reset()`), `static func halo(_ level:)` returning the three layers' numbers,
  and `static func spread(fill:)`. All pure, all pinned by tests.
- `NotchViewModel`: `updateDictating(level:mic:)` steps a `Voice` and publishes
  `dictationLevel` (now the smoothed value) and a new `dictationFill`.
  `beginDictating` resets the voice. `micName` stays in `DictationInfo` (the
  ear can still hop; nothing renders it now).
- `Views/NotchRootView.swift`: the rim `.shadow` and pool overlay on the shell
  are replaced by a `DictationHalo` overlay (the three strokes, masked, breathing)
  and a `sent` overlay keyed on leaving `.dictating`. `dictatingContent` becomes
  the app name alone.
- `ChalantTests/DictationStripTests.swift`: the rim/pool/dot tests are replaced
  by tests for `Voice.step`, `halo`, and `spread`.

## Proof

- Unit: attack faster than release; fill grows while talking, eases in a
  pause, clamps to 0...1, resets; halo rest and full maxima; spread endpoints;
  clamping.
- Live: a Release build installed on the founder's Mac, then they dictate.
  The three things to see: the edge lights the instant they speak and settles
  after; the lit edge spreads over a sentence; the point of light rises into
  the notch on release. Then the thumb-over-the-mic test: the strip opens and
  stays at its resting halo. That is the pass.
- Perf: `sample Chalant 5` while holding and talking; `NSHostingView.layout`
  under the 10% bar. The halo is opacity, blur and mask on the shell, no
  layout, and the breath is a Core Animation repeat, not a TimelineView.

## Out of scope

Everything else on the two earlier boards (island, settings, landing page):
parked by the founder's word ("i only want to upgrade the voice dictating
thing"). Words on the strip: no, reaffirmed. The mic name: gone; if the founder
wants it back it returns bottom right in `textTertiary`.
