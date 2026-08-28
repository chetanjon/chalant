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

## 2026-08-15 — MULTI-TOKEN SPANS. **M4's ACCEPTANCE BAR IS MET: PROPER-NOUN ERRORS DOWN 39% AND 41%.**

The entry above named split names as the highest-value remaining work and the
evidence for it. This is that work.

| set | raw | single-word only | **with spans** |
|---|---|---|---|
| **propernoun dev** | 40.37 | 37.27 | **27.33** |
| **propernoun holdout** | 32.93 | 31.71 | **17.07** |
| English torture (locked) | 20.00 | 18.22 | **18.22** |
| code-switch dev | 102.34 | 102.34 | **95.31** |
| code-switch holdout | 75.41 | 72.13 | **72.13** |

**Proper-noun errors: dev 23 → 14 (−39%), holdout 17 → 10 (−41%), code-switch
dev 5 → 1.** M4 asks for at least 30% with no loss of precision. **Both halves
now pass**, on a holdout set that no threshold was tuned against.

Overall corrections fall 32% on propernoun dev and 48% on holdout. **The locked
English set does not move at all**, which is the right result: it contains
almost no vocabulary, so a vocabulary pass should be invisible there.

16 utterances joined, including:

```
friction lens        -> FrictionLens      app cast      -> appcast
speech analyzer      -> SpeechAnalyzer    core ML       -> CoreML
SF speech recognizer -> SFSpeechRecognizer  super whisper -> Superwhisper
text injector        -> TextInjector      Fluid, audio  -> FluidAudio
```

### Why this had to be a separate pass, measured

**A split name is made of CONFIDENTLY heard words.** `friction` 0.98, `lens`
0.98, `analyzer` 0.94, `Speech` 0.92, `injector` 0.91. The engine hears every
word correctly and gets only the boundary wrong. The single-word gate fires only
on uncertainty, so it can never see this, and a confidence gate on spans would
mean the pass never fires at all. The evidence comes from the match instead: a
run of words sounding like one of the user's own terms, to near-exactness
(0.95), at comparable length.

### THE STOPWORD GUARD, AND THE FAILURE THAT FORCED IT

**The first version shipped without it and the corpus found two failures within
minutes. All 14 unit tests passed while it was broken.**

```
"I can't make it on Thursday."       ->  "I can't make Aidan Thursday."
"Ship Chalan to the Kizu group."     ->  "Ship Chalant the Kizu group."
```

The second is the worse one: **the name came out RIGHT and the sentence lost a
word.** That is the Part 1 §2 violation rather than a wrong guess.

**Neither is reachable by any threshold.** `it on` and `Aidan` reduce to the
SAME phonetic key and sit 20% apart in length, so similarity and length both see
a perfect match. Only the fact that `it` and `on` are function words separates
them.

**Part 5 §3 named this mechanism before it was needed** (`stopwordSpanSimilarity
0.85`, *"protects `and` from becoming `Andre`"*) and it was not used. A hard
refusal rather than a raised bar, because at identical phonetic keys there is no
bar left to raise. Known limitation, stated rather than discovered later: a term
genuinely containing a function word ("Bank of America") cannot be joined. No
term in use does.

**The general lesson, and it is the second time today: the corpus catches what
the unit tests cannot, because the tests only contain the failures already
imagined.** Both bad joins were of a shape nobody thought to write a test for.

### Still open

- **The reverse split is not handled.** `Whisperflow` for `Wispr Flow` is one
  token that should be two. This pass only joins.
- **Confidently wrong single words remain**, and they are now the largest group:
  `Chalan` for `Chalant` at 0.87, `Journalagada`, `Aiden` for `Aidan`, `Villow`
  for `Willow`. No confidence threshold reaches them; this is CTC rescoring's
  territory.
- **The term list still contains the answers**, so this measures the layer given
  a correct vocabulary. M5 learning it from the user's own corrections is what
  makes that a fair model of the shipped product.

## 2026-08-16 — M7's LATENCY AND FIDELITY GATE, MEASURED. THE PROMPT FRAMING IS WORTH 6 OF 7 FAILURES.

Part 0 §0.5 made the latency budget an empirical gate rather than a spec
constant, and the 2026-08-14 reversal made this pass the DEFAULT path for every
utterance. So it gets measured before it gets built. `tools/cleanupprobe`, 20
utterances of real deterministic pipeline output, Apple's on-device model.

**The model is available on this machine.** Everything below assumes that and it
is the first thing that would have stopped M7 dead.

### Three output modes, and the framing decides everything

| mode | rejected by `FidelityGuard` | warm p50 | p95 | worst |
|---|---|---|---|---|
| `@Generable` single field (Part 2 §8's) | 6/20 | 0.80s | 1.28s | 2.07s |
| plain string | 7/20 | 0.54s | 1.73s | 2.99s |
| **transcript delimited as DATA** | **1/20** | **0.54s** | **0.95s** | **1.10s** |

**The schema was not the problem and that had to be checked before blaming the
model.** Plain string scored WORSE than the structured output, so the
`@Generable` field is not what was mangling the text.

**The framing was the problem.** Handing the transcript over as the prompt made
the model read ordinary dictation as instructions to itself:

```
"Cancel the subscription today."            -> "I cannot process requests to cancel subscriptions."
"Drop the users table on the local copy."   -> "I cannot perform that action. I am a foundation model..."
"Move the stand-up from 93, 932, 1015."     -> "I cannot move objects. However, I can help edit..."
```

**Part 2 §8's injection preamble did not prevent this, and it is not the failure
that preamble was written for.** That defends against a user trying to hijack
the model. This is the opposite and far more ordinary: people dictate imperatives
constantly, and a helpful assistant declines to cancel their subscription.

Putting the transcript between markers, labelled as data with the task stated
around it, removed every refusal. **A rule the model may follow, replaced by a
structure it cannot misread.**

### Latency: the launch claim's problem is real but survivable

**0.54s median, 0.95s p95, 1.10s worst, on top of the 0.05-0.23s the whole rest
of the pipeline costs.** So cleanup is roughly 4x everything else combined, and
Part 8 §1's p50 120ms / p95 250ms budget is gone whatever else happens.

For comparison the competitors clean in the cloud, so this is not obviously
worse than a network round trip. But **"faster" cannot be claimed on the
cleaned path**, and the honest claim remains consistency rather than a number.

### The guard earned its keep and had two bugs of its own

**Both were found by running the real model, neither by thinking about it.**

1. **It rejected `$1200` -> `$1,200`** as a missing number. That is the same
   amount better written, and the guard was throwing away a good cleanup. **A
   guard that fires on CORRECT output does not look like a bug, it looks like
   the feature not working.** Fixed by stripping thousands separators, while
   leaving `.` and `:` alone so `3:15` and `315` stay different.
2. **It missed the model stuttering.** `"Move the stand-up from 93, 932, 1015"`
   came back as `"Move the stand- Move the stand-up from 93, 932, 1015"`, with
   identical numbers, negations, names and content overlap, so every check
   passed. Now caught by comparing bigram counts: a pair of words appearing more
   often in the output than the input is the model repeating itself, which is
   this guard's business precisely because `Disfluency` handles the HUMAN kind
   and runs before the model ever sees the text.

### What this run does NOT establish

- **It does not show the model cleans well.** 13 of 20 outputs are IDENTICAL to
  the input, which is correct: set C is SCRIPTED speech with no fillers and
  nothing to tidy. The real test is the 44 captured spontaneous utterances, and
  it has not been run.
- The four genuine improvements seen (a comma before "not", quotation marks
  around reported speech) are encouraging and are four examples.
- One real corruption survives at 1/20: `"It's/user/Chatan/projects."` became
  `"It is Chatan's projects."`, a destroyed file path. Code and paths are a
  known-hostile case for a cleanup model and M6's code mode is where that
  belongs.

### 2026-08-16 — the same pass on 42 REAL SPONTANEOUS utterances, which is the test that matters

The run above used set C, which is SCRIPTED and has nothing to clean, so 13 of
20 outputs came back identical and it proved only that the model does not
corrupt. This is the founder's own captured dictation, fillers and false starts
included, taken from `captured.jsonl` where `output` is already the
deterministic pipeline's text.

| | scripted (set C) | **real spontaneous** |
|---|---|---|
| rejected by the guard | 1/20 | **2/42** |
| model refusals | 0/20 | **0/42** |
| warm p50 | 0.54s | **0.99s** |
| warm p95 | 0.95s | **2.10s** |
| worst | 1.10s | **3.70s** |

**Latency is roughly double what the scripted set suggested**, because real
utterances are longer. ~1s median and 2.1s at p95 is the honest number for the
cleaned path, against 0.05-0.23s for everything else combined.

### How much does it actually clean? Modestly.

- **20 of 42 outputs are IDENTICAL to the input.** The model does nothing to
  half of real speech.
- **Fillers: 11 utterances contained one before, 6 after.** It removes roughly
  half of what it should, which is the job it exists for.

The best example, and it is genuinely beyond what the deterministic stages can
do:

```
in : Look at this, look at, look at, look at what I talked till now in this
     sentence. Like, it's...
out: Look at this. Look at what I talked about until now in this sentence. It
     is not there yet.
```

`Disfluency` deliberately leaves that triple alone, because punctuation between
repeats reads as emphasis a speaker chose. The model can tell it was not.

And one that shows the cost of letting it reword freely:

```
"We got to be perfect."  ->  "We must be perfect."
```

No fidelity violation, so nothing catches it, and it is the speaker's voice
being changed rather than cleaned. There is no guard for register.

### A third guard bug, again found only by running it

**It rejected a good cleanup with "a name went missing: Im".** English
capitalises the first person everywhere, so `I'm` bares to `Im`, which is
capitalised and not opening the sentence. A rewrite is entitled to turn "I'm not
sure" into "I am not sure". Fixed.

**That is three guard bugs now, and every one of them was found by running the
real model rather than by reasoning about the guard.** Two of the three made it
reject CORRECT output, which is the failure mode that does not look like a bug:
it looks like the feature not working.

### The decision this leaves, and it is the founder's

Cleanup costs ~1s, does nothing to half of real speech, and removes about half
the fillers in the rest. Confidence is calibrated (AUC 0.796) and could route
only the risky utterances through it, keeping the fast path fast.

**That deviates from "clean every utterance", which the founder settled twice on
2026-08-14, so it is not a decision to take quietly.**

### 2026-08-16 — CAN CONFIDENCE DECIDE WHICH UTTERANCES ARE WORTH CLEANING? NO. THE FOUNDER'S "CLEAN EVERYTHING" STANDS.

Cleanup costs ~1s and does nothing to half of real speech, so the obvious
proposal was to route only risky utterances through the model and keep the fast
path fast. Confidence is calibrated for spotting WRONG WORDS (AUC 0.796), so it
looked like the signal for it. **It is not, and this closes the question rather
than leaving it open.**

Measured on the same 42 captured utterances, cross-referencing per-utterance
mean confidence against whether the model changed the text at all:

| | count | mean confidence |
|---|---|---|
| model changed it | 22 | 0.841 |
| model left it alone | 20 | 0.870 |

**A separation of 0.029, and AUC 0.602 against a coin flip's 0.50.**

| route below | utterances cleaned | of which useful | useful ones missed | avg latency |
|---|---|---|---|---|
| 0.85 | 12 | 7 | 15 | 0.27s |
| 0.90 | 27 | 16 | 6 | 0.75s |
| 0.95 | 35 | 22 | 0 | 1.06s |
| clean everything | 42 | 22 | 0 | 1.19s |

**To catch every useful cleanup you must route 35 of 42 and save 0.13s.** There
is no threshold that buys meaningful speed without throwing away cleanups.

**Why it fails, and it is obvious in hindsight:** confidence measures whether
the engine HEARD correctly. Cleanup fixes what the speaker SAID: fillers, false
starts, rambling. A perfectly-heard "you know, like, we are just, you know..."
scores high confidence and needs the most cleaning. **The two are unrelated by
construction, and a good AUC on one question says nothing about the other.**

**Consequence: the 2026-08-14 decision to clean every utterance is unchallenged
and now measured.** The alternative was proposed, tested and lost.

## 2026-08-16 — CHUNKING FIXES THE LONG-INPUT FAILURES. THE MODEL DID NOT GET BETTER; THE PIECES GOT SMALL ENOUGH.

The founder's own 703-character dictation (the friend in San Francisco), on
1.14.0, was rejected by the guard for a false positive and shipped raw. Fixed in
1.14.1, but the whole-paragraph cleanup underneath was still unreliable:

| | runs | clean | dropped negation | invented fragment | speaker rewritten as "he" |
|---|---|---|---|---|---|
| **whole paragraph** | 5 | 3 | 1 | 1 | **1, silently, in a "clean" run** |
| **chunked ~40 words** (shipping code) | 5 | **5** | 0 | 0 | **0** |
| chunked ~25 words | 3 | 3 | 0 | 0 | 0 |
| chunked ~70 words | 3 | 3 | 0 | 0 | 0 |

**11 chunked runs across three sizes: not one meaning error.** The on-device
model is reliable on ~40 words and not on ~140. Splitting at sentence ends puts
it where it works.

Cost: 4.4-5.2s chunked against ~4.0s whole, on this paragraph. Four model calls
instead of one, on a session prewarmed once. Roughly the same wait for a result
that can be trusted.

**Chunk size barely matters between 25 and 70. Shipping 40:** 25 measured no
cleaner and costs more calls; 70 has no evidence yet that it holds on longer
paragraphs. `CleanupPrompt.chunkTargetWords` is a reliability limit, not a
window limit, and the comment says so.

**Per-chunk guard, per-chunk fallback.** A rejected chunk now ships raw ON ITS
OWN. Before this, one rejected phrase anywhere threw away the whole cleanup,
which is exactly what the founder saw on 1.14.0.

### The wobble that survives, stated plainly

One clause flips between runs at every chunk size:

```
"he is waiting for the call"     (runs 2, 3)
"I am waiting for his call"      (run 1)
"he is waiting for your call"    (runs 4, 5)
```

The source was *"he said, I'll call you in half an hour and I'm waiting for
his call"*, which is genuinely ambiguous reported speech. Not a chunking
problem, and not the whole-paragraph failure of rewriting the speaker in the
third person throughout. Every run keeps *"I will just go back to sleep"*.
There is still no guard for pronoun identity; this is the size of what it would
be catching.

### 2026-08-16 (evening) — THE SHIPPING CLEANUP, RUN AS SHIPPED, ON 92 REAL UTTERANCES: ONE SHARED SESSION WAS COSTING 4x AND KILLING ITSELF; "REWRITE" WAS PARAPHRASING

`tools/shipclean`: the shipping path (`CleanupPrompt.chunks` / `framing` /
`unwrap`, `FidelityGuard`, compiled from Core) over every utterance in
`captured.jsonl` recorded before cleanup shipped, so `output` is raw
deterministic text. 92 utterances of the founder's own speech.

**Finding 1, a shipping bug (1.14.0 through 1.15.1): the polisher reused ONE
`LanguageModelSession` for every utterance.** A session keeps a transcript, so
the context grew all day. Same 92 utterances, same wording:

| | shared session | fresh session per utterance |
|---|---|---|
| median | 2.2 to 2.7s | **0.55s** |
| p95 | 4.6 to 6.1s | **1.9s** |
| utterances changed | 17 to 26 | **50** |
| context overflow (`exceeds the maximum allowed context size of 8192`) | every row past ~90 | none |

The model was slower AND lazier with a history of prior turns in front of it,
and eventually failed on every call until relaunch. Nobody saw it because the
failure log said only "failed" and the founder's app was relaunched often.
**Fixed: a fresh session per utterance; the model stays resident so it costs
nothing measurable. The log now carries the framework's reason.**

**Finding 2: "rewrite" is licence to paraphrase.** With fresh sessions the
model cleaned far more, and rewrote far more: "What next?" → "What comes
next?", "We got to be perfect" → "We must be perfect", "Make it PDF, man" →
"Make it a PDF", "I gave you" → "you gave me" (meaning inverted, uncaught), a
whole clause dropped (uncaught). Smallest-edit wording, measured against it:

| | "rewrite" | "smallest possible changes" |
|---|---|---|
| utterances given words never said | 23 | **1 to 2** |
| chunks the guard rejected | 13 | **2 to 3** |
| utterances with fillers, before → after | 14 → 9 | 14 → 7 or 8 |
| the model's own stutters | 3 → 2 | 3 → 1 |
| lost final period/question mark | 1 | 4 before `keepingEnding`, **0** after |
| median / p95 | 0.55s / 1.9s | 0.58s / 1.8s |

Two runs of the final wording agree within one utterance (22/92 changed, 2 and
3 rejected). **Shipped.**

**Finding 3, three model habits the guard now catches or unwrap repairs:**
typographic quotes ("it’s", "“done”": 0 of 92 after `plainQuotes`); a single
doubled word ("I'm I'm", "Kalisi, Kalisi": caught, both recur run to run);
dropped final punctuation on short lines (repaired, above).

**What is still not clean, honestly:** 5 of 92 keep a "like, you know" run
the small model does not touch, code-switched Telugu gets a letter changed now
and then ("vellama" → "wellama", not a capitalised name so the names check
cannot see it), and there is still no guard for pronoun identity or for a
dropped clause of ordinary words. Under the tight wording neither happened in
184 runs; under "rewrite" both did.

**Method note that outlasts the numbers: measure the SHIPPING path, not a copy
of it.** `tools/cleanupprobe` carries its own prompt and its own session
policy, and it could never have found finding 1. `shipclean` compiles Core so
it cannot drift; the polisher's session policy is the one line it must mirror
by hand, and it does now.

## 2026-08-20 — sparse commas, say it once (`fix/hear-the-words`)

Founder: "chalant is using a lot of commas... and if the user is saying the
same thing it should refine and give me one without fluff." Attribution first:
raw Apple transcripts of the comma-heavy clips (`transcribe` on the captured
audio) show the commas are the TRANSCRIBER's, one at every pause ("because,
you know, the music"), and en_IN returned byte-identical text to en_US on the
same clips (2 clips, the cheap locale experiment finally run: no win there).

Two changes, measured with `shipclean --all --fresh --limit 40` on the
captured corpus, same 40 rows both runs:

- Deterministic: a filler's OPENING comma now dies with it (Fillers). The
  strand class ("because, the music") was all over the corpus outputs.
- Prompt: remove commas that only mark a pause; when the speaker repeats or
  rephrases, keep the version they finished with, ALWAYS THE LATER ONE.

|                | before | after |
|----------------|--------|-------|
| commas/100w    | 11.14  | 10.47 |
| changed        | 17/40  | 18/40 |
| guard rejected | 1/40   | 2/40  |
| p50            | 0.75s  | 0.85s |

The extra rejection is the right one: "I don't, I do use it" repaired means
dropping a negation, the guard vetoes it, and it ships verbatim. THE FIRST CUT
OF THE REPETITION RULE KEPT THE EARLIER VERSION and flipped that sentence to
"I don't use it" (guard-blind: a "don't" survives either way); "always the
later one" is the load-bearing phrase. An explicit example in the prompt was
tried and removed: it taught a case the guard vetoes anyway and cost tokens.

## 2026-08-20 (afternoon) — the budget starved, and restatements collapse

Founder on 1.24.2: "if I'm talking the same thing again, it's giving me
exactly the same thing. It's not refining at all." First corpus read off the
new instrumentation: EVERY real utterance landed raw (polishSeconds 1.35 /
2.01 / 5.17 s on 26/29/40-word rows, refinedAtOnce false), and "budget
expired at the caller" fired 5 times with waits far past the 0.73 s hard
cap: Whisper (started at finalize since 1.24.0) starves the cooperative
pool so thoroughly that the budget's own timers fire seconds late. With
land-once, raw stays: so nothing ever refined.

Fixes: hearing drops to utility priority; the caller's deadline moves to
the main actor's executor (unstarveable by CoreML); `Restatement` collapses
an exactly-repeated sentence (≥3 words, case/punctuation-blind, first copy
kept) deterministically on every path including raw landings and the
hearing pass. Measured: the pass touches 1 of 380 historical corpus rows
(high precision by design; the historical set predates deliberate repeat
testing). 241 Core tests, 6 new.

## 2026-08-21 — the model goes cold five minutes after last use (`feat/prewarm-at-keydown`, campaign phase 1a)

Phase 1a's lever (prewarm the cleanup model at every key-down) was written
down on the strength of one number: a cold first call of 2.4 s against a
0.99 s warm median (2026-08-16 above). That run measured a first call with
NO prewarm at all, so nothing had shown that a `prewarm()` on one session
warms the FRESH session each piece actually responds on, or how long a
warm-up lasts. Part 1 §3 bans optimising before measuring, so:
`tools/warmprobe`, one fresh process per run, the shipping prompt and
framing compiled from Core, a ~38-word filler-laden synthetic passage.

**Warmth is not per process, and the system takes it away on a timer.**
Apple's `modelmanagerd` loads the 3B model for every client and unloads it
five minutes after its last use, read straight from its own log: Chalant's
launch prewarm loaded it at 16:24:44 (3.8 s, first load since boot) and it
was unloaded at 16:29:49 ("unloadIfNecessary ... Unloading asset
instruct_3b"); the probe's runs at 17:15 were unloaded at 17:20:42 and the
next at 17:25:57 and 17:31:16, five minutes to the second each time. A reload from the
page cache takes 0.75 to 0.9 s; the first load after boot 3.8 s.

What a fresh process pays, one run per line, timings of the FIRST respond:

| model state at the respond | first respond | next respond |
|---|---|---|
| cold, no prewarm (the 1.26.0 first utterance after a 5 min pause) | **2.487 s / 2.550 s** | 0.894 s / 0.913 s |
| cold, prewarm on a separate session, then 1 s wait (a short hold) | **1.077 s** | 0.924 s |
| cold, prewarm on a separate session, then 3 s wait | **1.107 s** | 0.925 s |
| warm (another process responded 2 s earlier) | 0.923 s / 1.000 s | 0.906 s / 0.930 s |

The `prewarm()` call itself returns in 5 to 28 ms and the daemon logs
"Loading asset" 16 ms later, so the load runs entirely behind the hold. A
prewarm on one session warms a fresh session in the same process: the
warmth lives in the daemon, not the session. When already loaded the daemon
answers "Not loading asset": a repeated prewarm costs nothing.

So the launch prewarm (1.16.x) was covering only the first five minutes
after launch, and every dictation after a longer pause has been paying
~1.6 s extra at the one moment the user is waiting: the 17:36 conviction
row (polish 2.456 s, one minute after a relaunch whose prewarm had already
expired by the time of the previous hold's silence, or simply unused) fits.
Phase 1a: `keyDown` calls `polisher.warmUp()`; a polish-worthy utterance
is over 40 characters, so over ~3 s of speech, and the reload is under 1 s.
Expected on the founder's rows: polishSeconds on cold-after-a-pause
utterances drops from ~2.5 s to ~1.1 s (the 0.65 s budget still decides
whether the refined text lands at once; this removes the cold penalty, not
the model's own time). Phase 1b (a keep-warm timer while the ear is warm)
is now known to need a period under five minutes if it is ever built; with
1a hiding the reload inside the hold, it may not be needed at all.

## 2026-08-21 — THE STARVATION VERDICT: nothing was starved. The waits could not return. (`fix/the-budget-is-real`)

The first schema-2 row, from a synthetic hold on 1.26.0 (harness
`verify-dictation.sh --cold`, 183 chars, one 14 s sentence, TextEdit):

| field | value |
|---|---|
| polishSeconds | **1.697 s** against the 0.73 s hard cap |
| polishOutcome | budgetExpiredCaller |
| refinedAtOnce / refinedChanged | false / false |
| holdSeconds / inputPeak / keyDownHeard / fedBuffers | 14.18 / 0.43 / true / 139 |
| insert | tier 1, 0.166 s |
| hearing line | swapped, 3.42 s later, 183 → 182 chars |

The log around it: the urgent key-up piece's model reply (a guard
rejection, "a name went missing: Priya") is stamped 18:11:53.647167 and
the polisher's "cleanup not ready within budget ... 1.697046s elapsed
here" 18:11:53.647236, **seventy microseconds apart**, while neither
deadline leg (main actor, pool, raw dispatch timers, the 1.25.1 probe)
logged a late wake. Same shape as every row since 08-18.

**Measured the other way, in a bare process (`tools/mainstall`): the
model framework starves nothing.** A 20 ms main-queue ticker and a raw
thread posting main-queue blocks and detached tasks every 20 ms, across
warm responds, with a 300 ms `Task.sleep` started inside the respond:

| responds in flight | longest respond | main hop max | pool hop max | sleep(300 ms) woke after |
|---|---|---|---|---|
| 1 | 0.95 s / 0.98 s | 2 ms / 1 ms | 2 ms / 1 ms | 301 ms / 301 ms |
| 2 | 1.75 s | 26 ms | 26 ms | 305 ms |
| 3 | 2.53 s | 8 ms | 8 ms | 301 ms |

(Side fact: concurrent responds serialize in the daemon, which is why the
key-up piece took 1.87 s: it queued behind the previous tail speculation.)

**The mechanism, reproduced in isolation:** the polisher's bounded wait,
verbatim, a task group of {await task.value, sleep}, against a task that
takes 3 s with a 200 ms budget, **returned nil after 3.04 s**. A task
group does not return until every child has finished, and a child that
awaits another task's value cannot be cancelled. The sleep fired at 200
ms, `next()` answered, and the group sat on the value child until the
task was done. The controller's outer wait had the same shape around the
polish child, so its two dispatch-timer legs fired at 0.73 s, logged
nothing (they had not been late), and the group waited for the polish,
which was waiting for the model. Six deadline variants since 08-18 were
aimed at timers that were never late.

Fix: `Deadline.value(of:within:)` in Core, one continuation raced between
a dispatch timer and an observer task; the task is never cancelled, so
late pieces still land in the cache for the hearing pass. `DeadlineTests`
pins it (the expiry case returns in 0.10 s where it took 3 s). Both waits
use it; the two-executor race and `hardDeadline` are gone. Not yet
exercised live: no signing identity on the Mac today.

Also fixed off the same row: a budget miss erased the cold-start facts
(`polishColdStart: false`, `secondsSinceLastPolish: -1` on a process that
had never polished). They are fixed at key-down and are now read before
the wait.

What the row does NOT say yet: this sentence's tail chunk was rejected by
the guard on all nine speculations during the hold ("the model repeated
itself" ×8, then the missing name), so even a perfect deadline lands it
raw. Whether that is the synthetic voice or the passage is a question for
real rows.

## 2026-08-21 — PROTECTED-SPAN MUTATION RATE, FIRST MEASUREMENT: 0/61 as shipped; 0, 0 and 1 of 61 ungated (`feat/protected-span-rate`)

The directive's §4.1 metric, measurable for the first time: Set C annotated
with 76 protected spans (`corpus/setC.json`, founder-approved), the raw
en-US ASR text kept verbatim (`corpus/setC-asr-en_US.jsonl`), a CLI that
runs each string through the shipping text path (`tools/textpath`: the
controller's deterministic order, empty vocabulary, then
`FoundationModelsPolisher.polish` with the shipping prompt, framing and
`FidelityGuard`, no release budget), and a scorer for the five rules
(`corpus-kit/span-score.py`). Stamp on every run: commit `3ca798a`, prompt
SHA-256 `e97958cb280f…`, model `instruct_3b.fm_api_generic_3b?variant=
generic_sparse` version `15.0.0.13.102990`, macOS 27.0.

| run | rows to the model | spans present | mutated | rate | what changed |
|---|---|---|---|---|---|
| gated, as shipped (40-char line) | 10 of 30 | 61 | **0** | **0.0000** | nothing |
| ungated, pass 1 | 30 | 61 | 0 | 0.0000 | C14 comma before "not" |
| ungated, pass 2 | 30 | 61 | 0 | 0.0000 | C14 comma before "not" |
| ungated, pass 3 | 30 | 61 | **1** | **0.0164** | C14 comma; **C08 "can't" → "cannot"** (label `contraction`, stage `model`) |

Case drift 0 in every run; negation counts unchanged in every row ("cannot"
counted as a negation, stated in the scorer). **The model is not fully
deterministic**: C08 came back as said twice and expanded once in three
passes, so the ungated rate is 0 to 1 of 61 under this prompt, never a
single number. Rejected by the guard on all three ungated passes: C12
(`It's/user/Chatan/projects.`, `stillTheSameMessage`): ships as dictated,
no span touched. The deterministic stage changed C18, C23, C27 (doubled
openings removed) and touched no span.

**ASR misses, out of scope here and reported separately: 12 rows, 15
spans.** C03 (3:15, 3:50), C05 (Sara), C07 ($1,200 heard as $1200), C12
(the path), C13 (the email), C14 (build number heard as bill number), C17
(9:30, 10:15), C18 (API heard as ABI), C22 (40 heard as "4 tea"), C24
(TextInjector), C25 (timeout heard as timer), C29 ($9.99, $99 heard as 999
and 99). The founder expected about nine; the three beyond that (C05, C18,
C24) are in the raw text, not in the scorer.

What this does NOT say: Set C is scripted and mostly under the 40-character
line; 20 of 30 rows never reach the model as shipped. The rate on real
spontaneous dictation is the number the schema-3 row exists to give, and no
row of that kind exists yet (this build is not installed: no signing
identity on the Mac today).

## 2026-08-22 — CLOSING THE TWO GAPS: greedy decoding, and a sixth guard rule that adds nothing (`feat/close-the-two-gaps`)

Both measured with the #44 harness (`tools/textpath`, `corpus-kit/span-score.py`),
same stamp as before except the commit: model `instruct_3b.fm_api_generic_3b?
variant=generic_sparse` `15.0.0.13.102990`, prompt SHA-256 `e97958cb280f…`
(`CleanupPrompt` untouched).

### 1. Greedy decoding (`GenerationOptions(sampling: .greedy)` on every polish call)

The API exists (macOS 26.0+, `GenerationOptions.SamplingMode.greedy`). Ungated
Set C, three passes: every text field identical across the passes (the run
files hash alike once the per-row timing is dropped; `4fcd08b9…`), C08 no longer
flips ("I can't make it on Thursday." on all three), rate **0/61** on all three,
the same single rejection (C12, `stillTheSameMessage`) and the same single edit
(C14's comma) as the #44 sampled runs. Diffed against #44: no edit appeared or
disappeared; the only change is the flip going away. Timing unchanged (median
0.54 s per call against 0.61 s).

### 2. Rule six, `noNewTokens`: every output token must come from the input, no more often

Tokens lowercased, apostrophes kept inside words (curly read as straight),
everything else that is not a letter or digit stripped, list markers removed
first like the other rules. Fewer tokens is fine; any new token or any count
higher than the input is `rejected:noNewTokens`. No exceptions list. Runs last,
so the older rules keep naming what they catch. Seven tests that encoded the
2026-08-14 "rewords freely" positioning now assert the reversal (contraction,
expansion, synonym, pronoun-for-name and the reused-words reply are all new
words now); the deletions they also tested still pass.

**(a) Set C, ungated, greedy, three passes:** rate **0/61** on all three, text
identical across passes, rejections unchanged: C12 only (`stillTheSameMessage`,
which fires before rule six). Rule six rejected nothing on Set C.

**(b) False-rejection cost on D and E, ungated, one greedy pass each.** Rule six
runs after the older five, so every `rejected:noNewTokens` below is a row the
old guard would have let land.

| set | rows | landed | rejected by rule six | rejected by older rules | failed (framework refusal) |
|---|---|---|---|---|---|
| D (Telugu/Hindi/Marathi code-switch through en-US ASR) | 30 | 22 | **3 (10.0%)** | 3 (`namesSurvived`) | 2 |
| E (the founder's vocabulary) | 30 | 28 | **2 (6.7%)** | 0 | 0 |

The five rule-six rejections, source (after the deterministic pass, which
changed none of them) against the model's reply:

| id | afterDeterministic | model reply | what the model did |
|---|---|---|---|
| D-R1-a | Chalant Lo was dictation, punishes, tunda. | Chalant Lo was dictation, **punishment**, tunda. | swapped a word (the ASR was already nonsense here; truth "pani chestunda") |
| D-U08 | Gangotri Nundi call vachindi. | Gangotri Nundi **called**. | rewrote two words into a new one |
| D-R2-c | Ravi Ki Chebu meeting postpone Indane. | Ravi Ki Chebu meeting **postponed to** Indane. | added two words |
| E02 | Ask Athram, weather friction lens is ready for Gangotri. | Ask Athram, **whether** friction lens is ready for Gangotri. | fixed the ASR's homophone; the truth IS "whether" |
| E20 | Claude code writes straight into the Chalant Island. That's nice, one of that. | …That's nice, one of **those**. | changed a word the ASR got wrong; truth has no such clause at all |

So of five: three are the model adding or swapping words (the rule's purpose),
one (E02) is a correct repair of an ASR error that the rule blocks because it
cannot know it is correct, one (E20) is a plausible edit of a phrase the
speaker never said. In the 50 landed rows the model's edits were deletions,
punctuation and case only (D: 4 rows, E: 2 rows), all passing rule six.

**(c) Redundancy, stated, nothing removed.** `didNotStutter`: redundant in
practice (a repeat raises a token's count; the only escape is a compensating
drop of the same word elsewhere). `numbersSurvived`: the "appeared" half is
redundant (a new figure is a new token); the "went missing" half is not, rule
six allows drops. `negationsSurvived`: same split, "appeared" redundant, "went
missing" not. `namesSurvived`: not redundant (it catches drops; it fired on 3 D
rows today). `stillTheSameMessage`: redundant for replies that bring new words,
not for replies made of fewer source words. `emptyOutput`: not redundant.

## 2026-08-22 — WHAT DOES THE MODEL BUY? Sets C, D, E (90 rows), greedy, rule six in force (`measure/what-the-model-buys`)

Measurement only. `tools/textpath` ungated and gated over all 90 rows;
`corpus-kit/model-value.py` scores `afterDeterministic` and `final` (the
model's text where it landed, the deterministic text where gated, rejected or
refused) against the truth with score.py's corrections per 100 words, and
classifies every edit the model made. Per-row table:
`corpus/runs/what-the-model-buys-2026-08-22.jsonl`. Stamp: commit `f05e197`,
prompt `e97958cb280f…`, model `instruct_3b… generic_sparse 15.0.0.13.102990`.

### 1. Value

| set | rows | words | corrections/100w, deterministic | corrections/100w, final | closer | equal | farther |
|---|---|---|---|---|---|---|---|
| C | 30 | 225 | 18.22 (41) | 17.78 (40) | 1 | 29 | 0 |
| D | 30 | 189 | 93.65 (177) | 92.59 (175) | 2 | 27 | 1 |
| E | 30 | 243 | 37.86 (92) | 37.45 (91) | 1 | 29 | 0 |
| all | 90 | 657 | **47.18 (310)** | **46.58 (306)** | 4 | 85 | 1 |

Closer (every one): C14 `153 not 135` → `153, not 135` (a comma the ASR dropped);
D-U01 a stray `Drop.` at the end removed; D-R2-a `ah,` removed; E25 a comma
before `all` removed. Farther: D-U05 `status Enti?` → `status, Enti?` (a comma
added where the truth has none). Four corrections out of 310 recovered, one
added: the model moves the score by 0.6 per 100 words on 90 rows.

### 2. What the model does (11 edits, 7 rows, of 79 landed)

| class | edits | could the deterministic stage have done it? |
|---|---|---|
| filler/repeat deletion | 0 | (nothing to do: Disfluency and Fillers had already taken the `The the`, `Reply to reply to`, doubled openings) |
| other deletion | 2 (`Drop.`, `ah`) | partly. `ah` is not in `Fillers.noise` (uh, um, erm, uhh, umm, hmm, mmm); adding it is one line. `Drop.` is an ASR hallucination at the end of a sentence; no pass targets that and none should guess. |
| punctuation | 4 (+, ×2, −, ×2) | no. No deterministic pass adds or removes commas; commas come from the ASR, and the prompt's "remove commas that only mark a pause" is the only comma logic in the path. |
| case | 5 in 2 rows (`Aur Hai Ho Kya` → lowercase; `The demo` → `the demo`) | no. No case pass exists beyond sentence-initial capitalisation in Fillers and names in TermMatcher; the ASR capitalises code-switched words as if they were names. |
| other | 0 | rule six makes this class empty by construction |

### 3. Cost

Polish per call, 90 ungated rows, greedy: **median 0.603 s, p95 0.963 s, max
2.015 s; 25 of 90 calls (28%) over the 0.65 s release budget** (C 6, D 10, E 9).
The audit's L6 proxy over the same 20 real rows (2026-08-21): as measured median
1.594 s / p95 3.019 s; with polish at the greedy median on the rows that
polished, **0.943 s / 1.326 s**; with the model removed, **0.340 s / 0.723 s**.

### 4. The 40-character line

Gated, 47 of 90 rows reached the model (C 10, D 12, E 25). It changed three of
them (D-U01 `Drop.`, D-R2-a `ah,`, E25 a comma) and was rejected or refused on
five (D-R1-a rule six, D-R1-b and D-R4-c framework refusals, E02 and E20 rule
six). Of the 43 rows at or under 40 characters, the ungated model moved one
closer (C14's comma) and one farther (D-U05's comma): the line costs nothing
measurable.

**On these 90 rows the model is not earning its latency: it spends a median
0.6 s per call, over budget on 28% of calls, to recover 4 corrections in 310
and add 1, and every edit it made was a comma, a case change, or one word
deleted.**

## 2026-08-22 — shadow equals live, minus the wait (`feat/model-into-shadow`)

`tools/textpath` on Set C, greedy, ungated, the shadow call (no budget)
against the live call (the 0.65 s `refineBudget`): identical `modelOutput`
on all 28 rows where both landed; C12 rejected by the guard in both; C17
landed in shadow (0.79 s) and missed the budget in live
(`budgetExpired:inner`). Shadow's median model time 0.507 s, recorded on
the row's shadow line and never waited for.

## 2026-08-22 — the two free edits: "ah" and the comma before a contrastive "not" (`feat/model-into-shadow`, prompt 5 task 2)

Both edits the model was credited with on 2026-08-22 ("what does the model
buy?"), made deterministically. `Fillers.noise` gains "ah". New Core pass
`Contrast.commaBeforeNot`: a comma before "not" only when it sits between
two value tokens (a number, a number word, a capitalised mid-sentence word,
a possessive pronoun; the right one may follow "the", "a", "an"); ordinary
negation is never a match. It runs after Fillers and Restatement in
`deterministicText`.

**Dry run on real speech first** (`tools/passprobe`, read-only over the
391 utterance rows in the founder's `captured.jsonl`): the comma pass would
change **0 rows**. All 38 mid-sentence "not"s in real dictation follow an
auxiliary or a pronoun ("are not", "it's not", "do not", "I'm not"); a value
contrast has not occurred in real speech yet. "ah" occurs in 0 real rows.
Nothing to tighten, nothing touched.

90 rows, model off (`textpath --off`), against the #46 deterministic column:

| set | #46 deterministic | now | rows changed |
|---|---|---|---|
| C | 18.22 (41) | **17.78 (40)** | C14 `153 not 135` → `153, not 135` (the comma pass) |
| D | 93.65 (177) | **91.01 (172)** | D-R2-a `postpone, ah, Ennani` → `postpone Ennani`; D-U04 `Naaku, Ah, File,` → `Naaku File,` (both "ah") |
| E | 37.86 (92) | 37.86 (92) | none |
| all | 47.18 (310) | **46.27 (304)** | |

Six corrections recovered deterministically, against the model's net four
(46.58). Protected-span rate on the off run: **0/61**. One honest note on
D-U04: its "Ah" was the Telugu word "aa" ("that"), which the en-US ASR
rendered as an English filler; the score still improved because "Ah" never
matched "aa", but in code-switched speech "ah" can be a word. English-only is
the campaign's scope, and the row says so.

## 2026-08-22 — DOES THE MODEL REPAIR SPEECH? Set F, recorded, 30 rows (`measure/does-the-model-repair`)

Set F recorded by the founder (voiceprobe, built-in mic, 17:42-17:50),
transcribed with the same Apple en-US tool as Set C, kept verbatim in
`corpus/setF-asr-en_US.jsonl`. Three runs of `tools/textpath`, greedy:
off, live ungated (0.65 s budget, rule six), shadow (no budget). Stamp:
commit `85804a3`, prompt `e97958cb280f…`, model `instruct_3b … 15.0.0.13.102990`.

### Headline

| run | rows handled correctly | retractions heard / survived | span rate | corrections/100w |
|---|---|---|---|---|
| raw ASR | | 19 of 27 heard | | 103.07 (235) |
| off | 3 of 28 | 19 / 19 | 0/52 | 95.18 (217) |
| live ungated | 3 of 28 | 19 / 19 | 0/52 | 93.86 (214) |
| shadow | **4 of 28** | 19 / **18** | 0/52 | **83.33 (190)** |

The three "handled" rows in off are F22 and F23 (nothing retracted) and F19
(the ASR never heard "Jonnalagadda"). ASR misses: 19 spans in 14 rows, names
and number formats (Gangothri → "Gango 3", Vercel → "vessel", PostHog →
"post hog", Kizu → "Kizo", Aatram → "Atram", 3:15 → "315", $1,200 → "$1200",
1.26 → "126"); 8 of the 27 retracted values were never heard either.

### Who repaired what (shadow, per row)

Of 22 rows with a self-correction the ASR actually heard: **Restatement
repaired 0, the model repaired 4, neither 14**; 4 rows had nothing to
retract and 8 more had their retraction mangled by the ASR. The model's
four: F04 ("to production, scratch that, the deploy to staging" → the
staging clause; landed, 14 → 6 corrections), F07 ("$120 sorry $1200" →
"$1200"), F10 ("Ask Chetan? No, ask Aidan" → "Ask Aidan"), F21 (dropped
"on Thursday. No,"). **Three of the four were rejected by the guard** and
never landed: F07 by `numbersSurvived` (the retracted $120 "went missing"),
F10 and F21 by `negationsSurvived` (the marker "No" counted as a lost
negation). Four more correct repairs met the same two rules: F15 (930 →
1015), F16 (the marker "No"), F22 ("no, no"), F26 (125 → 126). So the guard
blocked seven correct repairs and caught two wrong ones: F30 kept the
retracted "Sarah" and dropped "Aidan" (`namesSurvived`, rightly) and F03
added "it is" (`noNewTokens`, rightly). Live landed only 3 of 30: 22 missed
the 0.65 s budget.

What Restatement would have needed for the model's four: it collapses only
a whole sentence said twice. F04 needs "clause, scratch that, clause" (cut
everything from the clause start to the marker); F07 needs "value, sorry,
value" (keep the later value of the same kind); F10 needs "phrase? No,
phrase" (restart after a marker); F21 needs "on X. No, on Y" (same
preposition, keep the later object). All four are the repair-marker grammar
of the campaign's phase 4, none of which exists.

What the model did on the 21 rows that landed: removed false starts and
restarts (F12 "Tell Sarah tell Sarah", F13 "hang on. The API key ends in",
F27 "My email, my email"), removed a marker without its clause (F14 kept
"Cancel the subscription today" and dropped "Scratch that."), the F04
repair, a comma dropped (F02), and one row worse: F24 gained a comma
(7 → 8). It touched no protected span: rate 0/52 on every run.

### Cost

Shadow, per call: **median 0.684 s, p95 1.089 s, 18 of 30 over the 0.65 s
budget** (median utterance 11 words). Live landed 3 of 30 inside the budget.

**On messy speech the model repairs too little to go back on the path: 4
of 19 heard self-corrections, 3 of them then killed by its own guard, at
0.68 s a call with 60% of calls over budget; the repairs it does make are
the phase 4 marker grammar, which belongs in a deterministic pass.**

## 2026-08-22 — REPAIR MARKERS, DETERMINISTICALLY: Set F off, 95.18 → 44.74 (`feat/repair-markers`, prompt 7 tasks 1 and 2)

New Core pass `Repair` (grammar in its header, ruled by the founder before
any code: VALUE / PHRASE / CLAUSE over the markers no, no wait, no no,
sorry, I mean, scratch that, wait, actually, make that, rather; `wait`
alone VALUE-only with punctuation both sides; pronouns a fourth value
shape; the echo rule on either side of LEFT; fillers transparent; runs
BEFORE Fillers). `Restatement` gains the prefix restart (later run kept).

**Dry run on real speech first** (`tools/passprobe`, read-only, the 391
rows of the founder's `captured.jsonl`): `Repair` would change **0 rows**
(real dictation so far has no marker-shaped self-correction). The prefix
rule as ruled (gap of four) changed 21 rows and about half were not
restarts: coordination ("local or can be hybrid", "turn it on and turn it
off", "he was sad, and he called") and lists ("in terms of effects, in terms
of sound, in terms of music"). Tightened until only self-corrections moved:
gap of two (every Set F restart fits), no conjunction in the gap or opening
the run, the second copy after a comma or directly after the first, a third
copy within the window on either side means a list. Result: **13 rows**,
all stutters or restarts ("I don't, I don't", "as well as well as", "I was,
I was", "where it may, where it gives", "Look at this, look at, look at",
"it will you know, it will"), plus the old whole-sentence rule's one row.

**Set F, model off** (same raw ASR as #48):

| | #48 off | now |
|---|---|---|
| rows handled correctly | 3 of 28 | **16 of 28** |
| retractions heard / survived | 19 / 19 | 19 / **4** |
| corrected values present | 17 of 26 | 17 of 26 |
| protected-span mutation rate | 0/52 | **0/52** |
| corrections per 100 words | 95.18 (217) | **44.74 (102)** |

What fired, per row: VALUE on F01, F02, F03, F05 (twice), F07, F10 (echo
"ask"), F11, F12 (echo "tell"), F13, F15, F20, F21 (echo "on"), F23 (echo
"access"), F24 (first marker only), F27, F29; PHRASE on F17, F19, F22, F26;
CLAUSE on F04, F14; the prefix restart on F21 ("I can't make it. I, okay,")
and F30 ("Priya, and Sarah, Priya, and"). The four survivors are the
grammar's stated edges: F06 (a pause with no marker), F08 (a restart that
does not repeat the clause's opening), F12 (the ASR wrote "Sarah" for both
names), F24 (the second marker is a bare "wait." with punctuation on one
side only; the first firing leaves "3" as the surviving value, so this row
got worse by one word). F27's VALUE is the documented partial repair
("Chetan at Jonalagada 8800 at gmail.com"). The remaining corrections are
the ASR's (19 spans in 14 rows never arrived) and "hang on." (not a marker).

**Sets C, D, E, model off:** 0 rows changed against the #47 deterministic
baseline; Set C rate 0/61. Compare the model in shadow on the same set
(#48): 83.33 corrections per 100 words, 4 of 28 handled, at 0.68 s a call.

**Chain atomicity (ruled after the numbers above):** markers that share a
value resolve together or not at all. F24's chain ("No," then a bare
"wait." with punctuation on one side) now ships verbatim instead of
half-repairing to "3". Re-run: the same 13 real rows; Set F handled 16 of
28 (F24 was never counted as handled, its "3" survived either way),
retractions surviving 4, rate 0/52, corrections per 100 words **46.05
(105)**: F24 back at its raw seven costs three. C, D, E still 0 changed.

### Task 3: the guard stops counting a marker "no" as a negation

`FidelityGuard.negationsSurvived` now takes the scorer's rule: the output's
negation count must fall within [input minus the "no" markers `Repair`
identified, input]. Identified = matched as a marker AND given a valid
shape, applied or chain-abandoned (`Repair.identifiedNegationMarkers`);
"no" as a determiner has no shape and still counts. Tests pin a marker
removed (free), a determiner removed (rejected), and the two Set F rows
where the names rule is now the wall ("Chetan", and "Thursday" read as a
name).

Shadow on Set F, rejections before and after:

| | before (#48: no Repair, plain count) | after (Repair in front + the range) |
|---|---|---|
| rejected | 9: negationsSurvived 4, numbersSurvived 3, noNewTokens 1, namesSurvived 1 | **1: F16 negationsSurvived** |
| model changed the text | 21 rows | 3 rows (F02 a comma, F13 the "hang on." restart, F24 a comma) |
| handled / survived / rate | 4 of 28 / 18 / 0/52 | 16 of 28 / 4 / 0/52 |

Stated plainly: eight of the nine rejections vanished because `Repair` now
removes the markers before the model sees the text, so the model has
nothing to repair and echoes the repaired text; the range itself was not
exercised on this set (no row where the model removed a marker Repair had
identified but left). F16's "No," has no valid shape (the restart "the
post hog dashboard" does not repeat the clause's opening), so the rule
still calls the model's removal of it a lost negation. Median model time
0.649 s. The corpus record of the model is now honest about markers; what
lands is unchanged (shadow).

## 2026-08-23 — the ear stops following ghosts, and the pause dots settle (`fix/ear-and-ellipses`)

Born from a live failure: at 14:28 the founder's iPhone offered itself
over Continuity as "Cj Microphone", became the system default, won the
automatic choice, then vanished; every hold after it heard nothing, and
no notification told the ear (AVAudioEngineConfigurationChange fires only
for the engine's own configuration). Three changes, one commit each:

1. `InputChoice.Device.isPhoneLink` (CoreAudio transport 'ccwd'/'ccwl'):
   a phone's mic is exiled from automatic choice like the conferencing
   loopbacks; a pin still wins. The name can never identify it: it is
   named after the owner.
2. Two CoreAudio listeners on the hardware object (device list, default
   input) route into the existing `devicesChanged()`, which already
   rebuilds when the bound device vanished or something better appeared.
3. `Guardrail.settlingEllipses`: the transcriber's pause dots ("...",
   "…") settle deterministically: full stop before a capitalised letter
   or at the end, comma before a lowercase letter; a single period is
   never touched. Founder's ruling 2026-08-23: "when I am not talking,
   it was putting dots. I don't want that." Dry run over the 396 real
   rows: **17 changed, every one the pause pattern**, no decimal, path
   or version touched; two read stiffly ("the movie was. Marvelously
   shot") but truthfully, and better than dots.

## 2026-08-27 (evening): the two small fixes (`fix/names-and-commas`)

The founder chose causes 1 and 3 of the measurement above: "both small
fixes first." One behavior change per commit, both pure Core, 273 tests
green (4 new).

### Task 1: a contact name can never eat an everyday word

`TermMatcher.resolve` gains a hard refusal ahead of the confidence gate:
a heard word on the new ~950-word `EverydayWords` list is never rewritten
on sound alone. "that"/"Thota" and "short"/"Sharat" both sit at phonetic
similarity 1.00 and inside the 25% length tolerance, so no floor could
ever have separated them; ordinariness is the only axis that does. Cost
verified zero: the 2026-08-15 sweep's eight true repairs all have
non-words on the heard side and all still fire (pinned). The alias path
is deliberately untouched, so a name heard as a real word remains
learnable from the user's own typed correction. The corpus score cannot
move from a checkout (vocabulary is empty by design), so the guard is
pinned by unit tests rather than a score delta.

### Task 2: a filler dying between two clauses leaves one comma

`Fillers.droppingPauseComma` now keeps the earlier comma when the word
after the removed filler opens a clause (subject pronouns and their
contractions, `clauseOpeners`). Dry-run, old pass against new, passprobe
over the real corpus:

| set | rows changed | reading |
|---|---|---|
| 19 schema-3 raw rows | **1** | the target: "on the top, we need to improve the design." |
| 415 landed outputs | **3** | all better; two are old bugs where the eager comma-drop had BLOCKED a downstream "you know" removal ("close you know, I don't" now "close, I don't") |
| scripted set C | 0 | the 08-20 sparse-commas ruling holds |
| scripted set D | 0 | same |

The cascade in the two "blocked aside" rows is worth naming: keeping the
boundary comma preserves exactly the punctuation evidence the aside rule
gates on, so removing fillers left-to-right stops destroying its own
downstream conditions.

Not addressed here, still queued from the measurement: the shadow polish
(cause 2, needs the prewarm/budget arc) and the ear's noUndoHere discards
(cause 4).
