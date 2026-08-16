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

## 2026-08-15 — THE §0.1 DECIDING EXPERIMENT, RUN AT LAST ON THE FOUNDER'S OWN VOICE. **PATH B WINS AND THE QUESTION IS CLOSED.**

Part 0 §0.1 forked the whole vocabulary design on which module to use, and said
the decision belongs to the real corpus because §0.12 shows engine rankings
INVERT on accented speech. Until today the only evidence was ONE synthesized
file (2026-08-12, top of this log). This is 60 real utterances, six
configurations each, 360 analyzer runs, via `tools/signalprobe` compiled against
the shipping `TokenAssembly` so the numbers cannot drift from what ships.

Corrections per 100 words. **Bold is the best in each column.**

| configuration | English torture (locked) | code-switch dev | code-switch holdout |
|---|---|---|---|
| `SpeechTranscriber` @ en_US | **20.00** | 102.34 | 75.41 |
| `SpeechTranscriber` @ en_US + bias | **20.00** | 102.34 | 75.41 |
| `SpeechTranscriber` @ mul_IN | 42.67 | **46.88** | **29.51** |
| `SpeechTranscriber` @ mul_IN + bias | 42.67 | **46.88** | **29.51** |
| `DictationTranscriber` @ en_US | 31.56 | 73.44 | 68.85 |
| `DictationTranscriber` @ en_US + bias | 30.22 | 62.50 | 57.38 |

### The four findings, in the order they matter

**1. `contextualStrings` does NOTHING on `SpeechTranscriber`. Confirmed at three
locales, on 60 real utterances, to the last decimal.** Biased and unbiased are
not close, they are byte-identical: 0 of 60 utterances differ at en_US, 0 of 60
at mul_IN. The 2026-08-12 synthetic result held completely. **Do not re-open
this.**

**2. Biasing DOES work on `DictationTranscriber`, and the effect is large and
replicated.** dev 73.44 → 62.50, holdout 68.85 → 57.38. The error classes say
where it comes from and it is exactly the founder's demand: **proper-noun errors
on dev fall 7 → 1, and on holdout 5 → 0. Number errors fall 41 → 9 on dev and
13 → 1 on holdout.** A control run (the same configuration twice) differs on 1
utterance of 60, so a 15-17% move is far outside the module's own variance.

**3. And it loses anyway, for two reasons that are not close.** It is beaten on
English 30.22 to 20.00, **winning 2 of 30 utterances head to head**, and the
penalty is not punctuation as first guessed but ordinary words misheard
(`other` 39 vs 18). More decisive: **`DictationTranscriber` has no `mul_IN`
locale at all** (`supportedLocale(equivalentTo:)` returns nil), so the module
that can use a vocabulary cannot do code-switching, and the module that does
code-switching ignores vocabulary. There is no configuration where it is the
best answer.

**4. Confidence cannot route between the two engines, measured.** Picking the
reading whose mean confidence is higher scores **47.66 on dev, WORSE than simply
always using mul_IN at 46.88**, and exactly equal to the floor on holdout. It
recovers 0.9 of the 4.9 points available on English. Two models' confidence
scales are not comparable, and this kills the obvious hybrid before it is built.
A perfect oracle would score 15.11 on English against a 20.00 floor, so the
prize for routing is real (13-24%) but there is currently no signal that reaches
it.

### Verdict: Path B. `SpeechTranscriber` stays, and the vocabulary layer is post-ASR.

The term store, `TermMatcher` and alias learning are built on top of the engine's
own confidence rather than on native biasing, because native biasing is
unavailable on the only module that can serve both English and code-switched
speech. This is the route the signal layer above makes possible; before
confidence existed it could not have been taken.

**Locale stays a routing decision, unchanged and still unsolved:** en_US is 2.1x
better on English, mul_IN 2.2x better on code-switching, and no cheap signal yet
picks between them.

### A platform fact that is in none of the nine documents

**`DictationTranscriber` re-emits finalized results for a span it has already
finalized, keyed by an IDENTICAL start time.** Measured on C01: two finals,
`[1.11…5.52]` 45 chars and `[1.11…8.90]` 46 chars, the second a corrected
re-reading of the first. Anything that concatenates finals doubles the text, and
the first version of this probe did exactly that and scored every dictation
configuration at roughly double its true error count. `SpeechTranscriber` does
not do this: its five finals cover five distinct, non-overlapping spans and
genuinely append.

**This is Part 1 §3's banned duplication pattern wearing a different hat, and
`TranscriptAssembler` would fall into it.** It does `finalized.append(contentsOf:)`
and `TranscriptEvent.finalized` carries no span, so it could not de-duplicate
even if it wanted to. Correct for `SpeechTranscriber`, and a bug the moment
anything else is plugged into that seam. Reconcile by audio span, never by text.

Also measured: `DictationTranscriber` is not quite deterministic (1 of 60
utterances differs between identical runs); `SpeechTranscriber` is (0 of 60, at
both locales).

### What this experiment is NOT

- **The term list contains the answers.** `terms.txt` holds the names the corpus
  was built around, so the biasing result is an upper bound on a list that is
  already correct. That is a fair model of the shipped system only if the terms
  come from the user's own corrections, which is precisely what M5 is for. It is
  not a fair model of a cold start.
- 60 utterances, one speaker, one room, file input rather than the microphone.
- Sets A, B and E are still unrecorded, and they are the ones that would move
  the proper-noun number on English, where it is currently only 2 errors of 45.

## 2026-08-15 — CONFIDENCE IS CALIBRATED (Phase 0's open question, answered) AND THE VOCABULARY LAYER STILL MUST NOT SHIP

Phase 0 established that `transcriptionConfidence` is present on 100% of
finalized runs and varies from 0.011 to 0.998, then said the honest thing:
*"present and varying is not meaningful; the directive's bar is AUC > 0.70
against per-word error, which needs the corpus."* The corpus now exists and the
tokens now carry confidence, so it is answered. `tools/calibration.py`.

### 1. Confidence clears the bar as an error DETECTOR

AUC is the probability that a randomly chosen wrong word was less confident than
a randomly chosen right one. 0.50 is a coin flip.

| split | words | wrong | AUC | mean confidence, wrong vs right |
|---|---|---|---|---|
| English torture (locked) | 202 | 49 | **0.833** | 0.756 vs 0.933 |
| code-switch holdout | 56 | 23 | 0.749 | 0.491 vs 0.697 |
| code-switch dev | 136 | 69 | 0.631 | 0.554 vs 0.678 |
| **all** | **394** | **141** | **0.768** | **0.614 vs 0.835** |

**0.768 overall and 0.833 on English, against a bar of 0.70.** Confidence is a
real signal about which words are wrong, and it is strongest exactly where the
product is strongest. It is fit for **risk routing**: deciding which utterances
deserve an expensive second pass. Note it degrades on code-switched speech,
which is also where the engine is worst, so it is least trustworthy precisely
where it would be most useful.

### 2. And it is NOT sufficient to decide a substitution. The vocabulary layer is net harmful as gated.

Ran the full shipping pipeline (`TermMatcher` on tokens, then `Guardrail`,
`Disfluency`, `Fillers`) over the corpus, scored against raw:

| split | raw | full pipeline |
|---|---|---|
| English torture | 20.00 | 18.67 |
| code-switch dev | 102.34 | 102.34 |
| code-switch holdout | 75.41 | 73.77 |

**Every point of that gain is the disfluency stage that already shipped.** The
vocabulary layer's own contribution, isolated:

- **proper-noun errors on the locked English set: 2 before, 2 after. It fixed
  none.**
- **number errors on holdout: 13 before, 14 after. It added one.**
- Five substitutions in 60 utterances: **1 right (`Kisu` → `Kizu`), 4 wrong.**

The worst of the four is the one this whole design exists to prevent:

```
Never merge that branch without a review.   →   ...without a ravi.
```

A correct, ordinary English word, unsure for its own reasons, rewritten into a
name. `PhoneticKey`'s own tests assert it collides on ordinary English; this is
that collision reaching the user's document.

**M4's acceptance criterion is explicit that this is the failure that matters:**
*"propernoun corrections per 100 words drops at least 30% versus baseline, and
precision does not fall, no new errors introduced on utterances that were
previously correct."* Both halves fail.

### 3. It is not a tuning problem. Swept, and the similarity floor does nothing.

`tools/floorsweep` re-applies the matcher to the stored tokens, so the whole
grid costs no transcription. Similarity 0.65 to 0.90 x confidence 0.30 to 0.60:

| confidence floor | wins | losses | verdict |
|---|---|---|---|
| 0.30 | 0 | 0 | does nothing |
| 0.40 | 1 | 0 | safe, and fires once in 60 utterances |
| **0.50 (shipping)** | **1** | **1** | **net harmful** |
| 0.60 | 2 | 1 | net positive, still lossy |

**Wins and losses are IDENTICAL across the entire similarity range**; only the
neutral count moves. The similarity floor is not the lever, which means the
provisional 0.65 was never the thing holding this together.

**The structural reason was written down before any of this was measured, in
Part 1 §1:** *"Similarity is candidate generation only; the decision compares
acoustic scores for candidate vs. original. Never substitute on text resemblance
alone."* Confidence gates whether to look. It cannot decide what to choose, and
the choosing is where this breaks. CTC rescoring is not pedantry.

### Verdict: `TermMatcher` stays built, tested and UNWIRED, and the reason is in its docstring

Wiring it today would also be theatre: there is no term store, so the active
vocabulary is empty and the pass is a no-op by construction. The danger is the
opposite one, that a future store silently switches on a layer already measured
as net harmful.

### THE REAL BLOCKER, AND IT IS NOT CODE

**This corpus cannot settle the vocabulary layer, because it barely contains
vocabulary errors.** The locked English set has 2 proper-noun errors in 225
words. A sweep decided by 1 win and 1 loss is not a sweep, it is noise with a
table around it, and no threshold should be tuned on it.

**The unblocking action is recording the `propernoun` and `technical` sets, and
only the founder can do it.** Those are the sets Part 4 says are where
differentiation gets measured, and they are among sets A, B and E which are
still at zero. Until they exist, M4 and M5 are being designed against 2 data
points.

## 2026-08-15 — SET E RECORDED, AND IT REVERSED THE ENTRY ABOVE. THE VOCABULARY LAYER IS WIRED.

The founder recorded the 30-utterance `propernoun` set the same evening. The
corpus is now 90 utterances. **Everything the previous entry concluded about the
vocabulary layer was a true reading of a corpus that did not contain the thing
the layer exists to fix, and it inverted immediately once that data arrived.**

**Keep the lesson, not just the result: a layer cannot be judged on data that
does not contain its failure class.** "Not tunable" was measured, published in
this log, written into the type's own docstring, and wrong within the hour.

### The shipping numbers

Corrections per 100 words, raw engine output against the full pipeline
(`TermMatcher` → `Guardrail` → `Disfluency` → `Fillers`):

| set | raw | shipping | proper-noun errors |
|---|---|---|---|
| **propernoun dev** | 40.37 | **37.27** | **23 → 19** |
| propernoun holdout | 32.93 | 31.71 | 17 → 16 |
| English torture (locked) | 20.00 | **18.22** | 2 → 1 |
| code-switch dev | 102.34 | 102.34 | 5 → 5 |
| code-switch holdout | 75.41 | 72.13 | **2 → 0** |

**The locked set holds at exactly 18.22**, the number recorded before any of
this, so the vocabulary layer took nothing away where it had nothing to add.

### 8 repairs, 0 corruptions, across all 90 utterances

```
Kisu       -> Kizu           Challant   -> Chalant
Kisi       -> Kizu           Pribar     -> Prybar
versal     -> Vercel         Etram      -> Aatram
itrum      -> Aatram         Jonalagata -> Jonnalagadda
```

### The constants are now measured rather than provisional

Swept over all 90 utterances, counting wins (a wrong word became right) against
losses (a right word became wrong), which is the count M4 is accepted on:

| similarity | wins | losses |
|---|---|---|
| 0.70 | 12 | 5 |
| 0.80 | 10 | 2 |
| **0.85 / 0.90** | **8** | **0** |

`provisionalFloor` 0.65 → **0.90**, `confidenceFloor` 0.5 → **0.6**. Both were
marked UNTUNED in the code awaiting exactly this. 0.90 rather than 0.85 because
they measure identically and the last observed loss is at 0.80, so this stands a
full step clear of the cliff rather than on its edge.

**The trade this buys, stated plainly:** at 0.70 the matcher would make 12
repairs instead of 8, and corrupt 5 words the user got right. Four extra repairs
are not worth five corruptions. One casualty is `Shalan` → `Chalant`, an
original motivating case, now a documented known miss with a test recording it.

### Three findings that outlast the numbers

**1. A length guard, because similarity structurally cannot do this.** `review`
and `ravi` both reduce to `RF` under Double Metaphone, so they sit at 1.00 and
**no similarity threshold separates them.** `"Never merge that branch without a
review"` → `"...without a ravi"` survived every setting until length was used:
33% apart, where every true repair is within 17%. `TermMatcher.lengthTolerance`.

**2. The short-word rule was inverted and no test caught it.** It `return`ed
0.80 outright, so the moment the provisional floor rose above 0.80 a short word
faced a LOWER bar than a long one. It is now a floor among floors. The sweep
could never have found this: it passes an explicit similarity and never reaches
that branch.

**3. A failure the metric CANNOT see: canonical casing.** `score.py` lowercases
before comparing, so a lowercase term list scores identically while inserting
`"ship chalant to the kizu group"` into the user's document. Caught by reading
the output, not the number. `corpus/terms-canonical.txt` exists for this.

### What is left, and it names the next piece of work

27 of the 30 propernoun utterances still differ from what was wanted. The
failures fall into two clean groups:

**Split names, which the per-token matcher structurally CANNOT reach**, because
no single token is wrong. The engine broke one name into two words:

```
friction lens  <- FrictionLens      app cast        <- appcast
Speech analyzer <- SpeechAnalyzer   SF speech recognizer <- SFSpeechRecognizer
Fluid, audio   <- FluidAudio        core ML         <- CoreML
Super Whisper  <- Superwhisper      text injector   <- TextInjector
```

**Multi-token span matching is now the single highest-value next piece of
vocabulary work,** and this is the evidence for it.

**Single words the engine was too confident about.** `Chalan` for `Chalant` at
**0.87**, `Journalagada` for `Jonnalagadda`, `Aiden` for `Aidan`, `Villow` for
`Willow`. **Proper-noun errors are CONFIDENT errors:** on this set the engine's
wrong words average 0.757 against 0.909 for its right ones, because `Chalan` is
a perfectly plausible sound. AUC 0.796, which clears the 0.70 bar and is still
nowhere near enough to be the only gate. This is the group CTC rescoring exists
for.

### Honest limits

- **M4's bar is not met.** It wants proper-noun corrections down 30%; this is
  17% on dev. It is safe and positive, not finished.
- **The term list contains the answers.** Terms were written alongside the
  sentences, so this measures the layer given a correct vocabulary. That is a
  fair model of the shipped product only once M5 learns the list from the user's
  own corrections, and no model at all of a cold start.
- **8 wins and 0 losses on 90 utterances is still small n**, and the sets remain
  one speaker, one room, file input rather than the microphone.
