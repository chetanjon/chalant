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

---

## 2026-08-12 — M1 gate, extended run. 5 of 12 apps, all passing.

| App | Class | Result | Tier |
|---|---|---|---|
| **TextEdit** | native | ✅ all 6 cases | 1 |
| **Safari** | WebKit | ✅ empty, consecutive, clipboard | 1 |
| **Chrome** | Chromium | ✅ empty, consecutive, clipboard | 1 |
| **VS Code** | **Electron** | ✅ consecutive, clipboard, correct spacing | 1 |
| **Terminal** | terminal | ✅ landed at the prompt, clipboard preserved | 1 |

**Global case:** password field ✅ refused instantly, holder named, field untouched.

**Zero text-loss events across every run.** Tier 1 handled all five, so the
CGEvent tier and the clipboard floor remain untested in anger.

### The gate cannot formally pass on this machine

It requires **10 of 12**. Four apps are unavailable and no amount of testing
gets around it:

| App | Why not |
|---|---|
| Slack | Installed via Homebrew, but its sign-in screen has no text field at all: it hands off to a browser. Testing needs real credentials. |
| Notion, iTerm2, Figma | Not installed. |

That caps the achievable count at **8 of 12** (adding Messages, Mail and
Xcode), which is below the bar as written.

**What is covered is every architectural class in the list:** native, WebKit,
Chromium, Electron and terminal. VS Code is the same Electron case Slack
represents, and it passes at tier 1 with correct spacing. The honest reading is
that insertion works across the classes that matter, and that the literal 10/12
count is blocked by app availability rather than by any observed failure.

### Not run, and why

- **Messages, Mail** — deliberately left for a human. An errant Return in
  either sends something to a real person, and no test is worth that.
- **Xcode** — `open -a Xcode` handed the `.swift` file to VS Code instead, and
  chasing it was not worth the launch time. Worth one manual pass, since the
  protocol flags it for "autocomplete that rewrites after insertion", which is
  a genuinely distinct failure mode.

### Two findings from the run

**`NSWorkspace.frontmostApplication` and System Events can disagree.** One
insertion aimed at Terminal landed in Comet: System Events reported Terminal as
frontmost while the app read Comet a moment later. It resolved on retry, so it
is a race rather than a defect, but it is the exact shape of global case 2
("focus stolen mid-dictation → never insert into the wrong app"), and the M1
chain currently re-validates the target only against the value captured at
key-down. **Worth hardening before this ships.**

**One stray insertion went into the Comet browser** during that race
(`echo terminal-insert-test`). Harmless text in a browser field, cleared by the
user, but recorded because a test that types into the wrong app is exactly the
failure the protocol exists to catch.

---

## 2026-08-12 — global case 2 CLOSED: focus stolen mid-dictation

The race observed earlier (an insertion aimed at Terminal landing in a browser)
is fixed and the fix is proven by staging the race rather than waiting for it.

`InsertionTestHook` grew a `delay`, so a target can be captured, focus stolen,
and the insertion then allowed to proceed. Aimed at one app, switched to Safari
mid-flight:

```
target moved from ai.perplexity.comet to com.apple.Safari
outcome=refused(reason: targetChanged)
```

| Check | Result |
|---|---|
| Inserted into the wrong app | ❌ never |
| Original target modified | ❌ unchanged (`GUARD2`) |
| Words lost | ❌ survived on the clipboard |
| Both apps named in the log | ✅ |
| Normal insertion still works | ✅ `still works ` |

**The fix:** `TargetGuard` is pure and tested (6 cases), and the chain now
re-checks **immediately before every tier attempt** rather than once at key-up.
The window it closes is not small: the modifier-clear wait alone runs up to
500ms, and the permission checks, the Accessibility context read and all the
pasteboard work happen after that.

Unknown counts as a refusal. Nothing to compare against is not permission to
paste anywhere, because the cost of a wrong guess is the user's words in
someone else's window.

**Incidental confirmation that the guard was needed:** while staging this, the
target was captured as the Comet browser even though TextEdit had just been
activated, because `NSWorkspace.frontmostApplication` had not caught up. The
lag is real and reproducible, not a one-off.

---

## 2026-08-12 — the hotkey could go permanently deaf, and never said so

**Reported as:** "when i clicked opt the mic isnt working." Not a microphone
fault. The app had been up since 17:23 and was wedged.

**Measured on the wedged process, before any change.** Two synthetic left
Option holds, fifteen seconds apart, against pid 61910:

```
flagsChanged leftOption down=true wasDown=false
keyDown entered
flagsChanged leftOption down=false wasDown=true
keyUp entered, listening=true
```

Nothing else, either time. No `capturing`, no `fed N buffers`, no panel, no
error. Which guard fired names the state exactly: `keyDown` returned at
`guard !isListening` (a session was believed live) and `keyUp` returned at
`guard isListening, let transcriber` (the transcriber was already gone). Both
return without logging, so the app refused every key for three hours in total
silence.

**Relaunch fixed it**, which confirmed a stuck state rather than a broken mic:

```
keyDown entered
capturing
keyUp entered, listening=true
fed 13 buffers
nothing heard
```

**The race.** `keyDown` set `isListening` LAST, after the async setup
(permission, format, prepare, begin). That gap measured **183ms** on this
machine. A release landing inside it checked a flag still false, was dropped,
and setup then went live with the key already up.

**After the fix, same hardware, same synthetic keys.** A 60ms tap, which lands
well inside the setup window:

```
keyDown entered
keyUp entered, listening=false
released while still starting; setup will stand down
released while still starting; standing down without capturing
```

Then a normal 1.5s hold four seconds later, which is the assertion that
matters, because this is what the old build could no longer do:

```
keyDown entered
capturing
keyUp entered, listening=true
fed 15 buffers
nothing heard
```

| Check | Result |
|---|---|
| Quick tap leaves the app listening | ❌ never (stands down) |
| A later hold still captures | ✅ `fed 15 buffers` |
| Refusals explain themselves | ✅ every `ignored` carries a reason |
| Setup-to-capture latency | 94ms this run, no regression |
| Words lost | ❌ nothing was captured to lose |

`nothing heard` is correct in both runs: these were synthetic key events with
nobody speaking. What they prove is the state machine, not the recogniser.

**The fix:** `PushToTalk` is pure and tested (9 cases), including the one that
would have caught this: after the race, the very next press must still be
accepted. The controller derives `isListening` from it, so there is one place
the answer lives. The second deaf path is closed too: the `no ring handle`
branch used to return with the app still listening, and now ends the session
it cannot run.

---

## 2026-08-12 (late) — the microphone now has to prove it can hear

**Requirement (founder):** "the mic should always work even when lid closed or
open or wired or not or wireless etc etc."

**What it was doing.** Lid closed, wired earphones plugged in. The built-in
microphone was the system default and delivered **exactly 0.0** across 240,000
frames while the Mac spoke aloud, measured by an independent tool with
confirmed `authorized` mic access. The app faithfully captured 59 buffers of
that nothing and showed "Listening…" throughout. The earphone mic was attached
the whole time, reading **0.094** on room noise alone, and nothing ever tried
it.

**Second fault, caught live.** With the app running, changing the default
input took it from `fed 59 buffers` to `fed 0 buffers`. The warm engine binds
its tap at launch and never re-binds, exactly as CLAUDE.md line 1389 warns.

**After the change, from the exact broken state** (default input forced back to
the dead built-in, lid still closed), with no user action at all:

```
warm engine running at 48000.0 Hz on MacBook Air Microphone
MacBook Air Microphone delivered nothing for 2s; moving to Microsoft Teams Audio
warm engine running at 48000.0 Hz on Microsoft Teams Audio
Microsoft Teams Audio delivered nothing for 2s; moving to External Microphone
warm engine running at 48000.0 Hz on External Microphone
```

Then a spoken phrase, start to finish:

```
capturing
fed 63 buffers
utterance: 46 chars, finalize 0.073730s, insert 0.149434s,
           outcome inserted(tier: systemEvents), ring overruns 0
```

TextEdit received: `Hello, this is a test of the dictation system.`

| Check | Result |
|---|---|
| Recovers from a dead default input | ✅ 2 hops, ~5s, no user action |
| Settles rather than thrashing | ✅ stops once an ear hears |
| Words still land | ✅ Tier 1, 0.149s |
| Latency regression | ❌ none (finalize 0.074s) |

**Two bugs this test found in the first version of the fix**, both fixed before
this entry was written:

1. CoreAudio manufactures a private aggregate for the process holding the
   default device (`CADefaultDeviceAggregate-<pid>-0`). Offered as a candidate,
   the app hopped to its own reflection.
2. Restarting the engine itself fires `AVAudioEngineConfigurationChange`, so
   acting on every notification is an infinite loop, and clearing every silent
   verdict on each one resurrected the dead built-in every cycle. Now only a
   real change to the set of attached devices counts, and only devices that
   just APPEARED are forgiven.

**Not covered here:** wireless. "Cj Microphone" came and went during the
session and was chosen once, but no Bluetooth headset was tested end to end.
CLAUDE.md line 850 still wants 10 to 15 corpus recordings on AirPods.

---

## 2026-08-15 — the merge, on the Release build

**The question this answers:** the merge design listed "the event tap under a
notarized hardened-runtime Release build" as an unverified risk that could turn
1.13.0 into a different release. Every earlier test in this file ran against a
development-signed Debug bundle. This one did not.

**Test article:** `Chalant.app`, Release configuration, `Developer ID
Application: Chetan Jonnalagadda (WV59PZX4A3)`, `flags=0x10000(runtime)`, same
bundle ID as the shipping app. Unnotarized, which changes Gatekeeper's launch
policy and nothing about runtime capability. Installed Chalant 1.12.4 and the
standalone `ChalantDictation` both quit first.

**Result: the tap works there.** Full chain, driven by a synthetic left Option
hold (keycode 58, `flagsChanged`, flag `0x20`, posted to `.cghidEventTap`) with
speech from `say`:

```
flagsChanged leftOption down=true wasDown=false
keyDown entered → capturing
flagsChanged leftOption down=false wasDown=true
keyUp entered, listening=true → fed 49 buffers
inserted at tier 1 into com.apple.TextEdit
```

Said "hello world this is a test of chalant dictation", TextEdit received
"How long world is this a test of challenge dictation?". The mishearings are a
speaker playing into a microphone, and `chalant` → `challenge` is exactly the
rare-term failure M4 and M5 exist to fix.

| Check | Result |
|---|---|
| Event tap installs under hardened runtime | ✅ |
| Event tap RECEIVES keys there | ✅ |
| Speech assets resolve | ✅ `en_US: available` |
| Insertion Tier 1 (System Events) lands | ✅ `com.apple.TextEdit` |
| Never-lose-text invariant | ✅ see below |
| Ring overruns | ✅ 0, every run |

**The invariant was tested for real, by accident, and it held.** The first
utterance ran before Accessibility was granted. Every tier failed and the
outcome was `leftOnClipboard(reason: "Press ⌘V to paste it.")` rather than
silent loss.

**What the test found, and it is the reason to run tests on real hardware:**

| utterance | finalize | insert |
|---|---|---|
| 1st (no Accessibility yet) | 0.150s | 0.145s → clipboard floor |
| **2nd, first real insert** | 0.137s | **3.644s** |
| 3rd | 0.134s | 0.007s |
| 4th | 0.043s | 0.044s |

The first insertion of a session cost **3.6 seconds** and every one after it
cost single-digit to low-double-digit milliseconds. It is not the paste: macOS
keeps System Events asleep and the first insertion pays to start it, while the
user watches their words not appear. Fixed by waking System Events in
`warmUp()` (`AutomationPermission.warm()`, which asks for nothing and so does
not violate Part 2 §5's ban on prompting at launch).

**Re-measured after the fix, first insert of a cold launch, System Events
killed beforehand:**

```
utterance: 71 chars, finalize 0.083528s, insert 0.091947s,
           outcome inserted(tier: systemEvents), ring overruns 0
```

**3.644s → 0.092s.** Warm end to end is roughly 0.05 to 0.18s, which does not
reproduce Part 0 §0.5's 1.45s-with-preheat or 2.2s-cold figures even under the
hardened runtime.

**Two other facts worth carrying:**

- **Synthetic left Option events DO reach the tap on this Mac**, contrary to the
  macOS 26.5 report that CGEvents are silently dropped. They arrive only once
  Input Monitoring is granted; before that the tap installs, logs "event tap
  installed", and receives nothing but `tapDisabled` events, which are delivered
  regardless of the mask. **"Installed" is not "hearing."**
- **`tccd` logs `Failed to match existing code requirement for subject
  com.cj.chalant and service kTCCServiceMicrophone`.** That is the XCTest host,
  not the app: `ChalantTests` runs Chalant as its host signed *Apple
  Development* while the shipping app is *Developer ID*, so the requirements
  cannot match. Microphone-dependent XCTests can never get real mic access here.

**Not covered:** a human holding the key rather than a synthetic event, a real
notarized+stapled artifact, AirPods, and the 12-app M1 grid, which this run did
not attempt. Only TextEdit and VS Code were targeted.

### Insertion grid, same day, merged Release binary

Re-run because the grid that passed before ran against the standalone
development-signed Debug bundle. The insertion code is byte-identical after the
merge, but the binary, the signing identity and the hardened runtime are not.

Driven synthetically: left Option held via `CGEvent` `flagsChanged`, speech from
`say`, target focused by `activate` only. Browsers used a local page with an
`autofocus` textarea so no synthetic click was needed to place the caret.

| App | Bundle | Class | Tier | finalize | insert |
|---|---|---|---|---|---|
| TextEdit | `com.apple.TextEdit` | native | **1** | 0.084s | 0.092s |
| Safari | `com.apple.Safari` | WebKit | **1** | 0.148s | 0.387s |
| Chrome | `com.google.Chrome` | Chromium, async pasteboard | **1** | 0.157s | 0.045s |
| VS Code | `com.microsoft.VSCode` | Electron | **1** | 0.047s | 0.092s |
| Cursor | `com.todesktop.230313mzl4w4u92` | Electron | **1** | 0.171s | 0.052s |

**Five for five at Tier 1. Zero text-loss events. `ring overruns 0` on every
run.** Chrome matters most of these: it is the async-pasteboard case the 1.5s
restore delay exists for, and it inserted in 45ms.

**The M1 gate is NOT passed by this run and is not claimed to be.** It wants 10
of 12 apps, and this covers 5. What it does establish is that every
*architectural class* in the grid passes with the merged binary.

**Deliberately not attempted, with reasons rather than omissions:**

| App | Why not |
|---|---|
| Messages, Mail | An errant Return sends to a real person |
| Xcode | Insertion would modify a real project; its autocomplete-rewrites-after-insert case remains untested |
| Terminal | Text would be left at a live shell prompt with no authorized way to clear it from here. The `sudo` secure-input case is the valuable one and needs a human |
| Slack | Installed but not attempted |
| Notion, iTerm2, Figma | Not installed on this machine |

Also unverified: read-back of what landed. `osascript` here is not authorized to
send Apple Events into Safari, so the evidence for these cells is the insertion
log rather than the text. TextEdit was read back directly and did contain the
dictated sentence.

---

## 2026-08-16 — the dictation strip (spec: 2026-08-16-dictation-strip-design.md)

Status: BUILT, NOT YET SEEN BY A HUMAN. `scripts/preview-strip`.

What a pass looks like, per the spec:
- [ ] hold with the target app on the external display: strip on THAT display
- [ ] hold with the target app on the Mac's screen: strip THERE, not the monitor
- [ ] rim, pool and dot visibly follow the voice; quiet room = faint, speech = lit
- [ ] mic covered: strip opens and stays dark (this is the pass condition)
- [ ] a 0.7s hold still visibly opens and closes
- [ ] music playing: ducks on hold, restores on release
- [ ] no words appear in the strip at any point

Result (founder, dated):

---

## 2026-08-16 — the warm engine wedges on a device change, and now heals itself

Branch `fix/audio-engine-survives-device-change`. Release builds, Developer ID,
installed at `/Applications/Chalant.app`. macOS 27.0, arm64. Driven by
`Dictation/tools/earprobe/earprobe`, which streams the log and posts a 2s
synthetic left-Option hold before and after each change (`log show` does not
keep info-level lines, so every number below was read live).

### What the founder hit (12:48, from their own use, before this branch)

`fed 28 buffers` → wired earphones plugged/unplugged → `fed 0 buffers` on
every hold until relaunch. Root cause fixed one commit back on this branch
(`6b7b458`): the ONE `AVAudioEngine` reused across a device change. That
change alone was HALF-verified: four clean holds (30/38/66/39 buffers) but no
device change ever landed in the log.

### Reproducing a 0-buffer wedge without hardware

`earprobe device` (a CoreAudio aggregate wrapping the built-in mic appears and
is made default input, then is destroyed) did NOT wedge the released 1.15.0:
`fed 19` before, `fed 19` after appear, `fed 19` after disappear, with the
engine restarting on the same instance in between. So the plug/unplug SET
change is not, by itself, the wedge on this Mac. Regression check only.

`earprobe rate` (the built-in mic's nominal sample rate changed under the
running engine, 48000 → 44100, the trigger Apple documents for a
configuration change) wedged BOTH builds identically:

| build | before | after 48000→44100 | after 44100→48000 |
|---|---|---|---|
| released 1.15.0 (`build/export`) | fed 19 | **fed 0** | fed 19 |
| fresh-engine fix `6b7b458` | fed 19 | **fed 0** | fed 19 |

No `input devices changed` line in either: no `AVAudioEngineConfigurationChange`
reached the app. Nothing restarted the engine. `peak` sat frozen above zero,
so `hopIfDeaf` called the mic alive. Restoring the rate healed the tap in
place. That is a wedge every safeguard in the file was blind to.

### After `TapPulse` (this commit's build)

| step | log |
|---|---|
| baseline hold | `fed 18` / `fed 20` (two runs) |
| rate 48000→44100, +2s | `tap on MacBook Air Microphone delivered no buffers for 2s; restarting the engine` then `warm engine running` |
| hold while still at 44100 | `fed 0` (the fresh engine still reports 48000 Hz; a fresh PROCESS reports 48000 Hz too, so this is CoreAudio's view, not ours) |
| every ~3s while inconsistent | restart, restart, restart |
| rate 44100→48000 | next restart takes, no more firings |
| hold | **`fed 19`**, no relaunch |
| `earprobe device` on this build | fed 19 / 20 / 19, unchanged |
| 75s idle | **0** watchdog firings |

Verdict: the fresh-engine fix is necessary and this makes it sufficient for
any wedge that shows up as a dead tap, whatever the cause and whether or not
a notification arrives. The engine retries every ~3s until the hardware is
consistent, then dictation resumes by itself.

Still unproven, honestly: that the founder's exact jack event goes through
this path rather than a third one. What is proven is that no dead-tap state
survives more than ~2s any more. The founder's next plug/unplug in ordinary
use is the remaining evidence; the pass is a `delivered no buffers ...
restarting` line (or none at all) followed by `fed [1-9]`.

### 17:07 to 17:25, same day: the founder's real device, and a crash of my own

**The founder said "its not listening". Chalant was not running.** Crash report
`Chalant-2026-08-16-170750.ips`: at 17:07:28 the tap on the built-in mic
stalled (the founder had connected a Beats Pill, a 16 kHz Bluetooth input, and
plugged the wired earphones), the watchdog rebuilt the engine, and at 17:07:45
a later rebuild's `installTap` RAISED `Failed to create tap due to format
mismatch, 1 ch, 16000 Hz`. Uncaught NSException, SIGABRT. **The watchdog had
turned a wedge into a crash.** The AUHAL log shows its stream-format change
landing 1.3s after a bind, so a rebuild inside that window reads a stale
format. Fixed by wrapping `installTap` and `engine.start` in the parent
project's `AudioGuard` (which VoiceController already used and this engine
never adopted: the two-ears debt), tearing down on a raise, and letting the
poll bring a downed engine back (one attempt per 5s).

**Then the founder-shaped event was caught live, `earprobe flip`** (default
input to the 16 kHz Pill and back, engine on the built-in mic, device SET
unchanged):

| step | 1.15.0 would have | this branch |
|---|---|---|
| default → Pill | sometimes nothing, sometimes the tap dies silently | same; watchdog restarts within 2s if it dies |
| default → built-in (the disconnect shape) | `input devices changed`, engine stopped itself, **dead until relaunch** | `engine stopped itself on a configuration change ... restarting` ~100ms after the flip |
| hold 1s after the flip back | fed 0 | **fed 19** |
| hold inside a 2s dead window | fed 0 | `was dead at key-down; rebuilding before capture` then **fed 18** |
| six holds 0.3s after six flips | | 19-20 each, no false rebuild |

Non-deterministic which direction disturbs the tap and whether a notification
arrives at all; three watchers now cover it whichever way it goes: the
notification (`engine.isRunning`), the 2s watchdog, and the key-down check.
Process alive through every run. Rate and device scenarios re-run on the final
build: unchanged.

**Still unproven, honestly:** the exact headphone-jack unplug with the engine
ON the earphone mic (lid closed). Every reproduction here had the engine on
the built-in mic. The founder's ordinary use is the remaining evidence.

---

## 2026-08-16 — names in one shot: the correction learner, measured in the founder's hands and then end to end

**Live test with the founder (18:30 to 18:45), 1.15.2:** dictate "Send the
Chalant build to Kizu and tell Aidan it is ready" into Slack, Chrome, TextEdit,
fix a name, wait. What actually happened, from the log and the corpus capture:

| app | inserted | observer verdict | why |
|---|---|---|---|
| VS Code (this terminal) | many | **can read** | |
| Slack | "Send the Shalan bill to Kizu and tell Aidan it is ready." | none | the next dictation (to the terminal, 11s later) cancelled the watch |
| Chrome | "Send the Chalawant bill to Pisu and tell it and it is ready." then, second try, all correct | **can read** | nothing left to correct on the watched try |
| TextEdit | "Send the Chalant bill to Kisu and tell Aden it is ready." | **can read** | the document still reads exactly that: no fix was typed |

Reading works in every app tried. Nothing was learned because the loop's shape
was wrong for a person: one watch that the next dictation anywhere cancels, a
20s window, exactly one changed word accepted, and two sightings of the SAME
pair before anything fires, while a name is misheard differently every time
(Chalant: Shalan, Chalawant, Chalant; Kizu: Kizu, Pisu, Kisu; Aidan: Aidan,
Aden). The founder: "it's not correcting at all ... we gotta get creative to
make it work in one or two shots".

**After this branch, end to end, driven by `say` into TextEdit with the fix
applied to the document by AppleScript (the same edit a person makes):**

```
heard   : Send the challenge bill to Kazu and tell Aiden it is ready.
fixed to: Send the Chalant bill to Kizu and tell Aidan it is ready.
learned : challenge -> Chalant (heard is a word), Kazu -> Kizu (not a word),
          Aiden -> Aidan (a word), all from ONE fix, 3 pairs from one sentence
second  : Send the challenge bill to Kizu and tell Aiden it is ready.
```

**Kizu right after one fix.** "challenge" and "Aiden" are dictionary words, so
their exact rewrite waits for a second fix by design (a one-shot alias would
have turned every ordinary "challenge" into "Chalant"; that was measured, not
imagined: it happened on the first build of this branch and was closed before
anyone dictated on it). The names themselves ("Chalant", "Aidan") are already in
the vocabulary after one fix, through the sound-and-confidence-gated path.

Also: watches are per app now (a dictation elsewhere no longer cancels Slack's),
45s not 20s, and several fixes in one sentence are several corrections.

## 2026-08-18 — names for both ears (verification/NAMES_2026-08-18.md)

**What changed:** the phonetic pass and the second ear both draw on `Names`:
typed names ("Add a name" under Learn my names, stored as `dictationTerms`),
learned names, and the names in Contacts that sound like something in the
utterance. The second ear reads up to 20 of them as its prompt before it
listens.

**Measured offline first** (Set E, 30 names-dense clips, the shipped 626 MB
model, `whisperkit-cli`): no names 29.9% WER at 0.91 s; all 34 names 18.6% at
2.17 s; the shipping selector's per-clip lists 10.0% at 1.56 s. Table and
method in the verification file.

**Live, 14:47, installed Release build of this branch (Developer ID, ditto
over /Applications):** synthetic left-Option hold + `say` into the scratch
window, Better hearing on, four learned names standing:

```
heard 4s of audio as 17 chars in 1.500680s with 4 names (14 prompt tokens)
hearing kept: implausible (17 vs 49 chars)
```

Prompt path live: 4 names, 14 tokens, ~+0.2 s. The hearing was mush because
speaker-to-mic audio on this Mac has been mush since 08-17 21:20 (`say` is for
timing only, see the ear entry); the plausibility guard kept the landed text.

**Not exercised live:** reading Contacts. macOS has not been asked on this Mac
(no `contacts:` line in the log at launch, which is the authorized path's only
line), and the ask is the founder's, from the "Use the names in Contacts"
button. `ContactNames.usable` (the filter) is unit-tested; `read()` is the same
`CNContactStore.enumerateContacts` the message door already uses.

**Settings looked at (14:49, screenshot of the installed build):** under Learn
my names, the six learned rows, then the Add a name box with its dim Add
button, its note, then the Contacts row in its not-determined state ("Use the
names in Contacts", bordered, with the note). Same shape as the hook-rules box
on the Agents page; no capsule, hairlines only between rows. The founder
reviews by pixels, so the PR asks them to look too.

## 2026-08-20 — nowhere-to-type rescue (feat/nowhere-to-type)

Not yet exercised live. The protocol rows to run at the founder's next
session: (1) click the desktop, hold Option, speak → island toast "Nowhere to
type", ⌘V in any app pastes the words, and NO ⌘Z ever reaches Finder;
(2) dictate into VS Code and Slack → no toast, insertion exactly as before
(AX reports nothing affirmative there); (3) focus a password field → toast
names the holder. Automated coverage: LandingRolesTests pins the verdict
table (affirmative-only, closed list, unknown roles fail toward nothing).

## 2026-08-20 — first-press dead mic (fix/first-press)

Live protocol for the founder's next session, wired earphones in:
(1) wait 10+ min so the ear rests, then FIRST press with earphones plugged:
the hold must land words (the key-down proof condemns a silent built-in in
under a second; log shows "heard nothing at key-down; condemned"); (2) the
auto-hop must never visit "Microsoft Teams Audio" (log); (3) a normal-length
utterance must land refined with polish wait <= 0.73 s while dictating into a
BACKGROUND-app target (VS Code), which exercises the latency-critical
activity against App Nap coalescing. Automated: InputChoiceTests pin the
virtual-device exile and the pin exception.

## 2026-08-20 — rescued words are keepers (fix/rescue-keeps-the-words)

Not yet exercised live. Born of a real loss the same evening: the founder
dictated at a bare window ("where is the text of what i spoke"), the words
went to the pasteboard transient-marked, and the island's Clipboard tab,
the one place a person looks, skipped them by design. Handed-back words now
carry no transient mark, so the pane archives them like any real copy.
Protocol rows for the founder's next session: (1) click the desktop, hold
Option, speak → toast "Nowhere to type. What you said is in your clips.",
AND the words appear as the top row of the island's Clipboard tab within a
second, AND they survive copying something else afterwards; (2) focus a
password field, dictate → toast still says "on the clipboard" and the words
must NOT appear in the Clipboard tab (transient kept, on purpose);
(3) normal dictation into VS Code → inserted as before, and NOTHING new
appears in the Clipboard tab (the paste mechanics stay masked; the user's
old clipboard is restored). Automated: PasteboardGuard item tests pin which
writes carry the mark; ClipboardStore tests pin that unmasked writes are
archived and masked ones are skipped.
