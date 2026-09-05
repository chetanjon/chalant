# Notes

A dark, minimal notes app for iPhone. Black and white, dark mode only. Write,
edit, delete, search, checklists, and one extra: pin a note to the Lock Screen.
Notes sync between your own devices through iCloud; there are no accounts and
no server.

The spec this was built from is `NOTES_APP_SPEC.md` in the project root.

## Layout

```
Notes/
├── project.yml                 xcodegen spec: app, widget, tests
├── Notes/                      the app
│   ├── NotesApp.swift          @main, model container, deep link
│   ├── Models/                 Note (SwiftData) and NoteStore (create, delete, pin)
│   ├── Views/                  list, row, editor, UITextView wrapper, widget hint
│   ├── Logic/                  pure string logic: Checklist, NoteText, DateFormat, PinStore
│   ├── Theme/                  colours, fonts, spacing
│   └── Assets.xcassets/        AppIcon (generated), launch background
├── NotesWidget/                the Lock Screen widget extension
├── NotesTests/                 XCTest, runs on the simulator
└── scripts/make-icon.py        draws AppIcon.png from the numbers in the spec
```

Identifiers, all under the same team as Chalant:

| What | Value |
|---|---|
| App | `com.cj.notes` |
| Widget | `com.cj.notes.widget` |
| App Group | `group.com.cj.notes` |
| iCloud container | `iCloud.com.cj.notes` |
| URL scheme | `notes://note/<uuid>` |

## Build

Needs Xcode 15 or newer and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Nothing else.

```bash
cd Notes
xcodegen generate
open Notes.xcodeproj
```

Pick the `Notes` scheme, pick your iPhone, press Run. The first run on a
device makes Xcode register the App Group and the iCloud container with your
developer account; that happens on its own with automatic signing.

Tests: `⌘U` in Xcode, or

```bash
xcodebuild test -project Notes.xcodeproj -scheme Notes \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Free developer account

A free account cannot carry the iCloud or push entitlements. Delete the
`com.apple.developer.icloud-*` and `aps-environment` keys under
`entitlements.properties` in `project.yml`, regenerate, and the app builds
and runs with local storage only. The code falls back to a local store
when CloudKit is unavailable, so nothing else changes. Installs from a free
account last seven days.

## The Lock Screen widget

iOS does not let an app add a widget for you. Once, on the phone: lock it,
press and hold the Lock Screen, tap Customize, choose Lock Screen, tap the
widget area under the clock, and add Notes. From then on the pinned note
shows there. The app shows these steps once, the first time a note is pinned.

The widget never opens the database. When a note is pinned, unpinned, or
edited while pinned, the app writes a small record (id, title, preview, date)
to the App Group's `UserDefaults` and asks WidgetKit to reload. Tapping the
widget opens the app on that note.

## Ship

1. **App Store Connect**: create the app record with bundle id `com.cj.notes`
   (Apps → + → New App). The widget needs no record of its own.
2. **Archive**: in Xcode, Product → Archive with "Any iOS Device" selected.
   Release builds use automatic signing, same as Debug.
3. **Upload**: in the Organizer, Distribute App → TestFlight & App Store →
   Upload. Xcode manages the profiles.
4. **TestFlight**: in App Store Connect, under TestFlight, add testers by
   email. Internal testers (your team) need no review. External testers go
   through a short review once, a day or two. They install through the
   TestFlight app and later builds update on their own.
5. **App Store**: when it is stable, fill in the listing and submit the same
   build for review.

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
before each upload; App Store Connect refuses a build number it has seen.

## What is and is not built

Everything in the spec's acceptance list is implemented: autosave, the
first-line title, search with white-on-black highlights, swipe to delete,
checklists (button, tap to toggle, Return continues, Return on an empty item
ends), list previews, single pin, the widget in all three families, the
deep link, CloudKit sync, the app icon, and the one-time widget hint.

Two places iOS decides, not the spec: the swipe-to-delete block is as wide
as the system makes it (the spec asks for 88pt), and the widget's text uses
the Lock Screen's own rendering, so it is always white on the wallpaper.

Not built, on purpose: folders, tags, colours, rich text, attachments,
sharing, accounts, light mode, and the Live Activity stretch goal.
