# Moai

The AI-native dynamic island for Mac. Incumbents treat the notch as a widget shelf. Moai's rule: **everything you put on the island can be asked about.**

The name: real moai are buried up to their shoulders. Ours is buried in the bezel. Only the head shows at the top of your screen, and it surfaces when you hold it. (Also: mo-AI. You heard it.)

<p align="center"><img src="docs/assets/moai-demo.gif" width="560" alt="The island glances at what is playing, then opens into media controls, ambience, and focus."></p>

## Download

[**Latest release**](https://github.com/chetanjon/moai/releases/latest). Apple Silicon, macOS 14+, free, MIT-licensed.

First open: macOS will ask once. System Settings, Privacy and Security, Open Anyway. Moai is unsigned because it is free and independent. Speech recognition is Apple standard dictation, there are no API keys anywhere, and beyond the optional Chat tab, Moai asks the internet only for: whether a newer version exists (a daily check against GitHub releases, switchable off in Settings), album art for what you play, and favicons for sites you save, each fetched from its own source, never through a third-party service. The Live status API listens on localhost only; nothing it hears leaves the machine.

## v1 feature set

**Do** (the core surface)
- Hold the notch and talk, or tap and type. Same engine either way.
- `remind me to call amma at 6` becomes a real Reminder with an alarm.
- `schedule lunch with sarah friday at 1` becomes a real Calendar event.
- `agenda` or `today` drops today's calendar out of the notch.
- `focus 25` starts a pomodoro with synthesized brown noise, countdown live in the notch wing. `stop focus` ends it.
- `timer 10` runs a countdown in the wing.
- `brown noise` / `white noise` / `pink noise`, generated live, no audio files, works offline.
- `note: something` captures locally. `notes` lists. `clear notes` wipes.
- `play`, `pause`, `skip`, `previous` control music.
- `text amma: on my way` reads the message back; only the word `send` fires it, as an iMessage through Messages. Nothing ever sends unconfirmed, and any other command drops the staged text.
- Dates parsed deterministically with NSDataDetector. Verbs by prefix. Zero network, zero key, instant.
- Anything beyond the verbs goes to the Mac's own on-device model, keyless. Long conversations belong to the Chat tab and your own subscription.

**Voice**
- Hold to talk or tap the mic; recognition is Apple standard dictation, on-device when the model is warm, Apple dictation service otherwise, the same path Notes and Messages use. Your music ducks while you speak.

**Music**
- Whatever plays, anywhere: Spotify, Apple Music, YouTube in a browser, any app the system hears. While playing, a small wave dances beside the notch (or nothing, in Quiet mode) and a breathing album-color rim carries the signal; expand for artwork, transport, and scrubbing. Wave, rim, and the session countdown each have their own switch in Settings, so the closed pill can be exactly as bare as you like.
- With music and a focus session running together, the wave keeps the left wing and the countdown crosses to the right.
- The opened island comes in two materials, ink or liquid glass, in Settings under Life. Closed, it is always ink; melting into the notch is its job.
- On a notchless monitor the collapsed island shows nothing at all; the top edge still opens it on hover. Pixels over someone's window need a reason to exist.

**Clips** (clipboard history)
- Last 30 copies. Password-manager copies (concealed/transient) never stored.
- Brow glyph on any clip attaches it to Do: summarize, rewrite, translate.

**Shelf** (file drop)
- Drag files onto the notch, drag out, copy, or share.
- Brow glyph on PDFs and text files: attach contents and question them.

**Live status** (the open door)
- Anything on your Mac can put a status pill on the island: `curl localhost:4242/activity -d '{"id":"deploy","title":"Deploying","state":"working"}'`. States: `working`, `needs-input`, `done`, `failed`, `clear`; `GET /activities` lists, `DELETE /activity/<id>` clears. Loopback only, never leaves the machine.
- Made for the things that have no home: Claude Code hooks, build scripts, deploys, renders, long downloads. Needs-input leads the island's glance and wears the accent; finished things fade on their own.
- Claude Code, for example: a Stop hook running `curl -s localhost:4242/activity -d '{"id":"claude","title":"Claude Code finished","state":"done"}'` puts the run's end on the island; a Notification hook with `"state":"needs-input"` flags it the moment it wants you.

**Chat** (bring your own subscription)
- A small built-in browser under the notch pointing at Claude, ChatGPT, or Gemini; pick the service in Settings.
- You sign in with your own account, once; nothing is scraped, proxied, or automated, and no API key is involved.
- Moai is not affiliated with or endorsed by Anthropic, OpenAI, or Google.

**Deliberately cut:** webcam mirror, notes-as-panel, wallpapers, widget packs. (Agent monitoring was cut in v1 and un-cut in 1.0.63; the world filled with agents.)

## Permission prompts, in order of appearance

macOS will ask once each for: Microphone + Speech Recognition (first hold-to-talk), Reminders (first remind), Calendars (first schedule/agenda), Contacts (first text, so the name you say finds its number), Automation for Spotify/Music (when music first plays; asked up front if your player is already open during the welcome tour), and Automation for Messages (staging your first text). All expected, approve them.

## Run it (on your Mac)

Needs macOS 14+ and Xcode installed.

```bash
brew install xcodegen
cd moai
xcodegen
open Moai.xcodeproj
```

In Xcode: select your personal team under Signing & Capabilities, then hit Run.

First music control triggers a macOS Automation permission prompt (Moai → Spotify/Music). Approve it once.

### Or let Claude Code do it

Open this folder in Claude Code and paste:

> Generate the Xcode project with xcodegen, build the Moai scheme, and fix any compile errors you hit, then run it. Do not change the design, architecture, feature scope, or the Design law section of the README. Test each verb from the README v1 feature list and fix what fails. For the texting verb, stage and drop only: never say send, and never send a message to anyone.

## Architecture (30 seconds)

- `NotchWindowController`: borderless non-activating NSPanel at status-bar level, measured against the real notch via `NSScreen.safeAreaInsets` + auxiliary top areas, re-measured through every display change. Global click monitor collapses the island.
- `NotchViewModel`: island state, active tab, and the context handoff (`askAbout`) that lets clips and files flow into the Do surface.
- `Features/`: MediaRemoteBridge + MusicController (system-wide now-playing via the vendored adapter, AppleScript enrichment for Spotify/Music extras), EventKitService (reminders and calendar, deterministic date parsing), ClipboardStore (pasteboard polling, 1s, text and images), ShelfStore (drops, AirDrop, PDF/text extraction via PDFKit), ActivityStore + ActivityServer (the localhost:4242 status door), MessageCourier (stage, read back, send only on "send"), NotesStore, ShortcutStore, VoiceController, FocusController.
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

## Roadmap

- **v2:** meeting brief before your next call, screen context. (Messages sending shipped in 1.0.66; menu bar countdown was pruned, the island already carries the countdown on every display, and two surfaces for one number is the kind of thing this app exists to refuse.)
- Distribution: Homebrew cask; a notarized build if enrollment ever earns its $99. The landing page is [live](https://chetanjon.github.io/moai/).

## Audio attributions

- Rain ambience: derived from ["Calm rain.wav"](https://commons.wikimedia.org/wiki/File:Calm_rain.wav) (Wikimedia Commons, CC BY-SA 4.0), trimmed, normalized, edge-faded.
- Cafe ambience: derived from ["Cafe ambiance.ogg"](https://commons.wikimedia.org/wiki/File:Cafe_ambiance.ogg) (Wikimedia Commons, CC0), low-pass filtered and level-reduced for a calmer room.
- Fire ambience: derived from ["Campfire sound ambience.ogg"](https://commons.wikimedia.org/wiki/File:Campfire_sound_ambience.ogg) by Glaneur de sons (Wikimedia Commons, CC BY 3.0), normalized, softened, edge-faded.
- Brown/white/pink noise are synthesized in real time.
