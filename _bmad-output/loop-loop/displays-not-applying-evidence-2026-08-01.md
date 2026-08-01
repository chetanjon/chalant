# Evidence: Displays pane edits do not reach the island

INNER-loop step 2 (RCA). Gathered 2026-08-01. This is the input to the
dependency graph, the edge-case pass, and the architect. It records only what
was **observed**, and says plainly where it stops.

## The report

Founder, with a screenshot of the Displays pane: "updating anything here is not
updating the changes to the dedicated part here."

## What the pane looks like (confirmed, screenshot)

The pane renders correctly and completely: screen picker, Style
(Automatic / Notch / Pill / Off), Width, Height, Corner radius, Inner padding,
Reset. Values shown are the defaults (196 / 34 / 16 / 16). The Style note reads
"Automatic follows the hardware, and picks pill here."

This is the first time this pane has been seen on a screen. It was built blind.

## Confirmed facts

1. **Four displays are attached**, not three - the pane's list was scrolled.
   Obtained by running CoreGraphics directly, outside the app:

   | Display | safeArea top | logical | stable key (UUID) |
   |---|---|---|---|
   | DELL S2725QC (2) | 0 | 2560x1440 | EA7695E6-48C3-47A2-8E97-84DE9DE983FA |
   | Built-in Retina Display | **38** | 2056x1329 | 37D8832A-2D66-02CA-B9F7-8F30A301B230 |
   | DELL S2725QC (1) | 0 | 2560x1440 | DE4F3869-003F-4193-909D-6B0009142DE6 |
   | P2718EC | 0 | 2560x1440 | EAF6F676-2477-4BAC-856C-57DB5FBD21A7 |

2. **The island lives on the Built-in Retina Display.** A temporary probe in
   `placement(on:)` reported `style=notch inset=38.0 name=Built-in Retina
   Display`. The probe has been removed and the tree is clean.

3. **`displayConfigs` in UserDefaults was `{}`** (`0x7b7d`) after the founder
   had been interacting with the pane. Nothing was persisted.

4. **`onChange` IS wired.** `NotchWindowController.swift:305` sets
   `viewModel.displays.onChange` to `reposition() + rebuildSlivers()`.

5. **`reposition()` only ever re-places on `notchScreen`** - the one display
   the island is currently on. It reads `displays.config(for: thatScreen)`.

6. **Writing a config for the Built-in display directly into defaults and
   relaunching did NOT produce the forced geometry** (style pill, width 300).
   The island on the built-in remained a small rounded shape roughly 40pt wide,
   nothing like a 300pt pill. Inconclusive as to mechanism - see below.

## The two live hypotheses

Both are consistent with everything above. They are **not** yet separated, and
this matters because they need different fixes.

**H1 - the pane's writes never reach the store.** `displayConfigs` was `{}`
after interaction. If `set(_:forKey:)` is not being called, or is called with a
key that does not match, nothing persists and nothing can ever apply.

**H2 - writes land but are invisible, because the island is on one display.**
The island lives on the Built-in. Editing DELL or P2718EC changes stored config
for a screen the island is not on, so nothing moves and nothing says why. The
pane presents four editable displays as if each were live.

H2 is a real design flaw regardless of whether H1 is true: the pane gives no
indication which display the island is actually on.

## Also unexplained

Fact 6 argues something in the store -> geometry path is not applying either,
since a hand-written config for the island's own display produced no visible
change. That is a third possible fault and must not be assumed away.

## Known related defect (separate, already evidenced)

The collapsed island draws **two overlapping shapes** on a notchless display.
Confirmed by quitting Chalant: both shapes vanished, so both are ours. Root
cause identified by reading: `rebuildSlivers()` yields the island's own display
only when `state != .collapsed || glanceToast != nil`, but `monitorTucked` was
changed so the collapsed island now also draws whenever it has something to
say. Two rules for one fact; both draw. A fix was drafted and reverted
unapplied, to go through the approval gate.

## What has NOT been established

- Whether `set(_:forKey:)` is reached at all when a slider moves.
- Whether the key the pane writes under matches the key `placement(on:)` reads.
- Why a hand-written config for the island's display produced no change.

Anything beyond this is speculation and is left to the architect to plan
against, not to assert.
