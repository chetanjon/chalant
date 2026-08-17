# STAGE 1 DIRECTIVE

Copied verbatim into the repository on 2026-08-16 from
`~/Downloads/voice chalant docs/DICTATION_VERIFICATION_DIRECTIVE.md` (dated
2026-08-14), because the founder's session directives refer to it by this name
and it lived only in Downloads. Below the decisions block, the text is the
original, unchanged.

## DECISIONS THAT AMEND THIS DIRECTIVE (founder, 2026-08-16)

1. **Stage 3, personalisation, is OPEN.** Names-learning (the correction
   observer and the learned-terms ledger, shipped in 1.16.0) stays ON by
   default. Nothing in this directive is to be read as keeping it closed. The
   standing rule remains: the app never asks the user to spell, pronounce,
   record or enrol anything; that is what the correction learner is for.
2. **The L6 target is UNDER REVIEW, not 500 ms**, pending the measured
   comparison of three options (cleanup off the critical path; cleanup only
   above N characters; keep as is and change the target). Until that decision
   lands, L6 is reported, not judged.

---

# DICTATION VERIFICATION DIRECTIVE

**For: Claude Code, run against the Chalant repository**
**Status: execute in order. Do not skip to implementation.**

---

## PURPOSE

A deep research pass produced an architecture recommendation for Chalant's voice dictation system. Two of its load-bearing claims come from beta-era developer forum posts, not from shipping documentation, and neither has been verified on this machine:

1. `SpeechTranscriber` ignores `contextualStrings` / `AnalysisContext` entirely. Only `DictationTranscriber` honors them.
2. `transcriptionConfidence` may not be meaningfully populated for `SpeechTranscriber`.

If claim 1 holds, all context injection must move to a post-ASR resolver and the entire biasing strategy changes.
If claim 2 holds, confidence-based routing has no input signal and the risk estimator must be rebuilt on disagreement features instead.

Months of build sequencing depend on these two answers. Get them first.

This directive also establishes the evaluation corpus and the baseline numbers that every future change gets measured against. Right now there is no baseline, which means no change can be proven to help.

---

## RULES OF ENGAGEMENT

Read these before starting. They are not optional.

1. **Never invent an API.** If a symbol, property, or method does not appear in the Phase 0 SDK dump, stop and report. Do not guess names based on what seems reasonable. The Swift sketches in this document are structural illustrations and their symbol names may be wrong.
2. **The installed SDK is the source of truth.** If it contradicts this document, the SDK wins. Record the contradiction explicitly in the results file.
3. **Do not refactor working code.** This is an audit and measurement pass. The only code you add is a new test target or CLI target. Existing app targets are read-only.
4. **Do not add third-party dependencies.**
5. **Report raw data before interpreting it.** Every experiment writes its raw output to disk. Conclusions go in a separate section and must cite the raw file.
6. **A negative result is a real result.** If an experiment shows no effect, that is the finding. Do not tune the harness until it produces an interesting outcome.
7. **STOP at the checkpoints.** Two phases end with a hard stop and a report. Wait for a human decision before continuing past them.

---

## PHASE 0: SDK GROUND TRUTH

Establish what the installed SDK actually exposes. Everything downstream references this.

### 0.1 Record the environment

```bash
sw_vers
xcodebuild -version
xcrun --sdk macosx --show-sdk-path
xcrun --sdk macosx --show-sdk-version
system_profiler SPHardwareDataType | head -20
```

Capture all output. Every result file in this directive must carry this environment block, because Apple ships speech assets and Foundation Models updates independently of the app and results expire silently.

### 0.2 Dump the Speech framework interface

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)

# Swift interface files
find "$SDK/System/Library/Frameworks/Speech.framework" -name "*.swiftinterface" -exec echo "=== {} ===" \; -exec cat {} \;

# Objective-C headers, if present
ls -la "$SDK/System/Library/Frameworks/Speech.framework/Headers/" 2>/dev/null
```

Write the full interface to `verification/sdk_speech_interface.txt`.

### 0.3 Confirm the symbols this architecture depends on

Grep the dump for each of the following. For every symbol record: present or absent, exact spelling, exact type signature, availability annotation, and any deprecation notice.

**Core types**
- `SpeechAnalyzer`
- `SpeechTranscriber`
- `DictationTranscriber`
- `SpeechDetector`

**Context surface (claim 1 depends on this)**
- `AnalysisContext`
- `contextualStrings`
- `setContext`
- any `ContextTag` or equivalent key type

**Result metadata (claim 2 depends on this)**
- `transcriptionConfidence`
- `audioTimeRange`
- `alternativeTranscriptions`
- the `ReportingOption` and `AttributeOption` option sets in full
- the `Result` type, and whether alternatives live on the result or on individual runs

**Asset management**
- `AssetInventory`
- `maximumReservedLocales`
- `reservedLocales`
- `allocatedLocales`
- `assetInstallationRequest`
- `release(reservedLocale:)`
- `deallocate(locale:)`

**Custom language model path**
- `SFSpeechLanguageModel`
- `SFCustomLanguageModelData`
- `customizedLanguage`
- `prepareCustomLanguageModel` variants, and which are deprecated

Also dump the Foundation Models interface the same way:

```bash
find "$SDK/System/Library/Frameworks/FoundationModels.framework" -name "*.swiftinterface" -exec cat {} \; > verification/sdk_foundationmodels_interface.txt
```

### 0.4 Output

Write `verification/PHASE0_SDK_TRUTH.md`: a table of symbol, present/absent, signature, availability, notes. Flag every symbol that this architecture assumes exists but the SDK does not expose.

---

## PHASE 1: REPOSITORY AUDIT

Read-only. Produce a map of what exists before changing anything.

### 1.1 Map the engine and capture layer

For each item, record: file path, class or function, current behavior, and whether it is verified in code or inferred.

- Which transcriber class is instantiated: `SpeechTranscriber` or `DictationTranscriber`. This single answer determines whether the app can use contextual biasing at all.
- Exact init options passed: transcription options, reporting options, attribute options. Note specifically whether `.volatileResults`, `.alternativeTranscriptions`, `.audioTimeRange`, and `.transcriptionConfidence` are requested.
- Whether the code reads per-run attributes off the result `AttributedString`, or discards them and keeps only the plain string. Discarding is the most common and most costly mistake here.
- Audio path: `AVAudioEngine.installTap` or `AVCaptureSession`. Buffer size. Whether audio is converted to the analyzer's preferred format, and where.
- Whether `setVoiceProcessingEnabled` is called, and with what value.
- Whether `SpeechDetector` is used, and its sensitivity setting.
- `AssetInventory` handling: reservation, allocation, download progress, deallocation, error paths.
- Analyzer lifecycle: whether analyzers are torn down. There is a reported failure at roughly the third concurrent analyzer instance ("maximum number of recognizers reached"). Determine whether this app can hit it.

### 1.2 Map the intelligence layer

- Every Foundation Models call site. For each: the prompt, the schema if any, and critically whether its output can overwrite transcript words or only select among existing candidates.
- Parakeet / FluidAudio: when it runs, model version and hash, memory footprint, whether it is gated on anything.
- Confidence usage: is a raw ASR confidence value trusted directly anywhere? Is there any calibration layer?
- Context sources currently collected, and where they are injected. Flag any context being fed into `SpeechTranscriber`, since Phase 3 may prove that is a no-op.

### 1.3 Map insertion and learning

- Insertion method(s): CGEvent paste, AX API, AppleScript. Which is primary, which are fallbacks.
- Clipboard save and restore: does it preserve multiple pasteboard formats, or only plain text?
- Target verification: does the code confirm the focused element is unchanged between capture and insertion?
- Secure Input: is it detected at all?
- Correction observer: does one exist? What text changes does it treat as user corrections? What guards exist against counting autocorrect, Grammarly, IDE autocomplete, or collaborative-editor mutations as corrections?
- Personalization store: schema, persistence, whether learned entries have states or are flat.

### 1.4 Map instrumentation

- What latency spans are currently measured, if any.
- Whether any benchmark harness or golden corpus exists.
- Logging: what is captured per dictation, and whether it is enough to reconstruct a failure after the fact.

### 1.5 Output

Write `DICTATION_ARCHITECTURE_CURRENT.md` containing:

- A component table: component, file, current behavior, API surface used, known limitations, verification status.
- An end-to-end sequence diagram of one dictation, hotkey down through text inserted.
- The concurrency model: actors, tasks, cancellation paths.
- Fragile areas, duplicated logic, performance risks, technical debt.
- Features already working that should be preserved.
- Pieces that should eventually be redesigned, with the reason.

Do not propose rewrites in this file. Describe what is.

---

## PHASE 2: BUILD THE EVALUATION CORPUS

Nothing in Phase 3 or 4 can run without this, and no external source can provide it. It has to be CJ's voice, CJ's vocabulary, CJ's room.

### 2.1 Corpus design

Three sets, 100 utterances total. This is deliberately small. It is enough to detect large effects, which is all Phase 3 needs.

**Set A: rare-term set, 40 utterances.**
Each contains one to three terms drawn from CJ's actual working vocabulary. These are the terms that context biasing is supposed to fix, so they must be terms ASR plausibly gets wrong.

Seed list (extend from the repo's own symbols and the user's project names): Chalant, Kizu, Supabase, SwiftUI, SwiftData, Parakeet, FluidAudio, contextualStrings, AVAudioEngine, SpeechAnalyzer, SpeechTranscriber, AnalysisContext, Claygent, Prybar, Anthropic, PostHog, Vercel, Tempe, Jonnalagadda, Wispr, TestFlight, NSPasteboard, CGEvent, AXUIElement.

**Set B: normal prose control, 30 utterances.**
Ordinary sentences containing zero rare terms. This set exists to catch regression. Context biasing that improves Set A while damaging Set B is a net loss, and without Set B you will not see it.

**Set C: semantic torture, 30 utterances.**
Meaning-critical content where a plausible-sounding substitution is unacceptable:
- negation: "do not deploy to production"
- close numbers: fifteen vs fifty, one hundred twenty vs twelve hundred
- environments: staging vs production
- near-identical names: Sarah vs Sara
- times: three fifteen vs three fifty
- money: one hundred twenty dollars vs twelve hundred dollars
- paths and commands: "slash users slash chetan slash projects"
- destructive operations: "drop the users table", "force push to main"

### 2.2 Recording protocol

- One session, one room, quiet conditions, built-in Mac microphone.
- Save each utterance as a separate uncompressed file at the native input sample rate. Do not normalize, do not denoise, do not trim beyond leading and trailing silence.
- Record the exact ground truth transcript at recording time, not afterward from memory.
- Note anything unusual per utterance (a stumble, a cough, a false start). Do not re-record these. Spontaneous speech artifacts are signal, not noise.

### 2.3 Manifest format

Write `corpus/manifest.json`:

```json
[
  {
    "id": "A001",
    "audio": "corpus/audio/A001.wav",
    "truth": "open the Supabase dashboard and check the auth logs",
    "set": "A",
    "rare_terms": ["Supabase"],
    "protected_spans": [],
    "notes": ""
  },
  {
    "id": "C007",
    "audio": "corpus/audio/C007.wav",
    "truth": "do not deploy to production before three fifteen",
    "set": "C",
    "rare_terms": [],
    "protected_spans": ["do not", "production", "three fifteen"],
    "notes": "negation plus environment plus time"
  }
]
```

`protected_spans` is the substring list that a cleanup layer must never alter. It drives the protected-span mutation rate metric.

### 2.4 Output

`corpus/manifest.json` plus audio files, and `verification/CORPUS_README.md` describing how it was recorded and how to extend it.

---

## PHASE 3: THE VERIFICATION EXPERIMENTS

Build one offline CLI target. It reads the manifest, feeds file audio through the analyzer, and writes raw JSON results. File-based ingestion rather than live microphone, so runs are deterministic and repeatable.

**Before writing any harness code, resolve every symbol name against `verification/PHASE0_SDK_TRUTH.md`. The sketches below are structural only and their names may not match the SDK.**

### V1: Does `SpeechTranscriber` honor contextual strings?

This is the highest-stakes question in the entire project.

**Hypothesis.** `SpeechTranscriber` ignores contextual strings. `DictationTranscriber` honors them.

**Design.** Four conditions across all 40 Set A utterances plus all 30 Set B utterances:

| Condition | Transcriber | Context |
|---|---|---|
| A | SpeechTranscriber | none |
| B | SpeechTranscriber | contextualStrings = the rare-term seed list |
| C | DictationTranscriber | none |
| D | DictationTranscriber | contextualStrings = the rare-term seed list |

Conditions C and D are the positive control and they are not optional. Without them, a null result in B is indistinguishable from a broken harness.

Run each condition three times over the same audio to establish whether output is deterministic. Note any run-to-run variation before comparing conditions.

**Structural sketch, names unverified:**

```swift
// Resolve every symbol below against PHASE0_SDK_TRUTH.md first.
// If a name does not appear there, stop and report.

func runCondition(
    manifest: [Utterance],
    useDictationTranscriber: Bool,
    contextTerms: [String]?
) async throws -> [TranscriptResult] {

    var results: [TranscriptResult] = []

    for utterance in manifest {
        // 1. Construct the transcriber with the metadata options that matter.
        //    Request alternatives, time ranges, and confidence explicitly.
        //
        // 2. If contextTerms is non-nil, populate AnalysisContext and
        //    apply it before feeding audio. Record whether the call
        //    succeeds, throws, or silently no-ops.
        //
        // 3. Feed the audio file as an AnalyzerInput stream.
        //
        // 4. Collect finalized results only. Capture the full
        //    AttributedString, not the plain string.
        //
        // 5. Serialize: plain text, every run with its attributes,
        //    utterance-level alternatives, wall-clock duration.
    }

    return results
}
```

**Metrics.**
- Byte-exact transcript equality between A and B, per utterance.
- Rare-term recall on Set A: fraction of expected rare terms appearing exactly, case-sensitive.
- Set B word error rate, to detect regression.
- The same three for C versus D.

**Decision rules. Follow these exactly.**

- **B is byte-identical to A on all 70 utterances, AND D differs from C.** Claim 1 confirmed. Context cannot enter `SpeechTranscriber`. All biasing moves to a post-ASR resolver, plus an optional `DictationTranscriber` + `SFSpeechLanguageModel` path. **This is the expected outcome.**
- **B differs from A with rare-term recall improved.** Claim 1 is outdated, contextual biasing is live on the better model. This is a significant win and the architecture should be re-planned around it. Report immediately.
- **B differs from A with rare-term recall unchanged or worse.** Context is being consumed but is harmful or neutral. Investigate over-biasing before drawing conclusions.
- **B is identical to A AND D is identical to C.** Do not conclude anything. The harness is suspect, because the positive control failed. Debug the context-application path first, then rerun.

### V2: Is `transcriptionConfidence` actually populated?

**Hypothesis.** Confidence is either absent or constant, and therefore unusable for routing.

**Design.** Reuse condition A output. For every run in every finalized `AttributedString`, dump all attributes present. Do not look only for the confidence key. Dump everything, so you discover metadata nobody expected.

**Three outcomes.**
1. The key is absent. Confidence-based routing is impossible. The risk estimator must be built entirely on alternative disagreement, secondary-engine disagreement, rare-term flags, and acoustic features.
2. The key is present but every value is identical or degenerate (all 1.0, all 0.0). Functionally the same as outcome 1. Record the constant.
3. The key is present with varying values. Now measure whether it means anything: compute AUC of confidence for predicting per-word error against ground truth, across the full corpus.

**Success threshold for outcome 3.** AUC above 0.70 makes confidence a usable routing feature. Between 0.55 and 0.70 it is weak and needs calibration before use. Below 0.55 treat it as noise and discard it.

### V3: Alternatives granularity and volume

Rides along with V2, essentially free.

Confirm whether `alternativeTranscriptions` are delivered per utterance or per span, how many are returned, whether the count is configurable, and whether alternatives ever contain a rare term that the primary hypothesis missed. That last question is the one that matters, because post-ASR rescue depends entirely on the correct answer already being present in the N-best list. If it never is, rescue cannot work and the secondary engine becomes mandatory rather than optional.

Report: fraction of Set A rare-term misses where the correct term appears in any alternative.

### V4: Asset and recognizer limits

- Read `AssetInventory.maximumReservedLocales` at runtime and record the actual integer. Do not hardcode it anywhere in the app.
- Instantiate analyzers in a loop without tearing them down. Record the instance count at which failure occurs and the exact error. Then repeat with proper teardown and confirm the failure does not occur.
- Record asset storage location and size on disk, and behavior when a locale is deallocated and then requested again.

### V5: Audio tap reliability under device change

- Install a tap on the input node, log every buffer callback with a timestamp.
- Start recording on the built-in microphone. Mid-recording, connect AirPods. Log whether callbacks continue, stall, or stop.
- Repeat with a disconnect mid-recording.
- Repeat both with `AVCaptureSession` instead, if the repo has or can add that path cheaply.

Record: does `installTap` survive a device change on this macOS build? This determines whether the capture layer needs a rewrite.

### 3.6 Output and STOP

Write `DICTATION_VERIFICATION_RESULTS.md`:

- Environment block from Phase 0.
- One section per experiment: hypothesis, raw data file path, results table, decision-rule outcome.
- A single summary table: claim, verdict (confirmed / refuted / inconclusive), architectural consequence.
- Every contradiction between the SDK and the research report, listed explicitly.

**STOP HERE. Report and wait.**

V1's outcome changes the build plan. Do not begin implementing a context system before a human has seen this result.

---

## PHASE 4: BASELINE MEASUREMENT

Only after the Phase 3 stop is cleared.

There is currently no number describing how good Chalant's dictation is. Without one, no future change can be proven to help, and effort will go to whatever is most interesting rather than whatever is most broken.

### 4.1 Quality baseline

Run the full 100-utterance corpus through the current shipping pipeline, end to end, exactly as a user would experience it. Record:

- Word error rate, overall and split by set.
- Character error rate.
- Rare-term recall, exact and case-sensitive, on Set A.
- Protected-span mutation rate on Set C. This is the count of utterances where any protected span was altered. **Target is zero.** Any nonzero value is the single most important bug in the product.
- Semantic error rate on Set C: transformations that change meaning, whether or not WER moved.
- Punctuation F1 against ground truth.

### 4.2 Latency baseline

Instrument these six spans and report median and p95 across at least 20 live dictations:

| Span | From | To |
|---|---|---|
| L1 | hotkey down | first audio buffer received |
| L2 | first audio buffer | first volatile result |
| L3 | hotkey up | Apple finalized result |
| L4 | finalized result | resolver complete |
| L5 | resolver complete | insertion issued |
| L6 | hotkey up | text visible in target app |

L6 is the number the user actually feels. Everything else exists to explain L6.

> Amended 2026-08-16: the L6 TARGET is under review (see the decisions block at
> the top of this file). Measured on 48 live dictations that day, 1.16.0 as
> installed: median 0.87 s, p95 2.15 s, of which the on-device cleanup is
> ~0.55 s at the median.

### 4.3 Resource baseline

Peak RAM, sustained CPU, and energy impact during a 30 second dictation, measured separately for: Apple Speech alone, Apple Speech plus Parakeet, and Apple Speech plus Parakeet plus a Foundation Models call. Note the machine's total RAM and whether thermal throttling occurred.

### 4.4 Output

Write `DICTATION_BASELINE.md` with the environment block, all three baselines, and an explicit statement of which number is worst relative to its target. That number, not the most interesting research area, is where work goes next.

---

## OPEN DECISIONS: SURFACE, DO NOT DECIDE

These are product calls. Collect the evidence, present the trade-off, and let a human choose. Do not resolve them in code.

1. **Personal tool or shipping product.** Determines whether cold start, generic accents, multilingual support, and full evaluation rigor are needed at all. Personalization gets dramatically simpler with exactly one voice. Report which assumptions in the current code imply which answer.
2. **Sandboxing.** The AX insertion path requires a non-sandboxed build, which forecloses the Mac App Store and requires direct distribution, notarization, a self-hosted updater, and licensing. Report the current entitlements and what the chosen insertion path implies.
3. **Command versus dictation arbitration.** "new line", "delete that", "select all", "period". Does the system type those words or execute them? Report whether any arbitration logic exists today. This is a harder product problem than self-repair and users hit it constantly.
4. **Device tier matrix.** Foundation Models requires Apple Intelligence hardware. Parakeet needs roughly 600MB to 1GB plus first-run download. Report what an Intel Mac, an 8GB M1, and a current M-series machine can each actually run, and propose three tiers.
5. **Data policy.** The personalization store learns from text near the cursor. Report what is currently persisted, whether it is encrypted, retention behavior, and whether a user can inspect or delete it.
6. **Success thresholds.** Every metric in Phase 4 needs a ship bar. Propose targets based on the measured baseline, do not invent them in advance.

---

## DELIVERABLES CHECKLIST

- [ ] `verification/PHASE0_SDK_TRUTH.md`
- [ ] `verification/sdk_speech_interface.txt`
- [ ] `verification/sdk_foundationmodels_interface.txt`
- [ ] `DICTATION_ARCHITECTURE_CURRENT.md`
- [ ] `corpus/manifest.json` plus audio
- [ ] `verification/CORPUS_README.md`
- [ ] `verification/raw/` containing every experiment's raw JSON output
- [ ] `DICTATION_VERIFICATION_RESULTS.md` **← STOP after this**
- [ ] `DICTATION_BASELINE.md`

---

## THE PRINCIPLE THIS SERVES

The system's job is to recover the text the user intended to enter, using the strongest available evidence, with minimal latency and minimal need for correction. It is not to produce the prettiest version of what the user might have meant.

Evidence priority, highest to lowest: acoustic evidence, primary ASR hypothesis, primary ASR alternatives, ASR confidence and stability, timing and prosody, immediate application and document context, learned user vocabulary, correction history, secondary ASR evidence, language-model judgment.

The language model is the last reasoning layer, never the first transcription layer.

When uncertain, preserve the evidence-backed transcription rather than making an elegant guess.

This directive exists because most of that ordering is currently unverified assumption. Measure first.
