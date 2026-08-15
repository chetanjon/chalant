# Phase 0: SDK ground truth

Measured 2026-08-15 against the installed SDK and this hardware. Where this file
disagrees with any research document, **this file wins** and the document is wrong.

```
macOS            27.0 (26A5378n)
Xcode            26.6 (17F113)
SDK              MacOSX26.5.sdk        <-- note: SDK is 26.5, OS is 27.0
Swift            6.3.3
Hardware         MacBook Air, Mac15,12, Apple M3, 8 cores, 16 GB
Interface dump   verification/sdk_speech_interface.txt (682 lines, arm64e-apple-macos)
                 verification/sdk_foundationmodels_interface.txt (1501 lines)
Raw results      verification/raw/meta_*.json
Probe            verification/metaprobe.swift
```

The SDK is a minor version behind the OS. Runtime behaviour can exceed what the SDK
header describes: `mul-IN` is available at runtime on macOS 27 while this SDK is 26.5.

---

## 1. Symbol table

| Symbol | Status | Real signature / note |
|---|---|---|
| `SpeechAnalyzer` | PRESENT | **An `actor`.** `modules` is actor-isolated; `await` it. |
| `SpeechTranscriber` | PRESENT | `: SpeechModule, LocaleDependentSpeechModule` |
| `DictationTranscriber` | PRESENT | `: SpeechModule, LocaleDependentSpeechModule` |
| `SpeechDetector` | PRESENT | `final class SpeechDetector : Speech.SpeechModule` — **it does conform.** |
| `SpeechModule` | PRESENT | `protocol SpeechModule : AnyObject, Sendable` |
| `AnalysisContext` | PRESENT | `final class AnalysisContext : Sendable` |
| `contextualStrings` | PRESENT | **`[ContextualStringsTag: [String]]`, a dictionary, not `[String]`.** Only tag defined: `.general`. |
| `setContext(_:)` | PRESENT | `func setContext(_ newContext: AnalysisContext) async throws` |
| `ContextTag` | **ABSENT** | The type is `AnalysisContext.ContextualStringsTag`. |
| `transcriptionConfidence` | PRESENT | `ResultAttributeOption.transcriptionConfidence`; attribute `AttributeScopes.SpeechAttributes.ConfidenceAttribute`, `Value = Double` |
| `audioTimeRange` | PRESENT | `ResultAttributeOption.audioTimeRange`; attribute `TimeRangeAttribute`, `Value = CMTimeRange` |
| `alternativeTranscriptions` | PRESENT | `ReportingOption.alternativeTranscriptions` |
| `fastResults` | PRESENT | **`ReportingOption.fastResults` — in no research document.** |
| `etiquetteReplacements` | PRESENT | The only `TranscriptionOption`. **This is the profanity-masking knob the research listed as NOTHING FOUND.** |
| `isFinal` | PRESENT | On `SpeechModuleResult`, not on `SpeechTranscriber.Result` directly. |
| `AssetInventory` | PRESENT | `status(forModules:)`, `assetInstallationRequest(supporting:)` |
| `maximumReservedLocales` | PRESENT | **Measured value: 5** |
| `reservedLocales` | PRESENT | Measured: `[]` |
| `reserve(locale:)` | PRESENT | Returned `false` for `mul_IN` and did not block use |
| `allocatedLocales` | **ABSENT** | Architecture must not assume it |
| `deallocate(locale:)` | **ABSENT** | `release(reservedLocale:)` exists instead |
| `bestAvailableAudioFormat` | PRESENT | Two overloads, one taking a `naturalFormat` |
| `SFSpeechLanguageModel` / `SFCustomLanguageModelData` | PRESENT | `macOS 14+`, the legacy custom-LM path |

### The three enums, in full

```
TranscriptionOption   = { etiquetteReplacements }
ReportingOption       = { volatileResults, alternativeTranscriptions, fastResults }
ResultAttributeOption = { audioTimeRange, transcriptionConfidence }
```

### `SpeechTranscriber.Result`

```swift
let range: CMTimeRange
let resultsFinalizationTime: CMTime
var text: AttributedString
let alternatives: [AttributedString]   // INCLUDES the primary at index 0
var isFinal: Bool                      // via SpeechModuleResult
```

---

## 2. Presets, measured

| Preset | reporting | attributes |
|---|---|---|
| `transcription` | none | none |
| `transcriptionWithAlternatives` | alternativeTranscriptions | none |
| `timeIndexedTranscriptionWithAlternatives` | alternativeTranscriptions | audioTimeRange |
| **`progressiveTranscription`** ← what the app ships | fastResults, volatileResults | **none** |
| `timeIndexedProgressiveTranscription` | fastResults, volatileResults | audioTimeRange |

**Consequence: `AppleTranscriber.swift:42` requests no attributes and no alternatives.
The app currently discards confidence, timings and the N-best list entirely.** No preset
combines volatile results with alternatives *and* confidence, so the explicit
`init(locale:transcriptionOptions:reportingOptions:attributeOptions:)` is required.

---

## 3. V2 — is `transcriptionConfidence` populated?

**Answer: YES, and the contract is crisp.** Directive outcome 3.

| File | final runs with confidence | volatile runs with confidence | range | distinct |
|---|---|---|---|---|
| `te-1.caf` (founder, Telugu-English) | **7/7** | 0/18 | 0.104 – 0.727 | 7 |
| `en-1.caf` (founder, English) | **19/19** | 0/15 | 0.011 – 0.995 | 19 |
| `names.aiff` (synthesized) | **18/18** | 0/32 | 0.546 – 0.998 | 18 |

**Confidence is present on every finalized run and never on a volatile one.** Values vary
widely and are all distinct, so it is neither absent nor degenerate. Since insertion fires
on finalized results only, confidence is available exactly where the product needs it.

**Not yet answered:** whether it *means* anything. The directive requires AUC against
ground-truth per-word error before confidence may drive routing, with a 0.70 bar. **That
needs the corpus.** Until then confidence is a signal, not a probability, per spec §31.1.

---

## 4. V3 — alternatives granularity and volume

**Answer: per whole result, never per token, and thin.**

`alternatives[0]` is always the primary, so a count of 1 means **zero** real alternatives.

| File | real alternatives per final result | finals with any |
|---|---|---|
| `te-1.caf` | 0, 1, 0, 2 | 2 of 4 |
| `en-1.caf` | 0, 4 | 1 of 2 |
| `names.aiff` | 0, 2, 1, 0, 1, 0 | 2 of 6 |

**Most finalized results carry no alternative at all.** Post-ASR rescue depends on the
correct answer already being in the N-best list, and usually there is no list.

**But the one useful case is exactly the target case.** For `en-1`, primary `" Shalan rule."`
against truth "Chalant", the alternatives were:

```
" Shalan rule."   " Shalan Rule."   " Shalan."   " Chalan."   " Shalan rule?"
```

`"Chalan"` is nearer the truth than the primary. So the list is thin but occasionally
carries a rare-term rescue.

**Architectural consequence:** the secondary engine moves from optional toward necessary.
Spec §12.1 treats Parakeet as adaptive verification; on this evidence, N-best rescue alone
cannot carry rare-term correction. Quantify on the corpus before committing.

---

## 5. Timing — the pause question

**`.audioTimeRange` is present on 100% of runs, including volatile ones, and is useless
for detecting pauses.**

| File | runs with a time range | inter-word gaps | gaps that are EXACTLY zero |
|---|---|---|---|
| `te-1.caf` | 25/25 | 3 | **3 (100%)** |
| `en-1.caf` | 34/34 | 17 | **17 (100%)** |
| `names.aiff` | 50/50 | 12 | **12 (100%)** |

**32 of 32 inter-word gaps are exactly zero.** Word A's end equals word B's start in every
single case, including across audible silence. The ranges describe segment alignment, not
speech timing.

This confirms `CLAUDE.md` §0.4 on this hardware and **refutes CJ spec §3.4 and §9.2**,
which build the punctuation differentiator on this attribute. Pause features must come
from VAD over the audio we already own.

One research claim is now stale in our favour: volatile results were reported to *lack*
timing attributes. Here they carry them 100% of the time. They still lack confidence.

---

## 6. Contradictions with the research documents

See `DOCUMENT_CONFLICTS.md`. Rows resolved by this pass: 1 (confirmed), 2 (refuted, the
SDK bug is fixed), 3 (unchanged), 4 (refuted by runtime measurement).
