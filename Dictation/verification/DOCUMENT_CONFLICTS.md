# Where the governing documents contradict each other

Nine documents govern this build, written over five days by different research passes.
They disagree. This file resolves every disagreement found, with the evidence.

**Precedence, settled 2026-08-15:**

1. **Measurement on this machine** (`PHASE0_SDK_TRUTH.md`, `EVAL-LOG.md`) beats every document.
2. **`CLAUDE.md` Part 0** on platform facts. It is measured and reconciled from three passes.
3. **`CJ_Dictation_Intelligence_Build_Spec.md`** on intelligence architecture and the
   production hardening in §27 to §36, which are genuinely new and have no equivalent elsewhere.
4. **`CLAUDE.md` Part 1** remains the working contract regardless of the above.
5. The research reports and PDFs are evidence, not instructions.

The CJ spec is the newest document but **regressed on three platform facts** that Part 0
had already nailed down. Newer is not automatically righter.

---

## Resolved

### 1. Pause features must not come from `.audioTimeRange` — CJ spec is WRONG

- **CJ spec §3.4, §9.2:** "Apple already gives audio time ranges in transcript attributes.
  Use those before adding a custom acoustic model."
- **`CLAUDE.md` §0.4 and the deep-research report:** the attribute measures segment
  alignment, not silence.
- **Measured 2026-08-15: 32 of 32 inter-word gaps across three files are EXACTLY zero**,
  including across audible silence. Word A's end equals word B's start every time.
- **Resolution: Part 0 wins.** Pause features come from VAD over the audio we own. This is
  the punctuation differentiator, so getting it wrong would have cost a milestone.
- Stale in our favour: volatile results were reported to lack timing attributes. They carry
  them 100% of the time here. They still never carry confidence.

### 2. `SpeechDetector` composition — the RESEARCH is now WRONG, the CJ spec is right

- **`CLAUDE.md` §0.6 and Privacy-First §1.4:** "`SpeechDetector` cannot be composed with a
  transcriber (compile error). It is a final class not conforming to `SpeechModule`."
- **Measured:** the SDK declares `final public class SpeechDetector : Speech.SpeechModule`,
  and `SpeechAnalyzer(modules: [transcriber, detector])` **constructs successfully** with
  `modules.count == 2`.
- **Resolution: a real bug on an earlier point release, fixed by SDK 26.5.** The CJ spec's
  §2.1 pattern compiles. This does not change the §0.4 decision above: our own VAD is still
  required for pause timing, because the problem there is the *attribute*, not the detector.

### 3. `contextualStrings` does not bias `SpeechTranscriber` — unchanged, and the API shape is different from every document

- **CJ spec §2.3** builds a `ContextManager` around `AnalysisContext` as "a first-class ASR feature."
- **Apple engineer, forum 811083**, plus this repo's own §0.1 probe on this hardware:
  1/5 terms with bias, 1/5 without, byte-for-byte identical output. `DictationTranscriber`
  gets 3/5.
- **New, and in no document:** `contextualStrings` is `[ContextualStringsTag: [String]]`, a
  **dictionary keyed by tag**, not the flat `[String]` every document shows. Only `.general`
  is defined.
- **Resolution: Part 0 §0.1 wins.** Biasing is a post-ASR problem on Path B, or a
  `DictationTranscriber` decision on Path A. The corpus decides.

### 4. Indic locales exist on macOS 27 — the RESEARCH is WRONG

- **Research §4, Privacy-First, and the CJ spec's premise:** `hi_IN` and `te_IN` absent, no
  multilingual mode, therefore "treat Telugu as a native-script-preserving verbatim island."
- **Measured 2026-08-15 at runtime:** `SpeechTranscriber.supportedLocales` returns 45
  entries including `hi-IN`, `te-IN` and **`mul-IN`, whose macOS localized name is
  "Multiple languages (India)"**. Installing `mul_IN` pulled the whole Indic family in one
  download. On the founder's real voice, `mul-IN` transcribed Telugu-English and
  Hindi-English correctly and romanized, where `en-IN` returned fragmented mush.
- **Resolution: the engine path is open.** Code switching is no longer purely a vocabulary
  problem, and "verbatim island" is off the table. Whether `mul-IN` becomes the default is
  a corpus decision: it currently loses names (`Ravi` → `Rabi`), spells numbers out, emits
  no punctuation, and dropped a question marker.
- **Caveat:** the SDK is 26.5 while the OS is 27.0, so this is a runtime capability the
  headers do not describe. Re-verify on any OS change.

### 5. Corpus method — the DIRECTIVE is incomplete

- **Verification directive Phase 2:** 100 utterances, ground truth recorded at recording time.
- **`CLAUDE.md` Part 4** names the trap that design walks into: **do not read from a script.**
  Read speech and spontaneous speech are different acoustic phenomena; a scripted corpus
  "will make your app look excellent and tell you nothing."
- **Resolution:** take the directive's experimental structure (A rare-term / B ordinary-prose
  control / C locked semantic torture) and Part 4's *method* (spontaneous, real work,
  built-in mic, lid open, `desired` + `verbatim` columns, dev/holdout split, then frozen).
  Set B is the directive's best contribution: without an ordinary-prose control, a biasing
  change that helps rare terms while damaging normal speech is invisible.

### 6. Finalization latency — the forum reports do not reproduce here

- **Privacy-First §1.3:** ~2.2s without preheating, ~1.45s with `prepareToAnalyze()`, n=11.
- **This repo, measured:** finalize 0.017 to 0.20s; 0.06 to 0.30s end to end.
- **Resolution:** our hardware wins. Do not plan around the pessimistic figure, and do not
  publish ours either until the corpus produces a p95. Per §0.5 the safe claim today is
  *consistency*, not a millisecond number.

### 7. Pasteboard snapshot — the CJ spec omits a live risk

- **CJ spec §29.3** lists "pasteboard swap + synthesized Command-V" with no caveat.
- **Part 0 §0.2:** macOS 26 can alert or block a programmatic **read** of the general
  pasteboard. Our exposure is the snapshot read, not the write.
- **Resolution: Part 0 wins.** Use `NSPasteboard` `detect` methods for type inspection,
  wrap full-content snapshot in a capability that degrades gracefully, and never let a
  privacy prompt block the paste itself. **Untested on this machine.**

---

## Findings in no document at all

- **`ReportingOption.fastResults`** exists and is in `.progressiveTranscription`, which the
  app ships. Undocumented in every research pass.
- **`TranscriptionOption.etiquetteReplacements`** is the profanity-masking control. The
  Privacy-First report recorded Apple profanity behaviour as NOTHING FOUND; this is it.
- **`SpeechAnalyzer` is an `actor`.** `modules` is actor-isolated.
- **`alternatives[0]` is the primary**, so a count of 1 means zero real alternatives. Any
  code treating `alternatives` as a list of *other* candidates is off by one.
- **`allocatedLocales` and `deallocate(locale:)` do not exist.** The directive's symbol list
  assumes both. Use `reserve(locale:)` / `release(reservedLocale:)`.

## Open, needing the corpus

- Is confidence *calibrated*? Present and varying is not the same as meaningful. Directive
  bar is AUC > 0.70 against per-word error.
- Does the thin N-best list make a secondary engine mandatory rather than optional?
- `en-US` vs `en-IN` vs `mul-IN`, on corrections per 100 words.
