# Dictation: state of the build

Read-only audit, 2026-08-16, against `main` at `aa688d8`. Every claim below was
checked by reading the code. Where a claim needs the app actually running to
confirm, it says **unverified** rather than guessing.

**Scope note.** Chalant has two speech features and they are not the same thing.
`VoiceController` (`Chalant/Features/VoiceController.swift`) turns speech into
island commands. `Dictation` puts your words at the cursor. This audit is about
the second. Section 4 covers where they collide.

---

## 1. What works today

Verified by following the call path, not by reading comments.

### The hotkey is real and defensively written

`Dictation/ChalantDictationApp/Hotkey/EventTapMonitor.swift`

- A `CGEvent` tap on `.flagsChanged` only, `.listenOnly`, watching keycode 58
  (left Option) and the device-dependent flag `0x20` (`:20-24`, `:50`, `:106-109`).
  Using the device bit rather than `.maskAlternate` is what makes left and right
  Option distinguishable.
- The mask is built as `CGEventMask(1) << CGEventType.flagsChanged.rawValue`
  (`:50`) with a comment explaining that including the `tapDisabled` types would
  shift by `0xFFFFFFFE` and corrupt the mask into matching nothing. That is a
  real trap and it is handled.
- `tapDisabledByTimeout` / `ByUserInput` re-enable the tap (`:98-103`). Without
  this the hotkey dies silently after hours.
- The callback does no work: it hops to the main actor and returns (`:113-116`).

### Push-to-talk hold, with the release race handled

Hold, not toggle. `Dictation/Sources/ChalantDictationCore/Model/PushToTalk.swift`
is a pure state machine, and `DictationController` derives `isListening` from it
(`DictationController.swift:47`) so there is exactly one answer.

The genuinely hard case is covered: setup is async and takes ~180ms, so a release
landing inside that window used to be dropped. `key.ready()` at
`DictationController.swift:219-234` returns `.abandon` when the key came up
during setup, and stands the session down instead of going live behind the user.

### Audio capture

`Dictation/ChalantDictationApp/Audio/AudioEngine.swift`

- One `AVAudioEngine`, started warm and left running (`:105-118`). Capture is a
  gate, not an engine start (`:203-212`), so there is no spin-up latency and no
  clipped onset.
- Tap installed at the input node's **native** format (`:91`), buffer 4800 frames
  (`:105`). Refuses to install on a 0 Hz device (`:96-98`), which otherwise
  raises an ObjC exception rather than returning an error.
- The tap callback obeys the real-time rule absolutely: no allocation, no
  logging, no await. It calls `ring.observe` then conditionally `ring.write`
  (`:110-112`).
- **Format mismatch is handled properly.** The mic's native format is not what
  the analyzer wants; `AppleTranscriber.converted(_:)` (`AppleTranscriber.swift:95-122`)
  converts with one `AVAudioConverter` per session, and the comment records that
  feeding a raw 48kHz buffer traps inside `AnalyzerInput.init` with
  `EXC_BREAKPOINT`.

### ASR

Exactly one engine is initialized at runtime: **`SpeechTranscriber`**
(`AppleTranscriber.swift:70-74`), via the explicit initialiser requesting
`[.volatileResults, .alternativeTranscriptions, .fastResults]` and
`[.audioTimeRange, .transcriptionConfidence]`.

`TokenAssembly` (`Sources/.../Text/TokenAssembly.swift`) turns the attributed
runs into `Token`s carrying confidence and time range
(`AppleTranscriber.swift:243-259`). Straddling words are rejoined.

Volatile-versus-finalized is modelled explicitly in `TranscriptAssembler`
(`:41-54`): volatile replaces, finalized appends. This is the classic streaming
duplication bug and it is handled.

### Text pipeline

`DictationController.swift:370-410`, in order:

1. `TermMatcher.applyingAliases` — learned corrections, exact match, ignores confidence
2. `TermMatcher.joiningSpans` — rejoins names the engine split
3. `TermMatcher.resolving` — single-word phonetic repair, confidence-gated
4. `Guardrail.trimmingPunctuationRun`
5. `Disfluency.collapsingRepetitions`
6. `Fillers.removing`
7. `FoundationModelsPolisher.polish` behind `Cleanup.isEnabled()`

All of 1-6 are pure and in Core with tests (195 Core tests pass locally).

### Insertion

`Dictation/ChalantDictationApp/Insert/InsertionChain.swift`, an `actor` (`:16`)
so nothing here runs on the main thread.

- Secure-input refusal first, via `IsSecureEventInputEnabled()` and not an AX
  role check (`:36-42`). Text still reaches the clipboard, so it is never lost.
- Waits for modifier keys to clear, up to 500ms (`:46`, `:185-192`). A ⌘V
  synthesized while Option is held arrives corrupted.
- **Target is re-validated before every tier, not once** (`:69-82`). The comment
  records a live case on 2026-08-12 where an insertion aimed at Terminal landed
  in a browser.
- Clipboard snapshot and restore, with a 1.5s delay before restoring
  (`PasteboardGuard.swift:88-94`) because Chromium reads the pasteboard
  asynchronously.
- Per-bundle tier demotion persists across launches (`:141-180`).

### The learning loop

`Correction` (Core, pure), `CorrectionObserver`, `LearnedTerms`, and
`LearnedTermsList` all exist and are wired. Pairs persist to JSON in Application
Support and are inspectable and deletable in Settings.

---

## 2. What is half-built

### The `bias` parameter is dead plumbing

`DictationController.swift:207` calls `transcriber.begin(locale: locale, bias: [])`
— **always an empty array**. `AppleTranscriber.swift:152` then does `_ = bias`
and discards it. The whole `BiasTerm` seam is inert. This is harmless today
(§0.1 established `contextualStrings` does nothing on `SpeechTranscriber`) but it
reads as a working feature and is not one.

### The hand-kept vocabulary has no way in

`Vocabulary.terms()` reads `dictationTerms` from `UserDefaults`
(`Vocabulary.swift:37`). Empty by default, and **there is no UI that writes it**.
The only route is `defaults write`. So the phonetic passes (spans, single-word)
operate on an empty list for every real user until the learner fills it.

### Tier 1 does not verify the paste landed

`InsertionChain.swift:123` returns `SystemEventsPaste.run()`, which returns true
when AppleScript reported no error (`SystemEventsPaste.swift:13-34`). It never
checks that text arrived.

Tier 2 does verify, via `pasteboard.wasConsumed(since:)` (`:126-130`).

Part 0 §0.3 is explicit that **every** tier must verify, because "event sent" is
not "text landed". Tier 1 is the tier that fires ~always, so in practice
insertion success is largely unverified.

### The event tap can be deaf and report healthy

`Dictation.swift:81` sets `tapInstalled` from `monitor.start()`, which returns
true whenever `CGEvent.tapCreate` succeeded. The comment at `:65-68` states
plainly that without Input Monitoring the tap creates successfully and receives
nothing.

**Input Monitoring is never requested anywhere in code.** There is no
`IOHIDRequestAccess` call. It is raised implicitly by tap creation, and nothing
detects the deaf state. `tapInstalled == true` is not evidence the hotkey works.

### Cleanup has no chunking

`FoundationModelsPolisher.polish` refuses input over budget and ships it
unchanged (`CleanupPrompt.fitsInOnePass`, ~1500 tokens). Part 0 §0.7 specced
chunking on sentence boundaries. Long dictation simply skips cleanup silently.

### The correction observer's coverage is unmeasured

`CorrectionObserver` logs which bundle IDs it can read (`:101-108`), but that log
has never been read. Whether it works in Slack, Chrome, VS Code or Notion is
**unverified** and cannot be settled from code: Part 1 §1 established those apps
often report no focused element at all.

---

## 3. What is missing entirely

- **`TermRepository`, `ScreenContextProvider`, `Clock`** — protocols in
  `Sources/ChalantDictationCore/Protocols/` with **zero conformances anywhere**.
  Dead seams.
- **`Term.swift`** — the `Term` model is never constructed. Zero call sites.
- **A term store.** Part 2 §7 specifies `terms`, `confusions`, `app_profiles`,
  `utterances`, `edits` tables in SQLite/GRDB. None exist. `LearnedTerms` is a
  JSON file holding one of those five.
- **`utterances` persistence.** Part 2 §7 calls it triple duty (recovery
  history, latency telemetry, eval corpus) and says build it early. Not built.
  There is no dictation history and no way to recover a lost insertion.
- **Punctuation.** No stage exists. M3 lists it; nothing implements it.
- **ITN** (times, currency). The engine's own normalisation is all there is.
- **Self-repair detection** ("no wait, Wednesday"). Not built.
- **Per-app profiles beyond insertion tier.** `AppProfile` declares
  `register`, `codeMode`, `allowsPolish`, `autoCapitalize`
  (`Model/AppProfile.swift`) and **not one of them is read anywhere** (0 call
  sites each). Only `maxInsertionTier` and `consecutiveFailures` are used.
- **Code mode.** M6. Nothing.
- **FluidAudio / Parakeet.** Absent from the app entirely. Referenced only in
  planning documents.
- **Screen OCR context.** Nothing.
- **Multi-locale routing.** `DictationController.swift:55` hardcodes
  `en-US`. The measured 2.1x/2.2x split between en_US and mul_IN has no
  implementation.

---

## 4. Pipeline

```
 [hotkey]  left Option held
     |     EventTapMonitor.handle                                    WIRED
     |     Hotkey/EventTapMonitor.swift:96-122
     v
 [gate]    PushToTalk state machine, release-during-setup handled    WIRED
     |     Model/PushToTalk.swift, DictationController.swift:219-234
     v
 [audio]   AVAudioEngine, warm from launch, native format,           WIRED
     |     tap buffer 4800 -> lock-free AudioRing
     |     Audio/AudioEngine.swift:90-118
     v
 [convert] AVAudioConverter -> analyzer format                       WIRED
     |     ASR/AppleTranscriber.swift:95-122
     v
 [ASR]     SpeechTranscriber, explicit init, confidence+timings      WIRED
     |     ASR/AppleTranscriber.swift:59-74
     |
     |     bias: [BiasTerm] parameter                                DEAD
     |     DictationController.swift:207 passes []
     |     AppleTranscriber.swift:152 discards it
     v
 [tokens]  TokenAssembly: runs -> words with confidence              WIRED
     |     Text/TokenAssembly.swift
     v
 [aliases] TermMatcher.applyingAliases (learned pairs)               WIRED
     |     but the ledger is empty until the observer fires          UNVERIFIED
     v
 [spans]   TermMatcher.joiningSpans                                  WIRED
     |     operates on Vocabulary.terms(), which is EMPTY            HALF
     v
 [terms]   TermMatcher.resolving                                     WIRED
     |     same empty-vocabulary caveat                              HALF
     v
 [clean]   Guardrail -> Disfluency -> Fillers                        WIRED
     |     Text/{Guardrail,Disfluency,Fillers}.swift
     v
 [model]   FoundationModelsPolisher + FidelityGuard                  WIRED
     |     Polish/FoundationModelsPolisher.swift
     |     ~1s p50; returns input unchanged on any failure
     |     chunking for long input                                   MISSING
     v
 [punct]   punctuation restoration                                   MISSING
 [ITN]     times, currency                                           MISSING
     v
 [insert]  InsertionChain, 3 tiers, target re-validated per tier     WIRED
     |     tier 1 (System Events) success is UNVERIFIED by code
     |     tier 2 (CGEvent) verifies via pasteboard consumption      WIRED
     |     tier 3 clipboard floor                                    WIRED
     v
 [learn]   CorrectionObserver polls focused field for 20s            WIRED
           coverage per app                                          UNVERIFIED
```

---

## 5. Top 5 blockers, ranked by what they unblock

**1. Nobody has held the key and used this.** Every number in this repo comes
from file input through probe binaries. Insertion tier 1 is unverified by code,
observer coverage is unverified, the event tap can be deaf while reporting
healthy, and the ~1s cleanup cost has never been felt by a person. This blocks
every judgement about what to build next, because the priorities are currently
derived from a corpus rather than from use.

**2. The vocabulary has no way in, so the whole bias layer is inert for real
users.** Spans and phonetic repair both read `Vocabulary.terms()`, which no UI
writes. Until either a term editor exists or the learner has run long enough to
fill the ledger, M4's measured 39%/41% improvement is unreachable outside the
test harness.

**3. Two audio engines, no coordination.** See section 6.

**4. Tier 1 insertion is unverified.** It is the tier that almost always fires,
and its success signal is "AppleScript did not error". Any claim about insertion
reliability rests on this, and Part 0 §0.3 explicitly requires verification.
Fixing it also gives per-app coverage data for free.

**5. No `utterances` store.** Part 2 §7 wanted it in the first milestone that
produces text, for three reasons: recovery history, latency telemetry, and the
eval corpus. Without it there is no in-app history, no p50/p95 from real use, and
the corpus depends on a separate capture toggle.

---

## 6. Open questions I could not answer from the code

**Do the two audio engines fight?** `VoiceController.swift:24` creates its own
`AVAudioEngine` and installs a tap at buffer 1024 (`:435`). Dictation's engine
(`AudioEngine.swift:90`, buffer 4800) starts warm at launch and stays running.
There is **no coordination between them** — neither references the other.
"One app, one ear" is true for device *selection* (`InputChoice` is shared) and
false for the engine itself. Whether two live taps on the input node degrade
either path needs measuring on hardware.

**Does the event tap actually receive events?** `tapCreate` succeeding proves
nothing. Needs a runtime check.

**Does tier 1 land text in Electron and Chromium apps?** The code cannot tell
you; it reports AppleScript's exit status.

**Can the correction observer read Slack, Chrome, VS Code, Notion?** It logs the
answer per bundle ID and the log has never been read.

**Is the ~1s cleanup acceptable?** Measured from files. Nobody has waited for it.

**Why is `Package.swift` on Swift tools 6.2?** Nothing in the manifest obviously
requires it, and it is what broke CI. Whether it was deliberate is unclear from
the code. (PR #4 addresses the CI runner, not this question.)

**Should `AppProfile`'s unused fields stay?** `register`, `codeMode`,
`allowsPolish`, `autoCapitalize` have zero readers. Either M6 is coming or they
are dead weight advertising a feature that does not exist.

### One piece of comment debt worth naming

`DictationController.swift:345-369` carries three stacked comment blocks from
successive edits, describing the vocabulary passes in overlapping and partly
contradictory terms. It should be one block. Nothing is functionally wrong.
