# Chalant

The AI-native dynamic island for Mac. Incumbents treat the notch as a widget shelf. Chalant's rule: **everything you put on the island can be asked about.**

The name: chalant is nonchalant without the non. French chaloir meant to care; nonchalant means not caring; chalant is the half English forgot to keep. This island is both halves at once, perfectly calm on the surface, quietly caring underneath.

<p align="center"><img src="docs/assets/chalant-demo.gif" width="560" alt="The island glances at what is playing, then opens into media controls, ambience, and focus."></p>

## Download

[**Download Chalant.zip**](https://github.com/chetanjon/chalant/releases/latest/download/Chalant.zip), always the newest build. Apple Silicon, macOS 14+, free. (Release notes live on the [releases page](https://github.com/chetanjon/chalant/releases/latest).) Or through Homebrew:

```bash
brew install --cask chetanjon/chalant/chalant
```

Unzip, drag Chalant to Applications, open it. First open: macOS will ask once. System Settings, Privacy and Security, Open Anyway. Chalant is unsigned because it is free and independent. After that, updates take care of themselves: the island mentions a new version once, and one click installs it in place and relaunches (Sparkle, with updates signed by the project's own key; no browser, no re-download dance). Speech recognition is Apple standard dictation, there are no API keys anywhere, and beyond the optional Chat tab, Chalant asks the internet only for: whether a newer version exists (a daily check, switchable off in Settings), the update itself when you say yes, album art for what you play, and favicons for sites you save, each fetched from its own source, never through a third-party service. The Live status API listens on localhost only; nothing it hears leaves the machine.

## v1 feature set

**Do** (the core surface)
- Hold the notch and talk, or tap and type. Same engine either way.
- `remind me to call amma at 6` becomes a real Reminder with an alarm.
- `schedule lunch with sarah friday at 1` becomes a real Calendar event.
- `agenda` or `today` drops today's calendar out of the notch. `join` opens the next meeting's video link (Zoom, Meet, Teams, Webex, FaceTime); the Today rows carry a tap-to-join chip, and the glance marks a joinable meeting with a small camera.
- `focus 25` starts a pomodoro with synthesized brown noise, its progress ring live beside the notch. `stop focus` ends it.
- `timer 10` runs a countdown, its ring beside the notch. `stopwatch` counts up; `stop stopwatch` holds the reading on screen, `stopwatch` again rolls on, `reset stopwatch` clears. Also a chip in the Focus tab, with pause and reset buttons.
- `how much time left` reads the running sessions back; `cancel the timer` and its article-carrying kin stop the right thing, honestly ("No timer running." when there is none).
- Running sessions mark the closed pill with a small symbol (the progress ring, or a stopwatch glyph), never digits; numbers live in the open island.
- `brown noise` / `white noise` / `pink noise`, generated live, no audio files, works offline.
- `note: something` captures locally. `notes` lists. `clear notes` wipes.
- `play`, `pause`, `skip`, `previous` control music. `what's playing` names the track and where it plays; `volume up`, `turn the volume down a bit`, or `volume 30` turn the same knob the row's slider does (the player's own volume when it has one, the Mac's otherwise).
- `text amma: on my way` or `tell amma i'm on my way` reads the message back; only the word `send` fires it, as an iMessage through Messages. Nothing ever sends unconfirmed, and any other command drops the staged text. (`tell me ...` stays a question.)
- Dates parsed deterministically with NSDataDetector. Verbs by prefix. Zero network, zero key, instant.
- `read my screen` captures the front window, runs on-device OCR (Vision, keyless), and attaches the words as context for your next question; `summarize my screen` does it and answers in one breath; explain, describe, translate, and tldr lead the same way (`translate my screen to hindi`). Nothing is stored, nothing leaves the Mac; needs one Screen Recording yes.
- `what's new` reads the latest release notes right in the island.
- Anything beyond the verbs goes to the Mac's own on-device model, keyless. Long conversations belong to the Chat tab and your own subscription.

**Voice**
- Hold to talk or tap the mic; recognition is Apple standard dictation, on-device when the model is warm, Apple dictation service otherwise, the same path Notes and Messages use. Your music ducks while you speak.

**Music**
- Whatever plays, anywhere: Spotify, Apple Music, YouTube in a browser, any app the system hears. While playing, the pill stays bare and a breathing album-color rim carries the signal; a small wave can dance beside the notch if you switch it on. Expand for artwork, transport, and scrubbing. Wave, rim, and the session mark each have their own switch in Settings, so the closed pill can be exactly as lively or as bare as you like.
- With music and a session running together, the wave keeps the left wing and the session mark crosses to the right.
- The opened island comes in two materials, ink or liquid glass, in Settings under Life. Closed, it is always ink; melting into the notch is its job.
- On a notchless monitor the collapsed island shows nothing at rest; the top edge still opens it on hover. One thing counts as a reason to surface briefly: a passing toast (a timer finishing, an update landing). It lives six seconds and clears itself.

**Clips** (clipboard history)
- Last 30 copies. Password-manager copies (concealed/transient) never stored.
- Brow glyph on any clip attaches it to Do: summarize, rewrite, translate.

**Shelf** (file drop)
- Drag files onto the notch, drag out, copy, or share.
- Brow glyph on PDFs and text files: attach contents and question them.

**Live status** (the open door)
- Anything on your Mac can put a status pill on the island: `curl localhost:4242/activity -d '{"id":"deploy","title":"Deploying","state":"working"}'`. States: `working`, `needs-input`, `done`, `failed`, `clear`; `GET /activities` lists, `DELETE /activity/<id>` clears. Loopback only, never leaves the machine.
- `scripts/chalant` wraps it for humans and scripts: `chalant working "Deploying"`, `chalant needs-input "Waiting on you"`, `chalant done "Build finished"`, `chalant clear`. Copy it into your PATH if you like it.
- Made for the things that have no home: build scripts, deploys, renders, long downloads. The open island lists them attention-first (needs-input wears the accent); the closed pill never grows for any of it, and finished things fade on their own. Nothing posts unless you point it here.

**Chat** (bring your own subscription)
- A small built-in browser under the notch pointing at Claude, ChatGPT, or Gemini; pick the service in Settings.
- You sign in with your own account, once; nothing is scraped, proxied, or automated, and no API key is involved.
- Chalant is not affiliated with or endorsed by Anthropic, OpenAI, or Google.

**Deliberately cut:** webcam mirror, notes-as-panel, wallpapers, widget packs. (Agent monitoring was cut in v1 and un-cut in 1.0.63; the world filled with agents.)

## Permission prompts, in order of appearance

macOS will ask once each for: Microphone + Speech Recognition (first hold-to-talk), Reminders (first remind), Calendars (first schedule/agenda), Contacts (first text, so the name you say finds its number), Automation for Spotify/Music (when music first plays; asked up front if your player is already open during the welcome tour), Automation for Messages (staging your first text), and Screen Recording (first "read my screen"; may need a relaunch to take). All expected, approve them.

## Run it (on your Mac)

Needs macOS 14+ and Xcode installed.

```bash
brew install xcodegen
cd chalant
xcodegen
open Chalant.xcodeproj
```

In Xcode: select your personal team under Signing & Capabilities, then hit Run. `xcodebuild test -scheme Chalant` runs the unit suite (the parsing rules, version comparator, and session grammar that were each paid for live).

First music control triggers a macOS Automation permission prompt (Chalant → Spotify/Music). Approve it once.

### Or let Claude Code do it

Open this folder in Claude Code and paste:

> Generate the Xcode project with xcodegen, build the Chalant scheme, and fix any compile errors you hit, then run it. Do not change the design, architecture, feature scope, or the Design law section of the README. Test each verb from the README v1 feature list and fix what fails. For the texting verb, stage and drop only: never say send, and never send a message to anyone.

## Architecture (30 seconds)

- `NotchWindowController`: borderless non-activating NSPanel at status-bar level, measured against the real notch via `NSScreen.safeAreaInsets` + auxiliary top areas, re-measured through every display change. Global click monitor collapses the island.
- `NotchViewModel`: island state, active tab, and the context handoff (`askAbout`) that lets clips and files flow into the Do surface.
- `Features/`: MediaRemoteBridge + MusicController (system-wide now-playing via the vendored adapter, AppleScript enrichment for Spotify/Music extras), EventKitService (reminders and calendar, deterministic date parsing), ClipboardStore (pasteboard polling, 1s, text and images), ShelfStore (drops, AirDrop, PDF/text extraction via PDFKit), ActivityStore + ActivityServer (the localhost:4242 status door), MessageCourier (stage, read back, send only on "send"), UpdateChecker (the quiet daily version check; Sparkle does the in-place install when you say yes), NotesStore, ShortcutStore, VoiceController, FocusController.
- `Views/`: NotchRootView (the morphing shape, ink and glass materials, drop target, wings), ExpandedView (tabs + Do), IslandRows (the media row), SettingsPane.
- `AIService`: Apple's on-device model for quick answers and verb translation, keyless.

## Design law

The rules every round is built under, in the order they were paid for:

- One way per job. When two surfaces do the same thing, the worse one gets cut.
- No fixed-height voids. The island hugs what it shows.
- Nothing pins the island open. Drafts and staged messages survive collapse instead.
- Closed, the island is ink and melts into the hardware. Materials are for the opened shell.
- Nothing outward-facing fires unconfirmed. A text reads back before it sends.
- Copy tells the truth the moment architecture changes.

## Known trade-offs

- Now-playing rides a vendored MediaRemote adapter (BSD-3) loaded through `/usr/bin/perl`; if a future macOS closes that door, the app falls back to AppleScript polling for Spotify and Apple Music only.
- No conversation memory in ask, each question is fresh. Long conversations belong to the Chat tab.
- No global hotkey, by choice: every summon key collided with something. Hover, the mic, or the typed bar open the island.
- Texting sends over iMessage only. A number that lives on the green side isn't reachable yet; SMS relay is untested ground and stays out until it can be tested honestly.
- Unsigned; the first open needs one Open Anyway.

## Security posture

The honest version, since you are running an unsigned app that can touch a lot.

- **On device.** Every "ask" (voice, typed, screen reading) is answered by Apple's on-device model. Your words, your screen's text, and your clipboard never leave the Mac. There are no API keys and no cloud inference; the API-key era was deleted, not disabled.
- **What does reach the internet, all over HTTPS:** the daily update check (GitHub, switchable off), the update download when you say yes (signed with the project's EdDSA key, so a forged update cannot install), album art for Apple Music tracks missing local art (the track's title and artist go to Apple's public iTunes Search API), favicons for sites you save (one request to each site), and whatever you do in the optional Chat tab under your own login. Nothing else.
- **The Live status API** listens on loopback only and now refuses any request wearing browser headers, so a web page you visit cannot push or spoof a pill. Local processes still can, by design; that is the whole feature.
- **Outbound messages** are never sent unheard: Chalant reads the exact words and recipient back to you and fires only when you say "send." The text is escaped before it touches AppleScript, so a message body can never become a command.
- **No sandbox, and that is deliberate:** automating your music and Messages, reading the front window, snapping windows, and launching apps all require reaching outside a sandbox. The app runs with your privileges and no more. The trade you are making is trust, and the answer to trust is that the whole source is [right here](https://github.com/chetanjon/chalant), and the build is reproducible from it.

## Roadmap

- Screen context shipped in 1.0.78, Messages sending in 1.0.66, self-updates in 1.0.86. What remains from the old list: a meeting brief before your next call, still earning its shape. (The menu bar countdown was pruned; the island already carries the countdown on every display, and two surfaces for one number is the kind of thing this app exists to refuse.)
- Distribution: the Homebrew cask is live (`brew install --cask chetanjon/chalant/chalant`); a notarized build if enrollment ever earns its $99. The landing page is [live](https://chetanjon.github.io/chalant/).

## Attributions

- Self-updates: [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT), with archives signed by the project's own EdDSA key.
- Now-playing: the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause).
- Rain ambience: derived from ["Calm rain.wav"](https://commons.wikimedia.org/wiki/File:Calm_rain.wav) (Wikimedia Commons, CC BY-SA 4.0), trimmed, normalized, edge-faded.
- Cafe ambience: derived from ["Cafe ambiance.ogg"](https://commons.wikimedia.org/wiki/File:Cafe_ambiance.ogg) (Wikimedia Commons, CC0), low-pass filtered and level-reduced for a calmer room.
- Fire ambience: derived from ["Campfire sound ambience.ogg"](https://commons.wikimedia.org/wiki/File:Campfire_sound_ambience.ogg) by Glaneur de sons (Wikimedia Commons, CC BY 3.0), normalized, softened, edge-faded.
- Brown/white/pink noise are synthesized in real time.

Chalant is free, and its source is public so the trust above is checkable. The code is not licensed for reuse; all rights stay with the author.
