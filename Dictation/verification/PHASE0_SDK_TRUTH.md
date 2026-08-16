# S0 — SDK ground truth

Run 2026-08-16 against the installed SDK and at runtime on the target machine.
Regenerated from scratch for the Stage 1 directive; supersedes the 2026-08-15
version of this file.

**Rule applied throughout: the installed SDK and the runtime are the source of
truth. Where either contradicts the directive or an existing document, the
contradiction is recorded rather than smoothed over.**

---

## Environment

| | |
|---|---|
| macOS | **27.0** (26A5378n) |
| Xcode | 26.6 (17F113) |
| SDK | **MacOSX26.5** |
| Hardware | MacBook Air, Mac15,12, **Apple M3**, 8 cores, **16 GB** |

**The SDK is a minor version BEHIND the OS.** Runtime capability can therefore
exceed what the interface implies, and an "absent from the dump" verdict is not
the same as "unavailable at runtime". This is not hypothetical: the multilingual
locales below are richer than the headers alone would suggest.

Full interface: `verification/sdk_speech_interface.txt` (683 lines, from
`Speech.swiftmodule/arm64e-apple-macos.swiftinterface`).

---

## Symbol table

### Permissions

All four CoreGraphics symbols are **PRESENT**, in
`CoreGraphics.framework/Headers/CGRemoteOperation.h`, all `macos(10.15)`, none
deprecated:

| Symbol | Signature |
|---|---|
| `CGPreflightListenEventAccess` | `bool CGPreflightListenEventAccess(void)` |
| `CGRequestListenEventAccess` | `bool CGRequestListenEventAccess(void)` |
| `CGPreflightPostEventAccess` | `bool CGPreflightPostEventAccess(void)` |
| `CGRequestPostEventAccess` | `bool CGRequestPostEventAccess(void)` |

**S1 is implementable exactly as written.** None of these are currently called
anywhere in the repository.

`IsSecureEventInputEnabled` — **PRESENT**, exported from
`Carbon.framework/Frameworks/HIToolbox`. Already used successfully at
`Dictation/ChalantDictationApp/Insert/SecureInputProbe.swift:21`.

**`AXManualAccessibility`** — as the directive anticipated, this is a magic
attribute string and not an SDK symbol. It does not appear in any header and its
absence means nothing. Noted rather than reported absent.

### Locale

| Symbol | Status |
|---|---|
| `SpeechTranscriber.supportedLocales` | PRESENT, `static var ... { get async }` |
| `SpeechTranscriber.installedLocales` | PRESENT, `static var ... { get async }` |
| `SpeechTranscriber.supportedLocale(equivalentTo:)` | PRESENT, `static func ... async -> Locale?` |

### Assets

| Symbol | Status | Signature |
|---|---|---|
| `AssetInventory.maximumReservedLocales` | PRESENT | `static var Int` (sync) |
| `AssetInventory.reservedLocales` | PRESENT | `static var [Locale] { get async }` |
| `AssetInventory.reserve(locale:)` | PRESENT | `static func async throws -> Bool` |
| `AssetInventory.release(reservedLocale:)` | PRESENT | `static func async -> Bool` |
| `AssetInventory.status(forModules:)` | PRESENT | `static func async -> Status` |
| `AssetInventory.assetInstallationRequest(supporting:)` | PRESENT | `static func async throws -> AssetInstallationRequest?` |
| **`AssetInventory.allocatedLocales`** | **ABSENT** | 0 occurrences |
| **`AssetInventory.deallocate(locale:)`** | **ABSENT** | 0 occurrences |

`AssetInventory.Status` cases: `unsupported`, `supported`, `downloading`,
`installed`. It is `Comparable`.

**The directive lists `allocatedLocales` and `deallocate(locale:)`. Neither
exists.** The reserve/release pair is the whole API. Any S3 wording built on
allocate/deallocate needs rewriting to reserve/release.

### Lifecycle and teardown — this is what S2 turns on

**`SpeechAnalyzer` carries the entire teardown surface:**

| Method | Note |
|---|---|
| `cancelAndFinishNow() async` | **the abandon path S2 needs** |
| `finalizeAndFinishThroughEndOfInput() async throws` | what the app uses today |
| `finalizeAndFinish(through:) async throws` | |
| `finish(after:) async throws` | |
| `finalize(through:) async throws` | |
| `cancelAnalysis(before:)` | sync |
| `setModules(_:) async throws` | reuse across sessions is possible |

**`SpeechTranscriber` has NO teardown method whatsoever.** No `finish`, no
`cancel`, no `invalidate`. Only `@objc deinit`. Its lifetime is ARC's problem
and the analyzer's.

**Verdict: S2 is implementable as written, and better than written.**
`cancelAndFinishNow()` is a real, cheap abandon path. `setModules(_:)` means a
single long-lived analyzer is possible, which would sidestep the recognizer-cap
failure entirely rather than managing it.

---

## Runtime truth

A throwaway CLI (not an app target) printed the live lists.

### en_IN is PRESENT and ALREADY INSTALLED

**45 supported locales, 24 installed.** `en_IN` appears in both.

Installed: `bn_IN en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA gu_IN
hi_IN kn_IN ks_IN mai_IN ml_IN mr_IN ne_IN or_IN pa_IN ta_IN te_IN ur_IN mul_IN`

Supported but not installed: the German, Spanish, French, Italian, Japanese,
Korean, Portuguese and Chinese sets.

**S3's core assumption holds.** The differentiator is one line away, as the
directive suspected, and the asset is already on this machine.

`maximumReservedLocales` = **5**. `reservedLocales` = **`[]`** — the app has
never successfully reserved anything, or reservations do not persist.

### The equality trap is REAL, and measured

| Constructed | `== ` in supportedLocales | identifier match | `supportedLocale(equivalentTo:)` |
|---|---|---|---|
| `Locale("en_IN")` underscore | **true** | true | `en_IN` |
| `Locale("en-IN")` **hyphen** | **false** | **false** | `en_IN` |
| `Locale("en_US")` underscore | true | true | `en_US` |
| `Locale("en-US")` **hyphen** | **false** | **false** | `en_US` |

The framework's own identifiers use **underscores**. A hyphenated `Locale` is
not equal to them and does not match by identifier either. Both resolve
correctly through `supportedLocale(equivalentTo:)`.

**This already implicates shipping code.** `DictationController.swift:55`
declares `Locale(identifier: "en-US")` — hyphenated, and therefore not equal to
the framework's `en_US`. It works only because both consumers route through
`supportedLocale(equivalentTo:)` first
(`AppleTranscriber.swift:58`, `SpeechAssets.swift:55`). The directive's rule is
already satisfied, by exactly one call on each path, with no test holding it
there.

---

## ⚠ The unresolved contradiction S0 exists to catch

**`AssetInventory.status(forModules:)` returned `.supported` for EVERY locale
tested — including `en_US`, which the app uses successfully every day, and
`de_DE`, which is definitively not installed.** Both presets, same result:

```
en_US  installedLocales=true   status=supported
en_IN  installedLocales=true   status=supported
mul_IN installedLocales=true   status=supported
de_DE  installedLocales=false  status=supported
```

`.installed` is a real case in the enum and was never returned.

**Why this matters more than it looks.** `SpeechAssets.ensure`
(`SpeechAssets.swift:63-76`) switches on exactly this value, and only
`.installed` produces `.available`. `SpeechAssetState.isReady` is true **only**
for `.available` (`:24-27`), and `DictationController.swift:153` refuses every
key press when the state is not ready.

If the app saw what this CLI saw, dictation would refuse every hold. **It does
not — dictation demonstrably worked on this machine tonight**, with 72 captured
utterances on disk.

**Most likely explanation, with evidence but NOT confirmed in both contexts:**
the status API reports `.supported` to a process lacking Speech Recognition
authorization. The CLI measured `SFSpeechRecognizer.authorizationStatus() == 0`
(`notDetermined`); the app requests that authorization at launch
(`Chalant/Features/PermissionPrimer.swift:14`).

**Consequence for Stage 1, and it is the reason to stop here:**

1. **Do not design S3 on this CLI's `status` readings.** They are not
   transferable to the app's context. `installedLocales` matched expectations
   and looks trustworthy; `status(forModules:)` does not.
2. The directive tells S3 to "check `installedLocales`; if supported but not
   installed, run the asset installation request". Given the above, **that is
   the right signal and `status` is the wrong one** — which inverts what
   `SpeechAssets` currently does.
3. **Unverified either way:** whether the app's own asset gate ever reaches
   `.available` through the `.installed` branch, or whether dictation works for
   some other reason. Settling it needs one `log stream --level debug` while
   dictation restarts, since the line is `log.info` and `log show` does not
   persist those.

---

## Corrections to the directive, from the SDK

1. **`allocatedLocales` and `deallocate(locale:)` do not exist.** Use
   `reservedLocales` and `release(reservedLocale:)`.
2. **`SpeechTranscriber` has no teardown surface.** S2's teardown work belongs
   entirely to `SpeechAnalyzer`.
3. **S2 has a better option than the one implied.** `setModules(_:)` allows one
   long-lived analyzer reused across holds, which would avoid the
   recognizer-cap failure rather than managing it. Worth deciding before S2 is
   written, because it changes the shape of the fix.
4. **`maximumReservedLocales` is a synchronous property**, not async, unlike its
   neighbours. Reading it at runtime as the directive requires is trivial.

## What S0 did NOT establish

- Whether the recognizer cap ("Maximum number of recognizers reached")
  reproduces here. It is a reported failure, not a measured one, and S2's
  100-hold test is what settles it.
- Whether `CGPreflightListenEventAccess` returns false in the current TCC state.
  Not called anywhere yet.
- Anything about insertion, AX readability, or latency. Out of S0's scope.
