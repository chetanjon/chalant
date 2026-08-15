# Dictation merge: one app, one ear

**Status:** approved 2026-08-15. Ships as 1.13.0.
**Supersedes:** nothing. First spec for folding `~/projects/chalant-dictate` into Chalant.

## Why

Dictation is not a second product. It is Chalant's headline feature, and the
bundle ID has been `com.cj.chalant.dictation` from the first commit.

The argument is not aesthetic. On the night of 2026-08-12 the same dead
microphone bug was diagnosed and fixed **twice**, once in each codebase, because
each carries its own device ordering and its own silence watchdog. `VoiceController`
here and `AudioEngine` / `InputChoice` there solve one problem with two sets of
code and two thresholds, and only one of them got the good fix.

One product should have one ear.

## What is settled

1. **macOS floor: Chalant stays 14.0.** Dictation gates to 26. Not "raise
   everything to 26". The README promises 14+ publicly (README.md:11, :99).
2. **Scope: one ear.** Device selection and the deaf-mic watchdog collapse into a
   single shared layer both features draw from.
3. **Trigger: two doors, kept separate.** Hold left Option anywhere to dictate
   into the focused app. The island mic and long-press stay exactly as they are,
   for commands.

## The constraint that drives the design

The two projects disagree on the floor, and `SpeechAnalyzer` / `SpeechTranscriber`
are `@available(macOS 26, *)` with no backport.

| | Chalant (moai) | ChalantDictation |
|---|---|---|
| Deployment target | **14.0** | **26.0** |
| Swift / concurrency | 5.9, `targeted` | 6.0 (tools 6.2), `complete` |
| Speech engine | `SFSpeechRecognizer`, cloud-permitted | `SpeechTranscriber`, on-device |
| ARCHS | universal | arm64 |
| Tests | XCTest, 22 files | swift-testing, 7 files / 48 tests |

**Keeping 14+ means the two features can never share one recognizer**, because
`SpeechTranscriber` does not exist on 14. `VoiceController`'s `SFSpeechRecognizer`
command path survives regardless. "One engine" is off the table. **"One ear" is
not, and the ear is what broke twice.**

## Shape

- `git subtree add --prefix=Dictation ~/projects/chalant-dictate main`, so the
  12 commits of history come along rather than landing as an anonymous copy.
- **Keep the SPM package boundary** (`packages: ChalantDictationCore: path: Dictation`
  in project.yml). Core keeps Swift 6 `complete` while the app stays 5.9
  `targeted`, the Foundation-only rule survives, and **the 48 swift-testing tests
  keep running untouched**. Folding the files into `Chalant/Features/` would mean
  porting them to XCTest for nothing.
- **Verified 2026-08-15:** no file under `Sources/ChalantDictationCore` imports
  Speech, AVFoundation, AppKit or ApplicationServices, so `platforms: [.macOS(.v26)]`
  drops to `.v14` for free.
- Only two files need `@available(macOS 26, *)`, and both are already in the app
  target, not Core: `ASR/AppleTranscriber.swift` and `ASR/SpeechAssets.swift`.
- Drop `App.swift` and the menu bar scaffolding. Standalone-app furniture.
- `VoiceController` (862 lines) keeps its recognizer but **loses its candidate
  list, silence watchdog and route-change handling** to the shared ear. This is
  the riskiest edit in the merge and Chalant's whole command flow depends on it.
- Add a dictation case to `VoiceDoor`, which exists precisely so a door cannot
  vanish unnoticed the way every mic did in 1.12.3. Report present only on 26.
- **Retire the standalone app and its login item as an explicit step.** Two
  dictation apps running side by side means doubled text, self-inflicted.

## Not in scope, deliberately

- Turning the listening panel into the island. Moving the merge and the UI at
  once makes any failure ambiguous.
- Moving commands onto `SpeechTranscriber`. Blocked by the 14.0 floor anyway.
- The engine locale question (see below). It rides on the corpus, not the merge.

## Risks

1. **`VoiceController` surgery.** 862 lines, and every island command flows
   through it. Land the shared ear first with `VoiceController` still on its own
   code, prove it, then cut over in a separate commit.
2. **Swift 5.9 `targeted` app consuming a Swift 6 `complete` package** can surface
   Sendable errors at the boundary that the standalone app never met, being 6.0
   throughout.
3. **The event tap under a notarized hardened-runtime Release build is unverified.**
   The standalone app is a development-signed Debug build. Input Monitoring and
   Accessibility are TCC grants, so nothing is declared in the bundle, but that
   the tap *works* there has never been shown. Verify before shipping.
4. **`HotKeyCenter` cannot host the hold.** Carbon `RegisterEventHotKey` needs a
   real keycode plus modifiers (`isValid` rejects modifier-only) and fires on
   press with no release. `EventTapMonitor` stays for left Option, so the two
   hotkey mechanisms coexist by necessity, not neglect.

## What the merge does NOT need

No new entitlement. `Chalant/Chalant.entitlements` already carries
`device.audio-input` and `automation.apple-events`; Info.plist already carries
`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` and
`NSAppleEventsUsageDescription`. Input Monitoring and Accessibility are TCC
grants and are never declared in a bundle at all.

## Order of work

1. Subtree in, package wired, project builds with dictation compiled but unreached.
2. `@available` gating on the two ASR files. Core drops to `.v14`. Tests green.
3. Shared ear extracted, dictation on it, `VoiceController` untouched. Prove it.
4. `VoiceController` cut over to the shared ear. Separate commit.
5. `VoiceDoor` case. Left Option wired in the real app.
6. Verify the event tap in a notarized Release build.
7. Retire the standalone app and its login item.
8. Ship 1.13.0.

One behaviour change per commit, per the dictation contract.

## Open, and riding on the corpus rather than this merge

Measured on this Mac 2026-08-15: macOS 27's `SpeechTranscriber` supports `hi-IN`,
`te-IN` and `mul-IN` ("Multiple languages (India)"), reversing the §4 research.
On synthesized speech `mul-IN` transcribed Telugu-English and Hindi-English
correctly where `en-IN` returned mush, and matched `en-IN` on pure English.
**Whether `mul-IN` becomes the default locale is a product decision that needs
real-voice accuracy and warm latency numbers.** It changes one line at the
transcriber, so it does not gate the merge.
