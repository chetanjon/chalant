# Better hearing: a stronger ear as the background "final"

**Date:** 2026-08-18
**Status:** proceeding under the founder's "continue building" after the ear
spike; behind a switch that is off by default and downloads nothing until it
is turned on. Spec written as the build begins.

## Why

`Dictation/verification/EAR_2026-08-17.md`: on this Mac WhisperKit
large-v3-turbo hears the founder's voice better than Apple's recognizer does
(Set C 8.2% vs 12.8% WER; on twenty of their own dictations it got Kizu,
Priya, Gangotri, "tidy pass", "no red flags", "hookah" right where Apple did
not). Measured again the same night, the compressed 626 MB build of the same
model (`large-v3-v20240930_626MB`) does as well or better (Set C 7.1%, names
set 29.0% vs Apple's 35.5%, the same wins on the founder's clips) at 1.2 s per
utterance after the audio ends instead of 3.4, and it is a third of the
download. It still can never be the ear that lands words instantly; it is the
ear whose better version replaces them in place a second or two later,
exactly the shape "instant, then tidied in place" already has.

## What the user gets

- **Nothing, unless they turn it on.** Settings, General, Dictation gains
  "Better hearing" (off). Its note says what it costs: a one-time 606 MB
  download to this Mac, memory while it is loaded, more battery per
  sentence, and that nothing leaves the Mac.
- **Turning it on downloads the model** (progress under the switch:
  "Downloading… 40%", then "Ready"; "Could not download" with a retry if the
  network fails; the switch stays on and it retries at next launch).
- **When it is on and ready:** every dictation still lands as today (Apple's
  words, refined at once or within ~0.65 s). In the background the utterance's
  audio goes through Whisper, its text through the same deterministic passes
  and the same tidy, and if the result differs and the swap policy allows,
  the words are replaced in place. Measured live: heard in 1.2 s, swapped 1.9 s
  after release. The app sits at ~136 MB RSS with the model loaded (Core ML
  maps it; the Neural Engine holds most of it).
- **Where it does not swap:** exactly the 1.18.0 rules (typed or clicked
  since, focus moved, terminals and editors that carry one, clipboard-only
  outcomes) plus a longer ceiling: 6 s instead of 4 (`SwapPolicy.maximumDelay
  (for:)` takes the source: the tidy alone keeps 4 s).
- **The strip does not change.**

## Architecture

- `project.yml`: package `WhisperKit` from `argmaxinc/WhisperKit` 1.1.0,
  product `WhisperKit`, linked into the app target only. The model AND the
  tokenizer download under Application Support/Chalant/Models: left to its
  defaults WhisperKit's hub cache is ~/Documents/huggingface, and the first
  build here made macOS ask "Chalant would like to access files in your
  Documents folder" (seen live, answered Don't Allow). Chalant never touches
  Documents.
- `Dictation/ChalantDictationApp/ASR/AppleTranscriber.swift`: keeps the
  utterance's converted samples in memory as it feeds the analyzer (16 kHz
  mono Float32, capped at 90 s), returned with the transcript at `end()`.
  This is the audio the corpus capture already tees to disk; now it also
  stays in memory for one more listener.
- `Dictation/ChalantDictationApp/ASR/BetterHearing.swift` (new): an actor
  owning the WhisperKit pipeline. `isEnabled` (UserDefaults
  `dictationBetterHearing`, default off), `state` (off, downloading(fraction),
  ready, failed(reason)), `prepare()` (download if needed, load, warm),
  `transcribe(samples:) async -> String?` (large-v3-turbo, English, no
  timestamps; nil on any failure). Loads on first need after the switch is
  on; unloads when switched off.
- `UserActivityWatch` ignores our own ⌘Z/⌘V for the half second around a
  swap: the first live run kept the ear's version as "userActed" because the
  tidy swap's own keystrokes were counted as the user's.
- `DictationController`: after the insert, if better hearing is ready, one
  more background task: Whisper text → `deterministicText`-equivalent on
  plain text (`Fillers`, `Disfluency`, `Guardrail`; the vocabulary passes need
  tokens with confidences and are skipped) → `polisher.polish` (full, no
  budget) → `SwapPolicy` with the 6 s ceiling → `replaceLastInsertion`. It
  waits for the tidy swap to settle first so the two never race for ⌘Z: the
  tidy swap task is awaited (or already done) before the hearing swap runs,
  and a swap that already happened is what the hearing swap undoes.
- `SwapPolicy`: `maximumDelay(for source: Source)`; `.tidy` 4 s, `.hearing`
  6 s. Pure, tested.
- Settings: `SettingToggle("Better hearing")` + status `SettingNote`.
- Logs: `hearing: N -> M chars, swapped after Xs` / `hearing kept: reason`.

## Proof

- Unit: `SwapPolicy` ceilings by source; the sample buffer caps at 90 s and
  resets per utterance; the plain-text deterministic pass.
- Live: switch on, watch the download reach Ready, dictate the founder's
  known-bad sentences ("send the Chalant build to Kizu", "Priya is away") and
  see the words corrected in place a few seconds later; typing right after
  release keeps them; the strip's latency is unchanged (log lines).
- Perf: memory with the model loaded; CPU/ANE per utterance; the numbers go
  in the release notes honestly.

## Out of scope

Making Whisper the primary ear (too slow); code-switched Telugu/Hindi (Whisper
forced to English translates); streaming Whisper during the hold (later, if
this earns its keep).
