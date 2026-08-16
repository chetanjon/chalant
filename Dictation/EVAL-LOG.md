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

## 2026-08-15 — first baseline, on the founder's voice

**60 of the 150 recorded.** Sets C (semantic torture, 30, locked) and D
(code-switched Telugu/Hindi-English, 30, six sentences said three times each).
Sets A, B and E are not recorded: they must be spontaneous and the app cannot
yet keep its own audio.

Corpus lives at `~/Desktop/chalant-corpus`. Built-in MacBook Air microphone,
lid open, normal room, nothing else listening.

### The numbers

| locale | English (torture, locked) | code-switched (dev) |
|---|---|---|
| **`en_US`** | **20.00** | 102.34 |
| `en_IN` | 22.67 | 103.12 |
| `mul_IN` | 42.67 | **46.88** |

Corrections per 100 words. **`en_US` is 2.1x better on English; `mul_IN` is 2.2x
better on code-switching. Neither wins both**, so "make `mul-IN` the default"
is not supportable as stated. It is a routing decision, or it waits for ITN.

Latency from the same day's manual test, not from this corpus: finalize
0.043-0.207s, insert 0.007-0.092s warm, roughly **0.05-0.23s key-release to
visible**. Part 0 §0.5's 1.45s/2.2s does not reproduce.

### Where the English errors actually are

```
number        25  (56% of all errors)
other         18  (40%)
proper_noun    2  (4%)
```

**More than half of what is left in English is numbers**, and the failures are
specific rather than diffuse:

| said | wanted | got |
|---|---|---|
| nine thirty to ten fifteen | `9:30 to 10:15` | `93, 932, 1015` |
| nine ninety nine ... ninety nine | `$9.99 ... $99` | `999 ... 99` |
| forty attendees, not fourteen | `40 attendees, not 14` | `4 tea attendees, not 14` |
| three fifteen, not three fifty | `3:15, not 3:50` | `315, not 350` |

**Times and currency are the worst classes.** Apple normalises bare quantities
well ("fifteen" to "15") and falls apart on structured ones. That is M3's
target, and it is worth roughly half the English error rate.

Also caught by the locked set, and it is the whole product thesis in one line:
`jonnalagadda8800@gmail.com` came back as `Junalagadda 8800@gmail.com`. **The
founder's own surname**, in the set that gates the fidelity claim.

And the semantic torture set did its job on its first run: `Email Sarah about
it, not Sara` came back as `not Sarah`. A meaning-changing name collapse, which
is exactly the failure class the set exists to catch.

### What this baseline is NOT

- **Not the full corpus.** 60 of 150, and the two sets that are missing (rare
  terms, ordinary prose) are the ones that would move the proper-noun number.
- **Not clean of harness effects.** 14 of 60 still do not start on the first
  word. A first pass lost the opening word of **48 of 60** because the recorder
  started capture after the audible cue finished; fixed by capturing first, and
  the old takes are kept as `audio-C-v1` / `audio-D-v1`.
- **Slightly pessimistic on labels.** `$1,200` was scored against `$1200`, which
  is a convention argument rather than an error.

### 2026-08-15 later — first deterministic pass, measured

`Guardrail.trimmingPunctuationRun` then `Disfluency.collapsingRepetitions`,
both pure and in Core, wired ahead of insertion.

**English torture set, `en_US`: 20.00 → 18.22 corrections per 100 words.**
45 errors to 41. Three utterances changed and nothing else in the set moved:

```
The the ABI key ends in 472.                   →  The ABI key ...
Reply to reply to Aidan and do not copy ...    →  Reply to Aidan ...
The the deadline is the 21st, not the 12th.    →  The deadline ...
```

Measured by compiling the actual Core sources into a CLI and re-running the
frozen manifest through them, so the number cannot drift from what ships.

**An earlier claim here was wrong and is withdrawn.** The first read of this
baseline said number formatting was cheaply fixable by deterministic rules and
worth roughly half the English error rate. It is not:

- When the engine turns "nine thirty" into `93`, the information is already
  gone. No text rule recovers `9:30` from `93`.
- Converting `315` to `3:15` is actively dangerous: `153` in "the build number
  is 153" must never become `1:53`. That is precisely what the fidelity guard
  exists to prevent.
- `"nine ninety nine"` arrived as `999`. `$9.99` is not recoverable from it.

So the deterministic bucket is **3 of 15 remaining failures, not 6**. The number
errors are a recognition problem and belong to the bias and learning layers
(M4/M5), not to M3's rules. `"4 tea attendees"` for "forty attendees" is a
learned confusion pair, not a formatting rule.

### What is left in English, after this pass

| class | cases | where it belongs |
|---|---|---|
| the founder's own names (`Chatan`, `Junalagadda`) and `TextInjector.swift` | 3 | M4 term store, M5 learning |
| numbers genuinely misheard (`93, 932, 1015`; `4 tea`) | 2 | M4 bias, M5 learning |
| misheard words (build/bill, timeout/timer) | 2 | M4 context bias |
| `Sara` collapsed to `Sarah` | 1 | M4 with both names present |
| comma rendered as a full stop | 1 | M3 punctuation, needs VAD |
| hallucinated `"Eating,"` on the onset | 1 | §0.18 confidence gate |

### 2026-08-15 — filler removal, measured on real speech rather than the script

The scripted sets cannot test this. Read sentences have no fillers, which is
the trap Part 4 names, so the evidence is the 418 words the founder actually
dictated through the app today.

**19 fillers in 418 words**: `uh` 6, `um` 1, `you know` 5, `I mean` 1,
`like,` 6.

**And the data settled a rule that guessing would have got wrong.** Three of
four uses of `like` were real words:

```
something like a name           real, keep
like post hog or 11 labs        real, means "such as", keep
Like, you know, use some...     filler
we are doing like, uh, ...      filler
```

So `like` is a filler only when a comma follows it, or when the next word is
noise. Removing it by word identity would have broken two sentences in four.

**Before and after, on a real utterance:**

```
before:  Like uh, the completely local one, right? ... Like, you know, use some
         3rd party, like, you know, storing database, like post hog or 11 labs.
         There is so much. we can do on our own to make it the better one.

after :  The completely local one, right? ... Use some 3rd party, storing
         database, like post hog or 11 labs.
         There is so much. We can do on our own to make it the better one.
```

10 of 28 captured utterances changed.

**Locked English torture set: 18.22 before, 18.22 after.** Unchanged, and that
is the result to want: scripted speech contains no fillers, so the pass has
nothing to do there. It acts on real speech and leaves clean text byte for byte.

**Two bugs the real speech found that the tests did not**, both fixed before
this entry:

1. Sentence starts were judged against the start of the *text*, not the
   sentence. Removing "Like," mid-paragraph left `you know,` unremoved and a
   lowercase word sitting after a full stop.
2. A first attempt moved a dropped token's comma onto the previous word, which
   turned "we are doing like, the local one" into "we are doing, the local
   one". The filler's comma belongs to the filler and leaves with it.

**Still not fixed, and visible in the same paragraph:**

- `Wispr Flow, Superwhisper` came back as `Whisper Fluence Super Whisper`, and
  `PostHog`/`ElevenLabs` as `post hog`/`11 labs`. Vocabulary, M4 and M5.
- `I don't, I do use` is a self-repair and both halves survive. M3's repair
  detector, not built.
- `look at, look at, look at` is left alone on purpose: punctuation between
  repeats is treated as a boundary the speaker made, and this one reads as
  deliberate emphasis.
