# Manual test log

Part 1 §2: nothing is claimed to work without a passing test or a dated entry
here. "Should work" and "now supports" are not evidence.

---

## 2026-08-12 — M0, partial. NOT YET ACCEPTED.

Build: Debug, `a699748` + event-tap mask fix. macOS 27.0, arm64.

### Verified working

| Thing | Evidence |
|---|---|
| Speech assets resolve and install | `asset state for en_US: available(locale: en_US (fixed en_US))` |
| Warm engine starts and stays up | `warm engine running at 48000.0 Hz` |
| Event tap installs | `event tap installed` |
| Entitlements reach the binary | `codesign -d --entitlements`: audio-input + apple-events present, hardened runtime on, team WV59PZX4A3 |
| Volatile/finalized assembly | 8 unit tests green, including the scripted duplication trap |

### Blocked, and why

**The acceptance criterion has not been run.** M0 accepts only on "dictate one
sentence into TextEdit and it appears, twice in a row, on a cold launch", and
that has not happened yet.

Two permissions are outstanding, both needing a human:

1. **Input Monitoring (`kTCCServiceListenEvent`) — currently `Unknown (None)`.**
   A listen-only keyboard event tap gets no events without it. `tapCreate`
   still succeeds and still logs "event tap installed", so the failure is
   completely silent and looks exactly like a code bug.
   **This permission is missing from the package's own list in Part 2 §5,**
   which names only Microphone, Accessibility, Automation and Screen Recording.
   Add it: System Settings → Privacy & Security → Input Monitoring.

2. **Microphone — `Unknown (None)`.** Prompts on the first real capture, which
   cannot happen until the key registers.

### Findings worth keeping

- **The event mask bug.** `1 << CGEventType.tapDisabledByTimeout.rawValue` is
  undefined behaviour: those raw values are 0xFFFFFFFE and 0xFFFFFFFF. Putting
  them in the mask corrupted it so the tap matched nothing, while still
  installing cleanly. Those two events are delivered regardless of the mask.
  Found by standing up a second, identical tap in a separate process that did
  receive the events.

- **An ad-hoc first launch poisons TCC.** The first build was ad-hoc signed
  (no team), which created TCC entries pinned to that identity. After signing
  was fixed, tccd logged `Failed to match existing code requirement for
  subject com.cj.chalant.dictation and service kTCCServiceListenEvent` and the
  app could not be granted anything. Recovery: `tccutil reset ListenEvent
  com.cj.chalant.dictation` and the same for Accessibility. Verified this did
  not disturb the main app, `com.cj.chalant`, whose Calendar and Reminders
  grants still read `Allowed (User Consent)` afterwards.

- **The `say` harness works for driving audio** (`say -a "MacBook Air
  Speakers"`, since the default output is the dead headphone jack), and
  synthetic right-Option `flagsChanged` events are visible to a listen-only
  tap. So once Input Monitoring is granted, M0 can be exercised end to end
  without a human at the keyboard.
