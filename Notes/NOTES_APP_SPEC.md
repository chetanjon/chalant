# Notes — Build Spec

A dark, minimal notes app for iPhone. Native SwiftUI. Everything you need to build it is in this file.

---

## 1. What it is

- Replaces Apple Notes for quick capture.
- Black and white only. Dark mode only.
- Essentials: write, edit, delete, search, checklists.
- One extra: **pin a note to the Lock Screen** so you don't forget it.
- Syncs across the user's own devices through iCloud. No accounts, no server.

**Why native, not web:** Lock Screen widgets, a real app icon, and iCloud sync are only possible with a native app.

---

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI, iOS 17+ | Modern, fast to build |
| Data | SwiftData + CloudKit | Local storage with free iCloud sync |
| Lock Screen | WidgetKit (accessory widgets) | Only way to show content on Lock Screen |
| App ↔ Widget sharing | App Group + shared SwiftData container | Widget reads the pinned note |
| Language | Swift 5.9+ | |
| Tools | Xcode 15+ | Free. Apple Developer account needed for CloudKit and to install on your phone long-term ($99/yr; free account works for 7-day installs) |

---

## 3. Design system

### Colors (dark only)
```
background   #000000
foreground   #FFFFFF
muted        #7A7A7A   secondary text, timestamps
faint        #444444   placeholders
field        #1A1A1A   search bar fill, pressed states
rule         #222222   row separators
```
Semantic: the ONLY accent is white. Destructive is white on black, or black on white. No red, no blue.

### Typography (SF Pro, system font)
```
Screen title      34pt  semibold  tracking -0.03em
Note title (row)  17pt  semibold
Row preview       15pt  regular   color: muted
Row time          15pt  regular   color: foreground, monospaced digits
Editor body       17pt  regular   line height 1.6
Editor first line 17pt  semibold  (first line IS the title)
Labels/meta       13pt  regular   color: muted
```

### Spacing
- Horizontal page padding: 20pt
- Row vertical padding: 16pt
- Row separator: 1pt, color `rule`, inset 20pt from both edges
- Search bar: height 44pt, corner radius 12, fill `field`
- Compose button: 56pt circle, white, black pen glyph, bottom-right, 20pt from right, 24pt above safe area
- Minimum tap target: 44×44pt

### Icons
- SF Symbols, weight `.regular`, stroke look:
  - Search: `magnifyingglass`
  - Compose: `pencil` (or `square.and.pencil`)
  - Back: `chevron.left`
  - Delete: `trash`
  - Checklist: `checklist`
  - Pin: `pin` / `pin.fill`
- No emoji anywhere.

### App icon
- 1024×1024 PNG, pure black background, three white rounded horizontal bars, left-aligned:
  - Bar 1 (title): y 33%, width 62% of content width, height 7%, radius 3.5%
  - Bar 2: y 49%, width 100%, height 4.4%
  - Bar 3: y 62%, width 80%, height 4.4%
  - Content box: 23% inset on left and right
- Put in `Assets.xcassets/AppIcon`. Xcode generates all sizes.

---

## 4. Screens

### 4.1 Notes list (home)
```
┌──────────────────────────────┐
│  Notes                        │  34pt semibold
│  [🔍 Search              ]    │  44pt field
│                               │
│  Walking app v1 scope         │  17 semibold
│  9:14  Voice notes on walks…  │  15, time white, preview muted
│  ─────────────────────────    │  1pt rule
│  Groceries                    │
│  8:02  1/4 done · eggs, milk  │  checklist summary
│  ─────────────────────────    │
│  …                            │
│                          (✎)  │  56pt white circle, bottom right
└──────────────────────────────┘
```
Behavior:
- Sorted by `updatedAt` descending. Pinned note(s) float to the top with a small `pin.fill` glyph at the right of the title.
- Tap row → open editor.
- Swipe left → reveals white "Delete" block (88pt wide, black text). Tap to delete. No confirmation.
- Swipe left further (full swipe) → deletes immediately.
- Long press row → context menu: **Pin to Lock Screen** / **Unpin**, **Delete**.
- Empty state: "No notes yet. Tap the pen to write one." in `muted`, 15pt, top-left under search.
- Time format:
  - Today → `9:14 AM` style (locale)
  - Within 6 days → weekday abbreviation (`Thu`)
  - Same year → `Aug 28`
  - Older → `Aug 28, 2025`
- Preview text:
  - Plain note: all lines after the first, joined with spaces, single line, truncated.
  - Checklist note: `"{done}/{total} done · {first open items}"`. If all done: `"All done"`.

### 4.2 Search
- Tapping the search field expands it, shows **Cancel** on the right, keyboard up.
- Live filter on every keystroke, matches title AND body, case-insensitive.
- Matches highlighted: white background, black text (`mark` style).
- Count label above results: "2 notes" in `muted`, 13pt.
- No results: "No matches."
- Cancel clears and dismisses.

### 4.3 Editor
```
┌──────────────────────────────┐
│  ‹      [checklist] [trash] (Done)  │  44pt bar
│                               │
│  Walking app v1 scope         │  first line, semibold
│  Voice notes while walking.   │  body
│  …                            │
└──────────────────────────────┘
```
Behavior:
- One `TextEditor` (or `UITextView`). No separate title field. First non-empty line is the title.
- **Autosave** on every change (debounce 300–400ms). No save button. **Done** just dismisses.
- **No "Edited …" timestamp shown.** No visible focus ring.
- Cursor lands at the end of the text on open. Keyboard opens immediately for a new note.
- Back (`‹`) and Done both dismiss. Swipe-from-left-edge also dismisses.
- **Trash**: first tap turns the icon into the word "Delete" (white, semibold). Second tap within 3s deletes and dismisses. After 3s it reverts. No system alert.
- Empty note (only whitespace) is discarded on dismiss.
- Top bar also has a **pin** button (`pin` / `pin.fill`) — toggles Lock Screen pin for this note.

### 4.4 Checklists
Represented inline in the text. A line that starts with `□ ` is an open item, `■ ` is done.

- Checklist button in editor toolbar:
  - If cursor's line is NOT an item → prefix it with `□ `.
  - If it IS an item → remove the 2-char prefix (turns back into plain text).
- Tapping the `□`/`■` glyph (cursor lands at position 0–1 of that line) toggles it.
- Return key on an item line → inserts `\n□ ` (continues the list).
- Return on an EMPTY item line (`□ ` only) → removes the marker and ends the list.
- List row preview shows summary as described in 4.1.

> Implementation tip: keep the note body as a single `String`. Do all checklist logic as string manipulation on the current line. Do not build a rich text model.

---

## 5. Lock Screen pin (the key feature)

Goal: user pins a note; it shows on the Lock Screen so they see it every time they pick up the phone.

### How it works on iOS
Lock Screen widgets (iOS 16+) are the mechanism. The user adds your widget to their Lock Screen once (long-press Lock Screen → Customize → add widget). After that, your app controls what the widget shows.

### Widget spec
- Target: **Widget Extension**, family `.accessoryRectangular` (the wide Lock Screen slot). Also support `.accessoryInline` (one-line, above the clock) and `.systemSmall` (Home Screen) for free.
- Content: the **pinned note's title** (bold) + first line of body (regular), truncated to 2 lines. If it's a checklist, show `"2/5 · milk, eggs"`.
- If nothing is pinned: show "Nothing pinned" in a faint style, with a hint "Long-press a note to pin".
- Tapping the widget deep-links into the app and opens that note: URL scheme `notes://note/<uuid>`.
- Only ONE note can be pinned at a time (keeps the widget simple). Pinning a new one unpins the old.

### Data sharing between app and widget
1. Create an **App Group**: `group.com.yourname.notes` (Signing & Capabilities → App Groups, on BOTH the app target and the widget target).
2. Store the SwiftData database in the App Group container so both can read it. Simpler alternative that's totally fine: when a note is pinned or its text changes, the app writes a small JSON (`{id, title, preview, updatedAt}`) to `UserDefaults(suiteName: "group.com.yourname.notes")`. The widget only reads that.
3. After any pin/unpin/edit of the pinned note, call `WidgetCenter.shared.reloadAllTimelines()`.

### Optional: nudge the user to add the widget
First time they pin a note, show a one-time sheet: "Add Notes to your Lock Screen" with 3 steps and a "Got it" button. iOS doesn't allow apps to add widgets programmatically; the user must do it once.

### Optional stretch: Live Activity
If you want it to appear on the Lock Screen WITHOUT the user adding a widget, use ActivityKit (Live Activities). It shows as a banner on the Lock Screen and in Dynamic Island for up to 8 hours (12 in newer iOS), then auto-ends. Good for "remind me today" style pins. Ship the widget first; add this later if wanted.

---

## 6. Data model

```swift
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var text: String          // full body; first line = title
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool        // only one true at a time (enforce in code)

    init(text: String = "") {
        id = UUID()
        self.text = text
        createdAt = .now
        updatedAt = .now
        isPinned = false
    }
}
```

Derived (computed, not stored):
```swift
extension Note {
    var title: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"^[□■] "#, with: "", options: .regularExpression) }
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? "New note"
    }
    var bodyLines: [String] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropFirst())
    }
    var isChecklist: Bool { bodyLines.contains { $0.hasPrefix("□ ") || $0.hasPrefix("■ ") } }
    var checklistSummary: (done: Int, total: Int, open: [String]) { /* count ■ vs □ */ }
    var preview: String { /* per 4.1 rules */ }
}
```

### iCloud sync
```swift
let container = try ModelContainer(
    for: Note.self,
    configurations: ModelConfiguration(cloudKitDatabase: .automatic)
)
```
Requirements: iCloud capability on the app target, CloudKit checked, a container ID like `iCloud.com.yourname.notes`, and Background Modes → Remote notifications. SwiftData handles the rest. All model properties must have defaults or be optional for CloudKit (the init above satisfies this).

---

## 7. Project structure

```
Notes/
├── NotesApp.swift             // @main, ModelContainer, deep link handling
├── Models/
│   └── Note.swift             // model + computed helpers
├── Views/
│   ├── NotesListView.swift    // 4.1 + 4.2
│   ├── NoteRow.swift          // one row, swipe actions, context menu
│   ├── EditorView.swift       // 4.3 + 4.4 toolbar
│   └── ChecklistTextView.swift// UIViewRepresentable wrapping UITextView (needed for cursor/line control)
├── Logic/
│   ├── Checklist.swift        // pure string functions: toggle, insert, continue
│   ├── DateFormat.swift       // "when" formatter
│   └── PinStore.swift         // writes pinned note to App Group UserDefaults, reloads widget
├── Theme/
│   └── Theme.swift            // colors, fonts as static lets
└── Assets.xcassets/
    └── AppIcon

NotesWidget/                   // Widget Extension target
├── NotesWidget.swift          // TimelineProvider + views for accessoryRectangular/inline/systemSmall
└── Assets.xcassets
```

---

## 8. Key code sketches

### Theme
```swift
enum Theme {
    static let bg = Color.black
    static let fg = Color.white
    static let muted = Color(hex: 0x7A7A7A)
    static let faint = Color(hex: 0x444444)
    static let field = Color(hex: 0x1A1A1A)
    static let rule = Color(hex: 0x222222)
}
```
Force dark: in `NotesApp`, `.preferredColorScheme(.dark)` on the root view.

### Row swipe + context menu
```swift
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
    Button(role: .destructive) { delete(note) } label: { Text("Delete") }
        .tint(.white)   // white block, black text set via label styling
}
.contextMenu {
    Button(note.isPinned ? "Unpin" : "Pin to Lock Screen", systemImage: note.isPinned ? "pin.slash" : "pin") { togglePin(note) }
    Button("Delete", systemImage: "trash", role: .destructive) { delete(note) }
}
```

### Pin logic
```swift
func togglePin(_ note: Note) {
    let wasPinned = note.isPinned
    for n in allNotes { n.isPinned = false }
    note.isPinned = !wasPinned
    PinStore.write(note.isPinned ? note : nil)
    WidgetCenter.shared.reloadAllTimelines()
}
```

### PinStore
```swift
enum PinStore {
    static let suite = UserDefaults(suiteName: "group.com.yourname.notes")!
    struct Pinned: Codable { let id: UUID; let title: String; let preview: String; let updatedAt: Date }
    static func write(_ note: Note?) {
        if let n = note {
            let p = Pinned(id: n.id, title: n.title, preview: n.preview, updatedAt: n.updatedAt)
            suite.set(try? JSONEncoder().encode(p), forKey: "pinned")
        } else { suite.removeObject(forKey: "pinned") }
    }
    static func read() -> Pinned? {
        suite.data(forKey: "pinned").flatMap { try? JSONDecoder().decode(Pinned.self, from: $0) }
    }
}
```
Call `PinStore.write(note)` also from the editor's autosave whenever `note.isPinned` is true, so the widget stays current.

### Widget
```swift
struct Entry: TimelineEntry { let date: Date; let pinned: PinStore.Pinned? }

struct Provider: TimelineProvider {
    func placeholder(in: Context) -> Entry { .init(date: .now, pinned: .init(id: UUID(), title: "Groceries", preview: "eggs, milk, rice", updatedAt: .now)) }
    func getSnapshot(in: Context, completion: @escaping (Entry) -> Void) { completion(.init(date: .now, pinned: PinStore.read())) }
    func getTimeline(in: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, pinned: PinStore.read())], policy: .never))
    }
}

struct NotesWidgetView: View {
    let entry: Entry
    var body: some View {
        if let p = entry.pinned {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.headline).lineLimit(1)
                Text(p.preview).font(.caption).lineLimit(1)
            }
            .widgetURL(URL(string: "notes://note/\(p.id.uuidString)"))
        } else {
            Text("Nothing pinned").font(.caption)
        }
    }
}

@main
struct NotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NotesPinned", provider: Provider()) { NotesWidgetView(entry: $0) }
            .configurationDisplayName("Pinned note")
            .description("Shows the note you pinned.")
            .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall])
    }
}
```

### Deep link
In `NotesApp`: `.onOpenURL { url in /* parse notes://note/<uuid>, set selectedNote */ }`. Register the `notes` URL scheme in Info → URL Types.

### Checklist string helpers
```swift
enum Checklist {
    static let open = "□ ", done = "■ "
    static func isItem(_ line: Substring) -> Bool { line.hasPrefix(open) || line.hasPrefix(done) }
    static func toggle(_ line: String) -> String {
        line.hasPrefix(done) ? open + line.dropFirst(2) : done + line.dropFirst(2)
    }
    // lineRange(in text: String, at cursor: Int) -> Range<String.Index>
    // Use it in the UITextView delegate for: toolbar button, tap-to-toggle, and shouldChangeTextIn for Return.
}
```
Use `UITextView` via `UIViewRepresentable` for the editor. You need `selectedRange`, `textViewDidChange`, and `shouldChangeTextIn` for the Return-key behavior. SwiftUI's `TextEditor` doesn't expose the cursor.

---

## 9. Build order (do it in this sequence)

1. New Xcode project → App, SwiftUI, name **Notes**. Set deployment target iOS 17.
2. Add `Theme.swift`, force dark mode, set app icon.
3. `Note` model + `ModelContainer` (local only first, no CloudKit yet).
4. `NotesListView` with sample data. Get spacing and fonts exact.
5. `EditorView` with plain `TextEditor` + autosave. Wire create/open/delete.
6. Swap `TextEditor` for `ChecklistTextView` (UITextView). Implement checklist button, tap-toggle, Return behavior.
7. Search with highlighting.
8. Swipe-to-delete, context menu.
9. App Group + `PinStore` + pin toggle in list and editor.
10. Widget Extension target. Test on Lock Screen (Settings → long-press Lock Screen → Customize → add widget).
11. Deep link from widget into the note.
12. Turn on iCloud/CloudKit. Test on two devices.
13. First-pin onboarding sheet (optional).
14. TestFlight for friends: App Store Connect → TestFlight → add testers by email. They install via the TestFlight app. No App Store review needed for internal testers.

---

## 10. Sharing with friends

- **TestFlight** (recommended): up to 100 internal testers or 10,000 external. External needs a light review (1–2 days) once. Friends get a proper icon, updates auto-install.
- **App Store**: full review, $99/yr developer account. Do this once it's stable.

---

## 11. Non-goals (don't build these)

- Folders, tags, colors, fonts, themes
- Rich text, images, attachments
- Sharing/collaboration
- Accounts or login of any kind
- Light mode

---

## 12. Acceptance checklist

- [ ] App opens to the list in under 1s, pure black, no flashes of white
- [ ] New note opens with keyboard up and cursor ready
- [ ] Typing autosaves; killing the app loses nothing
- [ ] First line shows as the title in the list
- [ ] Search highlights matches in white
- [ ] Swipe left reveals white Delete; full swipe deletes
- [ ] Checklist button, tap-to-toggle, Return-continues, Return-on-empty-ends all work
- [ ] List preview shows `x/y done · items` for checklists
- [ ] Pin from context menu and editor; only one pinned at a time
- [ ] Lock Screen widget shows the pinned note within 2s of pinning
- [ ] Tapping the widget opens that note
- [ ] Notes appear on a second iPhone signed into the same iCloud within a minute
- [ ] App icon is the black tile with three white bars
