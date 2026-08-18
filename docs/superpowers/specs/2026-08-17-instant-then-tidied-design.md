# Instant, then tidied in place (with smart formatting)

**Date:** 2026-08-17 (evening)
**Status:** founder said "go ahead, start building" against the plan below; spec
written as the build begins

## What the founder asked for

Their words, dictated through the strip: *"if I am dictating to Wispr Flow or
Superwhisper it will remove the ums and the gaps and all of the mistakes that
humans make, and if I was giving you a list it'll make a list by bullet points.
That is how we should be doing that and more."* And, an hour earlier, on the
tidy pass that already did part of this: *"the text is coming after two, three
seconds"*, which is why 1.17.1 shipped with tidy off by default.

So the bar is Wispr's result without Wispr's wait. The on-device model needs
about a second per sentence and prewarming does not help (measured, fresh 0.88 s
vs prewarmed 1.03 s median). The wait cannot be removed from the model, so it
is removed from the user: **the words land instantly, and the tidied version
replaces them in place a second later.**

## The design

### Track 1: instant, then tidied in place

1. On release, exactly as today: finalize, deterministic pass (fillers, doubled
   words, guardrail), **insert at once** (~0.1 s). Nothing changes here.
2. If "Tidy what I said" is on (and it is on again by default), the model pass
   starts in the background the moment the insert lands.
3. When the model returns, `SwapPolicy` decides. The swap happens only if ALL
   of these hold:
   - the tidied text differs from what was inserted (after trimming);
   - the tidied text passed `FidelityGuard` (already true, the polisher ships
     raw chunks otherwise);
   - the insert landed by pasting (tier 1 System Events or tier 2 CGEvent),
     because the swap undoes a paste; a clipboard-only outcome never swaps;
   - **the user has not typed or clicked since the insert** (a global monitor
     for keyDown / mouseDown runs only between the insert and the swap);
   - the front app is still the target app;
   - no more than **4 s** have passed since the insert (later than that the
     user has moved on, and a document changing under them is worse than a
     stray "um");
   - the target app is not on the no-swap list: terminals (Terminal, iTerm2,
     Warp, Ghostty, kitty, Alacritty, WezTerm), where ⌘Z is not undo and a
     second paste would double the text, and the editors that carry a
     terminal inside them (VS Code, Cursor, Zed): the founder dictates into
     the Claude Code prompt in VS Code's terminal panel, Electron exposes
     nothing through Accessibility to tell that pane from the editor, and
     doubled text there is the one outcome this design must never produce.
     Their editor buffers lose the swap for it.
4. The swap is **⌘Z then ⌘V** through the same System Events path the insert
   used, with the tidied text on the pasteboard and the pasteboard restored
   after, exactly like an insert. ⌘Z undoes precisely the pasted run in every
   editor that has undo (native, Electron, browsers, Slack, Notes, VS Code);
   that is why the mechanism is undo-then-paste rather than selecting back
   N characters (slow, visible, and wrong across soft line breaks) or the
   Accessibility API (returns nothing in Electron and web views, exactly where
   the founder dictates).
5. Nothing on the strip changes for this: the strip is closed by the time the
   swap happens. The "sent" light stays honest, because the words did land.

If any condition fails, the raw text simply stays. It was correct text; the swap
is an upgrade, never a repair.

### Track 2: smart formatting, in the same tidy pass

The prompt gains formatting rules, and the guard learns that formatting is not
a fidelity error:

- **Spoken lists become lists.** "first… second… third", "one… two… three",
  "number one… number two", "bullet point…" or an enumeration of three or more
  short parallel items → one item per line, with "- " for an unordered list and
  "1. 2. 3." when the speaker numbered them. Two items are prose, not a list.
- **Paragraphs.** "new paragraph" / "new line" spoken → a line break; a long
  dictation that clearly changes subject → paragraph break. Conservative.
- **Numbers, dates, emails, URLs written the way you would type them** is
  deferred: `FidelityGuard.numbersSurvived` compares digits and would need a
  number-word-to-digit equivalence first. Not tonight; noted.
- **Lists stay whole.** Chunking at ~40 words would split a spoken list across
  chunks and format them inconsistently, so an utterance with list cues under
  ~110 words is sent as one chunk.
- **Guard.** Before its checks, `FidelityGuard` strips list markers ("- ", "• ",
  "1. ", "2) ") from line starts and treats newlines as spaces, so a numbered
  list does not fail "a number appeared that was not said" and a bulleted one
  does not fail the content overlap.

### The switch

"Tidy what I said" defaults **on** again, and its note says what it now does:
"Your words land at once. About a second later they are tidied in place: ums
and false starts gone, punctuation fixed, spoken lists made into lists. If you
have started typing, nothing is touched." Off means the raw text is never
revisited.

## Architecture

- `ChalantDictationCore/Insert/SwapPolicy.swift` (new, pure, tested): the
  seven conditions above as one function.
- `ChalantDictationCore/Text/CleanupPrompt.swift`: formatting instructions,
  `looksLikeList(_:)`, list-aware chunking. `FidelityGuard`: marker/newline
  normalisation before the checks. Both tested.
- `ChalantDictationApp/Insert/InsertionChain.swift`: `replaceLastInsertion(with:
  into:)`, ⌘Z + ⌘V via System Events with the pasteboard guarded.
- `ChalantDictationApp/UserActivityWatch.swift` (new): global keyDown/mouseDown
  monitor with a start/stop and a `sawActivity` flag.
- `DictationController.keyUp`: after a successful insert, if tidy is on, start
  the watch and a detached polish task; on return, ask `SwapPolicy`, then
  replace. Logs lengths and the reason for keeping, never content.
- `Cleanup.isEnabled` default true; Settings note updated.

## Proof

- Unit: `SwapPolicy` each condition; `looksLikeList` on real spoken lists and
  on prose with numbers; guard accepts "- " and "1. " lines and rejects the
  same content wholesale replaced; chunking keeps a short list whole.
- Live: the founder dictates a plain sentence (lands instantly, tidied a second
  later, only fillers vanish), a list ("first… second… third"), and a sentence
  they immediately keep typing after (nothing swaps). Terminal: nothing swaps.
- Log lines: `swapped after Xs` / `kept: <reason>` per utterance.
