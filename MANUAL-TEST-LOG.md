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

---

## 2026-08-12 — M0 ACCEPTED

Build `7b8895d` + Accessibility gate. macOS 27.0, arm64, built-in mic.

**The criterion, verbatim:** "you dictate one sentence into TextEdit and it
appears, twice in a row, on a cold launch." Met.

| Run | Transcribed | finalize | insert | outcome |
|---|---|---|---|---|
| 1 | 20 chars | 0.200s | 0.095s | `inserted(systemEvents)` |
| 2 | 20 chars | 0.186s | 0.026s | `inserted(systemEvents)` |

Both on one cold launch, driven by the `say` harness into TextEdit, confirmed
by reading the document back.

### Latency, measured rather than assumed

Key-release to text on screen, across five successful utterances:
finalize 0.033-0.200s, insert 0.026-0.095s, so roughly **0.06s to 0.30s
end to end**.

Part 0 §0.5 demoted the latency budget to an empirical gate because two
independent sources measured finalization at 1.45s warm and 2.2s cold, and
warned the 250ms p95 target was probably unachievable and that "faster than
cloud" would die with it. **It does not reproduce on this hardware.** With
`prepareToAnalyze()` at key-down the target looks reachable.

Provisional, and not a public claim yet: these are short utterances of clean
synthesized speech into a quiet room. The corpus decides. But §0.5's
pessimistic branch can be treated as not applying here.

### Permissions actually required

Three, and Part 2 §5 lists neither set correctly:

| Permission | Needed for | In §5? |
|---|---|---|
| Microphone | capture | yes |
| **Input Monitoring** | the event tap seeing the key at all | **no** |
| **Accessibility** | System Events sending the keystroke | yes |
| Automation | nothing, as it turns out | listed, unnecessary |

The Accessibility failure is the nastiest: `System Events got an error:
ChalantDictation is not allowed to send keystrokes.` names the app rather than
the permission and sends you to the wrong settings pane. The app now checks
`AXIsProcessTrusted()` first and says which switch to turn on.

**Self-inflicted, worth remembering:** the `tccutil reset Accessibility` used
earlier to clear the ad-hoc-signing poison also removed the grant the paste
needed, and the next failure was then misdiagnosed as Automation. Resetting one
service can break a different feature.

### Known and deferred to M1

Insertion is mid-sentence-naive: the text landed as
`...reads the notchAcceptance test one.` with no leading space. That is case 2
of the 12-app protocol and M1's job, not a regression.

---

## M1 GATE — the 12-app protocol

**Accept when:** at least **10 of 12** apps pass at Tier 1 or 2, with **zero
text-loss events** across the whole run. Part 3: *a single text-loss event in
any cell fails the gate outright, regardless of how the other 75 look.*

Four of the twelve are not installed on this machine: Slack, Notion, iTerm2 and
Figma. Slack matters most of the four, being named "the most common real
target". Installing at least Slack is worth it before calling this gate passed;
the other three can be recorded as untested with the reason.

Fill in the tier that fired (1 = System Events, 2 = CGEvent, 3 = clipboard
floor) or a short failure note.

| App | empty field | mid-sentence | replaces selection | single ⌘Z undo | clipboard preserved | two in a row |
|---|---|---|---|---|---|---|
| TextEdit |  |  |  |  |  |  |
| Safari (textarea) |  |  |  |  |  |  |
| Chrome (textarea) |  |  |  |  |  |  |
| Slack *(not installed)* |  |  |  |  |  |  |
| VS Code |  |  |  |  |  |  |
| Notion *(not installed)* |  |  |  |  |  |  |
| Terminal |  |  |  |  |  |  |
| iTerm2 *(not installed)* |  |  |  |  |  |  |
| Messages |  |  |  |  |  |  |
| Mail |  |  |  |  |  |  |
| Xcode |  |  |  |  |  |  |
| Figma *(not installed)* |  |  |  |  |  |  |

### The three global cases

| Case | Expected | Result |
|---|---|---|
| Password field (1Password or a login form) | **refuses**, names the holder, never inserts | |
| Focus stolen mid-dictation (fire a notification during a long utterance) | refuses or falls to clipboard, **never inserts into the wrong app** | |
| `sudo` prompt in Terminal | secure-input probe fires, text lands on clipboard with the holder named | |

### How to run one cell

1. Put the cursor where the case describes
2. Hold **left Option**, say a short sentence, release
3. Check the text landed correctly, then press **⌘Z once** and confirm it all reverts

The tier that fired is in the log:
`log show --predicate 'process == "ChalantDictation"' --info --last 2m | grep "inserted at tier"`

---

## 2026-08-12 — M1 gate, partial run (3 of 12 apps + 1 global case)

Build `2e61ee8` + Spacing. Driven by `InsertionTestHook`, a debug-only
distributed-notification hook that runs the real `InsertionChain` with a known
string. M1 is about insertion, so putting the microphone in the loop would make
every cell depend on speech recognition and bury insertion failures under
transcription noise. Same tiers, same pasteboard guard, same demotion; only the
text source differs.

| App | empty | mid-sentence | replaces sel. | single ⌘Z | clip preserved | two in a row | tier |
|---|---|---|---|---|---|---|---|
| **TextEdit** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 1 |
| **Safari** (textarea) | ✅ | — | — | — | ✅ | ✅ | 1 |
| **Chrome** (textarea) | ✅ | — | — | — | ✅ | ✅ | 1 |

**Global cases**

| Case | Expected | Result |
|---|---|---|
| Password field | refuses, names holder, never inserts | ✅ `refused(secureInputActive(holder: "Safari"))`, field stayed empty, 0.0s |
| Focus stolen mid-dictation | never inserts into the wrong app | not run |
| `sudo` in Terminal | probe fires, clipboard floor, holder named | not run |

**Zero text-loss events.** Every run either landed the text or left it on the
clipboard.

### What this proves

- **Tier 1 handles all three so far.** No demotion has been needed, so the
  CGEvent tier and the clipboard floor are untested in anger.
- **Chromium's async pasteboard is handled.** Chrome took two consecutive
  insertions with correct spacing and the user's clipboard came back intact,
  which is exactly what Part 1 §1's 1.5s restore delay exists for. Restoring at
  the originally specced 40-80ms would have shown up here.
- **The secure-input refusal works and is instant.** Part 1 §1's correction is
  vindicated: `IsSecureEventInputEnabled()` catches a WebKit password field,
  which the abandoned `AXSecureTextField` role check would have had to ask a
  web view about.

### Spacing, added to make case 6 pass

Two consecutive insertions produced `firstsecond`. `Spacing` (pure, 8 tests)
now adds a trailing space always and a leading space only when the preceding
character is known and is not whitespace or an opener. `CursorContext` reads
that character over Accessibility, best-effort: it returns nil in Electron and
web views exactly as Part 1 §1 predicts, and nil is the safe default rather
than a degraded one. Verified in TextEdit: `one two` + `beta` gave
`one two beta `, and mid-word gave `befor INSERTED e`, which one ⌘Z reverted
whole.

### Still to run

- **VS Code** — installed, but it is hosting this session's terminal, so
  driving insertions into it risks disrupting the work. Worth a manual pass.
- **Terminal, Messages, Mail, Xcode** — installed, not yet run. Messages and
  Mail deliberately left for a human, since an errant Return in either sends
  something to a real person.
- **Slack, Notion, iTerm2, Figma** — not installed. Slack is the one worth
  adding: Part 3 calls it "the most common real target" and it is the Electron
  case the AX path was removed for.
