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
