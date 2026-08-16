# The dictation strip

**Date:** 2026-08-16
**Status:** design approved by the founder against a live mockup; spec for review

## What this is

When you hold left Option to dictate, Chalant's island grows into a low black
strip that breathes with your voice, and closes when you let go. It replaces
the floating `ListeningPanel` that dictation draws today, which the founder
reported as invisible while talking.

The strip is the level meter. It draws no bars and no words.

## Why now

Three things the founder said tonight, all true and all this:

1. *"I just don't see visually if it's working or not."* The current panel is
   a plain black box parked under the notch of whichever screen is `NSScreen
   .main`, which on their desk is the external monitor, while their eyes are on
   the app they are dictating into. It also fades in 0.7 seconds and a short
   hold is shorter than that.
2. The merge design (2026-08-15) explicitly deferred "turning the listening
   panel into the island" so a failure could not be blamed on two changes at
   once. The merge is done and shipped. That reason is spent.
3. Chalant's whole visual identity is the island. Dictation is the biggest
   reason the app listens, and it is the one feature that opens a window beside
   the island instead of lighting it up.

## The design, as approved

The founder chose these from a live mockup, one question at a time:

- **The slim strip**, not the full listening surface voice commands use.
- **No words while talking.** Only the level. What it heard arrives in the
  document.
- **The island itself is the meter.** No bars. The strip's rim glow and a pool
  of light at its base swell with the voice; one small accent dot at the centre
  grows with them. Silence looks like silence, which is the deaf-mic signal
  that has cost whole evenings, now visible without a word.

### What is on the strip

Three things, laid out left / centre / right along the bottom edge:

| position | content | style |
|---|---|---|
| left | the app the words are going into (its display name) | `Fonts.micro`, `textGhost` |
| centre | one dot, `accent`, 6pt at silence growing to 12pt at full level, with a matching glow | the only symbol |
| right | the live microphone's name | `Fonts.micro`, `textGhost` at 0.8 |

Height 68pt open, the collapsed island's own height at rest. Width is the
island's configured width for that display. Corner radius `Island.radiusExpanded`.

### What is deliberately not on it

- **Words.** Chosen. The reason: nothing to read while trying to think and talk.
- **A finish hint.** The strip only exists while the key is down; letting go is
  the instruction.
- **A close button.** Same reason. There is no session to cancel that
  releasing the key does not cancel.
- **Any second symbol.** One dot, one rim. Law 3, one symbol per meaning.
- **A waveform.** Law 3 again; the founder rejected a waveform glyph before.

### Motion

One curve, `Theme.Motion.island`, for the open and the close, like every other
change of the island's size. The level drives three things through one number
in `0...1`:

- rim glow: shadow radius `2 + level * 22`, opacity `0.10 + level * 0.55`, in
  the accent
- base pool: a radial gradient from the bottom centre, opacity `level * 0.22`,
  in the accent
- dot: diameter `6 + level * 6`, glow radius `4 + level * 14`

Level updates on the existing meter timer (`DictationController.startMeter`)
and animate with the same 0.1s ease-out the voice-command bars use, so it
tracks speech without flicker.

`Theme.Feel.current.ambient` off: the rim and pool still follow the level (that
is the meter, not decoration) but there is no idle shimmer of any kind.

### Which display

**The strip opens on the display showing the app being dictated into**, not on
`NSScreen.main` and not on the pointer's display. Rationale: the user's eyes
are on the field they are typing into. That is where the strip has to be to be
seen at all, and it is the fix for "the island is not visible."

Resolution: `NSWorkspace.shared.frontmostApplication` is already captured at
key-down as `InsertionTarget`. Its focused window's screen is found through
`CGWindowListCopyWindowInfo` for the target PID (frontmost window with a
non-zero bounds), mapped to a `CGDirectDisplayID`. Fallback, in order: the
display the pointer is on; `NSScreen.main`; any screen. If that display's
island style is `.off`, the strip opens on the fallback rather than nowhere.

This is the one place the strip's rule differs from voice commands' `default
OwnerDisplay()`. Voice commands are addressed to the island; dictation is
addressed to another app. Different job, different display rule.

## Architecture

### The seam

The island already has a `.listening` state with an owner display and a
`quietTheRoom()` that ducks music and ambience. Dictation gets a **sibling
state, not a reuse**: `.dictating`. Reusing `.listening` would run
`voice.begin()`, which starts `VoiceController`'s own recognizer, and two
engines listening at once is exactly the doubled-text failure the merge exists
to end.

`NotchViewModel` gains:

```swift
enum State { case collapsed, expanded, listening, dictating }   // dictating added

/// Driven by DictationController's meter timer. 0...1.
@Published var dictationLevel: CGFloat = 0
@Published var dictationTarget: (appName: String, micName: String)?

func beginDictating(into appName: String, on display: CGDirectDisplayID?)
func updateDictating(level: CGFloat, mic: String?)
func endDictating()
```

`beginDictating` sets the owner display, calls `quietTheRoom()`, and sets
`state = .dictating`. It does NOT touch `voice`. `endDictating` restores the
room the same way `endListening` does, without the finalize path.

`state(_:expandedOn:face:)` treats `.dictating` exactly as it treats
`.listening` (an owned expansion), which is what makes the strip appear on
exactly one display and every other face read collapsed.

### The view

`NotchRootView` renders a new `dictatingContent` when `model.state ==
.dictating`. It is small: an `HStack` of the three items above, on the bottom
edge, with `.padding(.top, face.contentTopReserve + Space.notchClearance)`
like the listening surface. The rim glow and base pool are drawn by the
existing island shape's shadow and an overlay, driven by `model.dictationLevel`.

`IslandShape` needs no change: it already animates all five lanes on the one
curve. The strip is a short expansion, nothing more.

### The wire

`DictationController` today owns a `ListeningPanel` and calls `panel.show()`,
`panel.update(level:text:)`, `panel.hide()`. Those three calls become calls
into `NotchViewModel` through a small `@MainActor` protocol so `Dictation/`
does not import the app's view model directly:

```swift
/// In Dictation/, ungated. What dictation needs from whatever shows it.
@MainActor protocol DictationSurface: AnyObject {
    func show(into appName: String, mic: String?, on display: CGDirectDisplayID?)
    func update(level: CGFloat, mic: String?)
    func hide()
}
```

`Chalant/Features/Dictation.swift` (the one file that already bridges the two
worlds) hands `DictationStack` a surface backed by `NotchViewModel`. The
`Dictation.shared` singleton gets a `surface` property set at launch by
`ChalantApp` where the controller is created.

`ListeningPanel.swift` is deleted. Not kept behind a flag: the merge design's
reason for keeping it is spent, and a second listening surface is exactly the
class of leftover this app has paid for before (two mic layers, two landing
pages).

### App name

`InsertionTarget` carries only a bundle ID. The strip wants "VS Code", not
`com.microsoft.VSCode`. `NSRunningApplication(processIdentifier:)?.localizedName`
at key-down, falling back to the bundle ID's last component. Cheap, and it is
read once per hold.

## What this does not change

- The hotkey, the audio engine, the recognizer, the text pipeline, insertion.
  None of them know the strip exists beyond three calls that already existed
  as `panel.*`.
- Voice commands' listening surface. Untouched. It keeps its bars, its words,
  its finish hint. The two doors stay separate, as decided 2026-08-13.
- Per-display island styles. A screen set to `.off` still gets no island; the
  strip goes to the fallback display.

## Testing

Pure:
- `NotchViewModel.state(_:expandedOn:face:)` for `.dictating`: owned on one
  display, collapsed everywhere else. Same shape as the existing `.listening`
  tests.
- The display-resolution rule as a pure function over `(targetDisplay,
  pointerDisplay, main, any, offDisplays)`, with the fallback order pinned.
- Level to visual mapping: 0 gives the resting rim, 1 gives the maxima above.
  A test that pins the three formulas, so nobody retunes one and not the others.

Manual, dated in `Dictation/MANUAL-TEST-LOG.md`, founder's hand on the key:
- Hold on the external display with the app there: strip on that display.
- Hold with the app on the Mac's screen: strip there, not on the monitor.
- Hold with the mic muted or lid closed: strip opens and stays dark. That is
  the pass condition, not a failure.
- 0.7s hold: strip visibly opens and closes even with nothing heard.
- Music playing: ducks on hold, restores on release.

## A settings mismatch found on the way, not fixed here

The founder's stored config sets **both** displays to `pill`, including the
MacBook's own screen with a real notch. They said they wanted a notch there.
Automatic (the default) follows the hardware and would give exactly that. It is
two clicks in Settings, Displays. Noted so it is not mistaken for a bug in this
work; not changed, because a user's settings are theirs.

## Out of scope, named so it stays out

- Words in the strip. Chosen against.
- Toggle mode (Stage 1 S6). The strip works for hold; toggle would need a
  visible end control, which is a different strip.
- Any change to the voice-command surface.
- Instant-then-swap insertion. Next, and separate.
