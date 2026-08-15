# Eval log

Numbers only. Part 1 §5: any change touching the transcription or text
pipeline reports corrections per 100 words before and after, on `--split dev`.

---

## 2026-08-12 — Part 0 §0.1 smoke test: the biasing path

**Question §0.1 posed:** does `AnalysisContext.contextualStrings` actually bias
anything, and on which module? Two independent research passes reported it is
silently ignored by `SpeechTranscriber` and honoured only by
`DictationTranscriber`. §0.1: *"If Path A's biasing also fails on this
hardware, both paths reduce to B and the decision is made."*

**Method.** One recording, `corpus/names.aiff`, 5.5s, synthesized so all four
runs get byte-identical audio: *"Ship Chalant to the Kizu group today, then
tell Aatram that FrictionLens and Gangothri are ready."* Five terms.
`tools/biasprobe`, macOS 27.0, en-US, file input rather than microphone.

| Path | Terms | Output |
|---|---|---|
| `SpeechTranscriber` no bias | **1/5** Kizu | Ship challenge to the Kizu group today, then tell Autram that friction lends in Ganga 3 are ready. |
| `SpeechTranscriber` WITH bias | **1/5** Kizu | *byte-identical to the line above* |
| `DictationTranscriber` no bias | **0/5** | Ship challenge to the keys who group today then tell Autum that friction, lens and gang of three are ready |
| `DictationTranscriber` WITH bias | **3/5** Aatram, FrictionLens, Gangothri | Ship challenge to the keys who group today then tell **Aatram** that **FrictionLens** and **Gangothri** are ready |

### Verdict: §0.1 is CONFIRMED on this hardware, and Path A survives

**`contextualStrings` does nothing on `SpeechTranscriber`.** Not "less", not
"sometimes": the two outputs are character-for-character identical. The API
accepts the strings and ignores them, exactly as reported.

**`contextualStrings` works on `DictationTranscriber`,** and the effect is
large. 0/5 to 3/5 on one five-second utterance: `Autum` → `Aatram`,
`friction, lens` → `FrictionLens`, `gang of three` → `Gangothri`. Native
biasing is real and it is not subtle.

So Path A does **not** collapse into Path B. M2's four-way experiment
(both modules × en-US and en-IN, on the real corpus) is still the deciding
run, and it now has a live contender rather than a formality.

### Caveats, stated so they are not forgotten

- **Synthesized speech, not a human, and not the founder's.** Part 0 §0.12
  makes the Indian-accented corpus non-negotiable for this decision precisely
  because engine rankings invert on accented input. This is a smoke test, not
  the experiment.
- **Neither path recovered `Chalant` or `Kizu` under bias**, and Path B got
  `Kizu` while biased Path A lost it. A bias list is not a guarantee, and §0.14's
  rejection guard (never replace a token that was already right) has visible
  motivation here.
- One recording, one locale, no repeats.

### Operational finding, worth as much as the result

**`DictationTranscriber` on `.shortDictation` emits a volatile result and never
finalizes**, even after `finalizeAndFinishThroughEndOfInput()`. The first
version of this probe filtered on `isFinal`, collected nothing, and reported
Path A as producing empty output twice, which reads exactly like a broken or
unsupported module. Both Path A rows above would have been recorded as 0/5 and
the decision would have gone the wrong way on a filter bug.

Any code consuming this module must keep the last volatile span. Assets are
also per-module: `SpeechTranscriber` being installed says nothing about
`DictationTranscriber`.
