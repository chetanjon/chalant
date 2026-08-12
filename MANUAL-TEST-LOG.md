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

---

## 2026-08-12 — M0, transcription PROVEN. Insertion blocked on Automation.

### Transcription works, measured

Two successful utterances through the full chain, driven by the `say` harness:

| Said | Transcribed | finalize |
|---|---|---|
| "The quick brown fox jumps over the lazy dog" | `The quick brown fox jumps over the lazy dog. Yeah, yeah.` | 0.040s |
| "Testing insertion into TextEdit" | `Testing insertion into text edit. Uh.` | 0.033s |

**Finalization measured at 33-40ms.** Part 0 §0.5 warned the 250ms p95 budget
might be unachievable because two independent sources measured 1.45s warm and
2.2s cold. On this hardware, with `prepareToAnalyze()` at key-down, it is two
orders of magnitude better. Treat as provisional: these are short utterances of
clean synthesized speech, not the corpus. But the pessimistic reading of §0.5
does not reproduce here.

**Both utterances hallucinated on the trailing silence** ("Yeah, yeah.", "Uh.")
This is exactly the fabricated-text-on-silence class Part 0 §0.18 predicts, and
it appeared on the very first successful utterance rather than as a rare tail
case. §0.18's guardrail stage is not optional.

### Blocked

Insertion never lands: Automation of System Events is not granted, so every
outcome is `leftOnClipboard`. The text is never lost, which is the invariant
holding, but M0 is not accepted until it reaches TextEdit twice in a row.

### Findings

- **A missing timeout cost 120 seconds.** With Automation ungranted, the
  default AppleEvent timeout froze the insert for two full minutes. Fixed with
  `with timeout of 3 seconds`, measured at 3.06s after.
- **But a short timeout then races the consent dialog**, so the permission can
  never be granted through the script path at all. Resolved by asking
  explicitly with `AEDeterminePermissionToAutomateTarget` before the paste.
- **That call answers -600 (procNotFound) when System Events is asleep**, and
  will not launch it. System Events is launched on demand, so a fresh login
  hits this instead of a prompt. The app now wakes it first, without stealing
  focus.
- **The `say` harness is not reliable for this app.** A run fed 51 buffers
  (~5s of audio) and still transcribed nothing: the buffers arrive but contain
  silence. Output volume was 100 and unmuted, routed to the built-in speakers.
  The likely cause is macOS voice-processing echo cancellation removing our own
  speaker output from the microphone input, which is precisely what it is for.
  Some runs succeed, so it is intermittent rather than absent. **Do not treat a
  harness "nothing heard" as an app failure without checking the fed-buffer
  count first.**
