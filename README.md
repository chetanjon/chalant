# Chalant

The AI-native dynamic island for Mac. Incumbents treat the notch as a widget shelf. Chalant's rule: **everything you put on the island can be asked about.**

The name: chalant is nonchalant without the non. French chaloir meant to care; nonchalant means not caring; chalant is the half English forgot to keep. This island is both halves at once, perfectly calm on the surface, quietly caring underneath.

<p align="center"><img src="docs/assets/chalant-demo.gif" width="560" alt="The island glances at what is playing, then opens into media controls, ambience, and focus."></p>

## Download

[**Download Chalant.dmg**](https://github.com/chetanjon/chalant/releases/latest/download/Chalant.dmg), always the newest build. Apple Silicon, macOS 14+, free. (Release notes live on the [releases page](https://github.com/chetanjon/chalant/releases/latest).) Or through Homebrew:

```bash
brew install --cask chetanjon/chalant/chalant
```

Open the disk image, drag Chalant to Applications, open it. Chalant is signed with a Developer ID certificate and notarized by Apple, so there is no warning to click past and no flag to pass. After that, updates take care of themselves: the island mentions a new version once, and one click installs it in place and relaunches (Sparkle, with updates signed by the project's own key; no browser, no re-download dance). Speech recognition is Apple standard dictation, there are no API keys anywhere, and Chalant asks the internet only for: whether a newer version exists (a daily check, switchable off in Settings), the update itself when you say yes, album art for what you play, favicons for sites you save, and the weather for your rounded location while that line is switched on. Each is fetched straight from its own source; this project runs nothing in the middle. The Live status API listens on localhost only; nothing it hears leaves the machine.

## v1 feature set

**Do** (the core surface)
- Hold the notch and talk, or tap and type. Same engine either way.
- `remind me to call amma at 6` becomes a real Reminder with an alarm.
- `schedule lunch with sarah friday at 1` becomes a real Calendar event.
- `agenda` or `today` drops today's calendar out of the notch. `join` opens the next meeting's video link (Zoom, Meet, Teams, Webex, FaceTime); the Today rows carry a tap-to-join chip, and the glance marks a joinable meeting with a small camera.
- `focus 25` starts a pomodoro, its progress ring live beside the notch. `stop focus` ends it. Sound stays yours: a session never starts, ducks, or stops ambience on its own.
- `timer 10` runs a countdown, its ring beside the notch. `stopwatch` counts up; `stop stopwatch` holds the reading on screen, `stopwatch` again rolls on, `reset stopwatch` clears. Also a chip in the Focus tab, with pause and reset buttons.
- `how much time left` reads the running sessions back; `cancel the timer` and its article-carrying kin stop the right thing, honestly ("No timer running." when there is none).
- Running sessions mark the closed pill with a small symbol (the progress ring, or a stopwatch glyph), never digits; numbers live in the open island.
- `brown noise` / `white noise` / `pink noise`, synthesized live in stereo, no audio files, works offline. `rain` / `fire` / `cafe` are recordings.
- `note: something` captures locally. `notes` lists. `clear notes` wipes.
- `play`, `pause`, `skip`, `previous` control music. `what's playing` names the track and where it plays; `volume up`, `turn the volume down a bit`, or `volume 30` turn the same knob the row's slider does (the player's own volume when it has one, the Mac's otherwise).
- `text amma: on my way` or `tell amma i'm on my way` reads the message back; only the word `send` fires it, as an iMessage through Messages. Nothing ever sends unconfirmed, and any other command drops the staged text. (`tell me ...` stays a question.)
- Dates parsed deterministically with NSDataDetector. Verbs by prefix. Zero network, zero key, instant.
- `read my screen` captures the front window, runs on-device OCR (Vision, keyless), and attaches the words as context for your next question; `summarize my screen` does it and answers in one breath; explain, describe, translate, and tldr lead the same way (`translate my screen to hindi`). Nothing is stored, nothing leaves the Mac; needs one Screen Recording yes.
- `left half`, `right half`, `maximize`, `center` snap the frontmost window. Bind the island to a key and it is a window manager with no chrome at all.
- `find parcel`, `where's the invoice`, `look for the contract` search your notes, clips, files, and today's day at once, and land you on whatever holds it.
- `what's new` reads the latest release notes right in the island.
- Anything beyond the verbs goes to the Mac's own on-device model, keyless.

**Voice**
- Hold to talk or tap the mic; recognition is Apple standard dictation, on-device when the model is warm, Apple dictation service otherwise, the same path Notes and Messages use. Your music ducks while you speak.

**Today** (the day, without opening Calendar)
- Today's events and reminders in one pane, in the order the day happens. Each meeting row carries a tap-to-join chip, and the glance beside the notch marks a joinable meeting with a small camera.
- A weather line rides along the top: the current temperature and a sky glyph for your location. On by default, though nothing is fetched until you grant location, and one switch in Settings turns it off for good.
- Calendar and Reminders have a switch each. Off is not cosmetic: the pane never touches the store, so the day stays private until you ask for it.

**Go** (the launcher grid)
- A quiet grid of the things you open all day: websites, apps, folders, and your own Shortcuts.app shortcuts, one tap each. Click and the island slips shut behind you.
- Built-in one-tap actions live on the same grid: Screenshot, Lock Screen, Dark Mode, Keep Awake, Mute, Screen Record.

**Notes**
- `note: something` captures without opening anything; the tab lists what you kept, and the notes live locally.

**Keyboard shortcuts**
- Any of the island's doors can take a system-wide combination: open or close the island, start listening, ask, clips, shelf, notes, Go, focus, settings. Record them in Settings; none is bound until you bind it.
- They go through Carbon's hot key API, not a global event monitor, so Chalant never asks for Accessibility and never sees a key it was not given.

**Battery**
- A panel with what is left, whether it is plugged in, and how the cells are holding up. The optional glance beside the notch is off by default, since the menu bar already carries a battery.

**Music**
- Whatever plays, anywhere: Spotify, Apple Music, YouTube in a browser, any app the system hears. While playing, the pill stays bare and a breathing album-color rim carries the signal; a small wave can dance beside the notch if you switch it on. Expand for artwork, transport, and scrubbing. Wave, rim, and the session mark each have their own switch in Settings, so the closed pill can be exactly as lively or as bare as you like.
- With music and a session running together, the wave keeps the left wing and the session mark crosses to the right.
- The opened island comes in two materials, ink or liquid glass, in Settings under Island. Closed, it is always ink; melting into the notch is its job.
- On a notchless monitor the collapsed island shows nothing at rest; the top edge still opens it on hover. One thing counts as a reason to surface briefly: a passing toast (a timer finishing, an update landing). It lives six seconds and clears itself.

**Clips** (clipboard history)
- Every copy is kept, text and images alike; disk is the only limit, the same as Finder or Photos. Pin the ones worth keeping to the top, remove any row by hand, or clear the lot at once (pins survive it). Password-manager copies (concealed/transient) are never stored.
- Brow glyph on any clip attaches it to Do: summarize, rewrite, translate.

**Shelf** (file drop)
- Drag files onto the notch, drag out, copy, or share.
- Brow glyph on PDFs and text files: attach contents and question them.

**Live status** (the open door)
- Anything on your Mac can put a status pill on the island, with the token Chalant mints on first launch:

  ```bash
  T=$(cat ~/Library/Application\ Support/Chalant/api-token)
  curl localhost:4242/activity -H "X-Chalant-Token: $T" \
       -d '{"id":"deploy","title":"Deploying","state":"working"}'
  ```

  States: `working`, `needs-input`, `done`, `failed`, `clear`; `GET /activities` lists, `DELETE /activity/<id>` clears. Loopback only, never leaves the machine.
- **Why a token, since it is loopback only.** Loopback is not a wall: every process on the machine can knock, including other logged-in accounts. Without one, anything could push a *convincing* pill, and a `needs-input` row sorts to the top wearing the app's own chrome, which is a good place to ask somebody for a password. The token is a 0600 file, so anyone who is already you can read it and nobody else can. Delete it and relaunch to rotate.
- `scripts/chalant` wraps it for humans and scripts and reads the token for you: `chalant working "Deploying"`, `chalant needs-input "Waiting on you"`, `chalant done "Build finished"`, `chalant clear`. Copy it into your PATH if you like it. `CHALANT_TOKEN` overrides.
- Made for the things that have no home: build scripts, deploys, renders, long downloads. The open island lists them attention-first (needs-input wears the accent); the closed pill never grows for any of it, and finished things fade on their own. Nothing posts unless you point it here.

**Deliberately cut:** webcam mirror, notes-as-panel, wallpapers, widget packs.

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
- No conversation memory in ask, each question is fresh.
- The weather line is a forecast model (Open-Meteo), not a thermometer, and its grid is coarser than a city. Expect it to sit a degree or three from the Weather app on your phone, which blends real station readings: measured across Phoenix on a August afternoon, actual stations spanned 95F to 100F while the model called the whole valley 99F. It is close enough to dress for and not close enough to argue with. Apple's own WeatherKit would match your phone exactly and was weighed and declined: it wants a provisioning profile and a permanent attribution mark on an island built around not spending space.
- Texting sends over iMessage only. A number that lives on the green side isn't reachable yet; SMS relay is untested ground and stays out until it can be tested honestly.
- Signed with a Developer ID certificate and notarized by Apple.

## Security posture

The honest version, since this app can touch a lot.

- **On device.** Every "ask" (voice, typed, screen reading) is answered by Apple's on-device model. Your screen's text and your clipboard never leave the Mac. There are no API keys and no cloud inference; the API-key era was deleted, not disabled.
- **Dictation is the one exception, and it is worth being plain about.** Turning speech into text is macOS's own dictation, the same path Notes and Messages use: on this Mac when the local speech model is ready, and through Apple's dictation service when it is not. Strict on-device-only was tried and spent a day answering "sound but no words" whenever that model was cold, so reliability won. Everything downstream of the transcript, the answer included, stays here. Type instead of talking and nothing is spoken to anyone.
- **What does reach the internet, all over HTTPS:** dictation audio when the local speech model is cold (above), the daily update check (GitHub, switchable off), the update download when you say yes (signed with the project's EdDSA key, so a forged update cannot install), album art for Apple Music tracks missing local art (the track's title and artist go to Apple's public iTunes Search API), favicons for sites you save (one request to each site), and the weather while that line is on. **The weather one is the only place your location is involved, so it is worth being plain about:** your latitude and longitude, rounded to two decimals (about a kilometre) before they leave, go to the public Open-Meteo API over HTTPS. No account, no identifier, nothing else about you, and nothing at all until you grant location and leave the line on. Switch the weather off in Settings and the request is never made. Nothing else.
- **The Live status API** listens on loopback only and now refuses any request wearing browser headers, so a web page you visit cannot push or spoof a pill. Local processes still can, by design; that is the whole feature.
- **Outbound messages** are never sent unheard: Chalant reads the exact words and recipient back to you and fires only when you say "send." The text is escaped before it touches AppleScript, so a message body can never become a command.
- **No sandbox, and that is deliberate:** automating your music and Messages, reading the front window, snapping windows, and launching apps all require reaching outside a sandbox. The app runs with your privileges and no more. The trade you are making is trust, and the answer to trust is that the whole source is [right here](https://github.com/chetanjon/chalant), and the build is reproducible from it.

## Roadmap

- Screen context shipped in 1.0.78, Messages sending in 1.0.66, self-updates in 1.0.86. What remains from the old list: a meeting brief before your next call, still earning its shape. (The menu bar countdown was pruned; the island already carries the countdown on every display, and two surfaces for one number is the kind of thing this app exists to refuse.)
- Distribution: signed and notarized since 1.11.0, as a disk image and through the Homebrew cask (`brew install --cask chetanjon/chalant/chalant`). The landing page is [live](https://chetanjon.github.io/chalant/).

## Attributions

- Self-updates: [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT), with archives signed by the project's own EdDSA key.
- Now-playing: the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause).
- Rain ambience: derived from ["Calm rain.wav"](https://commons.wikimedia.org/wiki/File:Calm_rain.wav) (Wikimedia Commons, CC BY-SA 4.0), trimmed, normalized, edge-faded.
- Cafe ambience: derived from ["Cafe ambiance.ogg"](https://commons.wikimedia.org/wiki/File:Cafe_ambiance.ogg) (Wikimedia Commons, CC0), level-reduced and seam-crossfaded for a calmer room.
- Fire ambience: derived from ["Campfire sound ambience.ogg"](https://commons.wikimedia.org/wiki/File:Campfire_sound_ambience.ogg) by Glaneur de sons (Wikimedia Commons, CC BY 3.0), normalized, softened, edge-faded.
- Weather: [Open-Meteo](https://open-meteo.com) (data CC BY 4.0), queried directly with a location rounded to about a kilometre.
- Brown, white and pink noise are synthesized in real time, in stereo.

Chalant is free, and its source is public so the trust above is checkable. The code is not licensed for reuse; all rights stay with the author.
