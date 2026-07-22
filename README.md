# Moai

The AI-native dynamic island for Mac. Incumbents treat the notch as a widget shelf. Moai's rule: **everything you put on the island can be asked about.**

The name: real moai are buried up to their shoulders. Ours is buried in the bezel. Only the head shows at the top of your screen, and it surfaces when you hold it. (Also: mo-AI. You heard it.)

## Download

[**Latest release**](https://github.com/chetanjon/moai/releases/latest). Apple Silicon, macOS 14+, free.

First open: macOS will ask once. System Settings, Privacy and Security, Open Anyway. Moai is unsigned because it is free and independent. Speech recognition is Apple standard dictation, there are no API keys anywhere, and beyond the optional Chat tab the only thing Moai asks the internet is whether a newer version exists (a daily check against GitHub releases, switchable off in Settings).

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
- Dates parsed deterministically with NSDataDetector. Verbs by prefix. Zero network, zero key, instant.
- Anything beyond the verbs goes to the Mac's own on-device model, keyless. Long conversations belong to the Chat tab and your own subscription.

**Voice**
- Hold to talk or tap the mic; recognition is Apple standard dictation, on-device when the model is warm, Apple dictation service otherwise, the same path Notes and Messages use. Your music ducks while you speak.

**Music**
- Spotify + Apple Music. Waveform wing when playing, transport on expand. Only talks to players already running.

**Clips** (clipboard history)
- Last 30 copies. Password-manager copies (concealed/transient) never stored.
- Brow glyph on any clip attaches it to Do: summarize, rewrite, translate.

**Shelf** (file drop)
- Drag files onto the notch, drag out, copy, or share.
- Brow glyph on PDFs and text files: attach contents and question them.

**Chat** (bring your own subscription)
- A small built-in browser under the notch pointing at Claude, ChatGPT, or Gemini; pick the service in Settings.
- You sign in with your own account, once; nothing is scraped, proxied, or automated, and no API key is involved.
- Moai is not affiliated with or endorsed by Anthropic, OpenAI, or Google.

**Deliberately cut:** webcam mirror, notes-as-panel, wallpapers, widget packs, agent monitoring.

## Permission prompts, in order of appearance

macOS will ask once each for: Microphone + Speech Recognition (first hold-to-talk), Reminders (first remind), Calendars (first schedule/agenda), Automation for Spotify/Music (first transport tap). All expected, approve them.

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

> Generate the Xcode project with xcodegen, build the Moai scheme, and fix any compile errors you hit, then run it. Do not change the design, architecture, feature scope, or the Design law section of the README. Test each verb from the README v1 feature list and fix what fails.

## Architecture (30 seconds)

- `NotchWindowController`: borderless non-activating NSPanel at screen-saver level, measured against the real notch via `NSScreen.safeAreaInsets` + auxiliary top areas. Global click monitor collapses the island.
- `NotchViewModel`: island state, active tab, and the context handoff (`askAbout`) that lets clips and files flow into the Do surface.
- `Features/`: MusicController (AppleScript polling), ClipboardStore (pasteboard polling, 1s), ShelfStore (drops, AirDrop, PDF/text extraction via PDFKit), NotesStore (UserDefaults).
- `Views/`: NotchRootView (the morphing shape + drop target + wings), ExpandedView (tabs + Do), MusicStrip, ClipboardView, ShelfView.
- `AIService`: Apple's on-device model for quick answers and verb translation, keyless.

## Known v1 trade-offs

- Music polling via AppleScript every 3s. Fine for v1; MediaRemote gives richer data (artwork, progress) but it's a private framework, revisit later.
- Clipboard is text-only for now. Images later.
- `.screenSaver` window level sits above fullscreen video. Revisit.
- No conversation memory in ask, each question is fresh.
- No global hotkey yet, click-to-open only.

## Roadmap

- **v1.5:** Messages sending, menu bar countdown, richer chat pane.
- **v2:** meeting brief before your next call, screen context, image clips, artwork via MediaRemote.
- Launch: notarized build ($99 Apple Developer), landing page with the mockup embedded, Homebrew cask.

## Audio attributions

- Rain ambience: derived from ["Calm rain.wav"](https://commons.wikimedia.org/wiki/File:Calm_rain.wav) (Wikimedia Commons, CC BY-SA 4.0) — trimmed, normalized, edge-faded.
- Cafe ambience: derived from ["Cafe ambiance.ogg"](https://commons.wikimedia.org/wiki/File:Cafe_ambiance.ogg) (Wikimedia Commons, CC0) — low-pass filtered and level-reduced for a calmer room.
- Fire ambience: derived from ["Campfire sound ambience.ogg"](https://commons.wikimedia.org/wiki/File:Campfire_sound_ambience.ogg) by Glaneur de sons (Wikimedia Commons, CC BY 3.0) — normalized, softened, edge-faded.
- Brown/white/pink noise are synthesized in real time.
