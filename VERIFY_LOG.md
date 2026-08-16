# Verify log

**An item is not done until this file has a dated entry written by a human who
performed the test with a hand on the key.** No exceptions, including for items
that obviously work.

Claude Code implements and self-tests. Self-testing is not verification: a build
succeeding and 195 unit tests passing say nothing about whether the app tells
you it cannot hear.

---

## S1 — prove the tap hears

**Status: AWAITING HUMAN VERIFICATION.** Implemented, builds, not verified.

### What changed

- `InputMonitoringPermission` (new). `CGPreflightListenEventAccess` /
  `CGRequestListenEventAccess`, both confirmed present in the S0 SDK dump. The
  app has never asked for this permission before.
- `Dictation.start()` now asks BEFORE creating the tap, and records the binary's
  signing identity, because TCC is keyed to code identity and a re-sign can
  revoke the grant with nothing in the logs to explain it.
- `EventTapMonitor.hasHeardAnything` — true once ANY `.flagsChanged` arrives.
  Deliberately any modifier, not just left Option: waiting for the dictation key
  would mean the check only passes once the user has already succeeded at the
  thing being checked.
- `Dictation.checkHearing()` returns `hearing` / `notPermitted` / `unproven` /
  `suspect`. Called when Settings appears, which is a real interaction, rather
  than on a timer, which would report nonsense while the machine sits idle.
- `DictationHearingNotice` — shown in the Dictation card only when there is
  something to say. There is no "all good" tick: working is the expected state.

### The test, to be performed by a human

Turn "Hold to dictate" ON first. All three parts need it on.

**1. It must tell you when it cannot hear.**

```
tccutil reset ListenEvent com.cj.chalant
```

Relaunch Chalant. Open Settings, General, Dictation.

- [ ] A notice appears saying Chalant cannot see the key
- [ ] It offers a button that opens the right pane of System Settings
- [ ] **Silence here is a FAIL**, even if dictation happens to work

**2. Granted, it works.**

Grant Input Monitoring, relaunch, click into TextEdit, hold left Option, speak,
release.

- [ ] Text appears
- [ ] The notice is gone from Settings

**3. It must notice the grant being taken away.**

With Chalant running, revoke Input Monitoring in System Settings. Type a few
characters somewhere. Open Chalant's Settings, General, Dictation.

- [ ] Within 10 seconds of opening Settings, a notice appears
- [ ] **Silence here is a FAIL**

### Result

```
Date:
Performed by:
macOS / build:
1. cannot-hear notice:        PASS / FAIL   notes:
2. granted, works:            PASS / FAIL   notes:
3. revoked, noticed:          PASS / FAIL   notes:
Anything surprising:
```

### Known unverified in this implementation

- **The System Settings deep link anchor `Privacy_ListenEvent` is unconfirmed.**
  The URL scheme is proven in this repo (`Privacy_Calendars`,
  `Privacy_Reminders` in `EventKitService.swift:217`); this specific anchor is
  not. If the button opens the wrong pane, that is the finding, and it is a
  one-word fix.
- `suspect` requires 3 checks with no events. Whether 3 is the right number is a
  guess and part 3 of the test is what says otherwise.

---

## S2 — survive 100 holds

Not implemented.

## S3 — locale correctness

Not implemented. **See `verification/PHASE0_SDK_TRUTH.md` first:**
`status(forModules:)` is not trustworthy across processes and S3 must be built
on `installedLocales` instead, which inverts what `SpeechAssets.swift:63`
currently does.

## S4 — insertion lands, or reports that it didn't

Not implemented.

## S5 — survive the environment

Not implemented.

## S6 — toggle mode

Not implemented.

## S7 — session journal

Not implemented. S1 logs the signing identity to the unified log meanwhile.

## S8 — first real numbers

Not implemented.
