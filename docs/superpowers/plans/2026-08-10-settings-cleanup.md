# Settings Cleanup: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eight settings pages become six, and every page answers one question. No setting is deleted, moved out of reach, or renamed away from what it does (founder, 2026-08-10: "fewer pages, same power").

**Architecture:** Three pages (What shows, Glance, Arrangement) all answer "what appears and where", and two of them literally share a card title ("Beside the notch"). They become one page. `LayoutSection`'s editor splits into two reusable builders that stay in `DashboardLayout.swift` (its drag handlers and state stay put); `WhatShowsSection` renders them. `GlanceSection` and `LayoutSection` are then deleted along with their enum cases.

**Tech Stack:** SwiftUI (macOS 14+), XCTest, xcodegen.

## Global Constraints

- **No setting disappears.** Every toggle, picker, slider, drag row and button that exists today still exists after, with the same label, the same `@AppStorage` key, and the same behavior. This is a reorganization, not a cut.
- The finish's laws hold: no pills, tokens for sizes, `Theme.controlTint` for controls, mono group labels, no em dashes anywhere.
- `DashboardSection.sessions` and `FeatureFlags` are untouched (dark-shipped; `SessionCards.swift:342` and `SessionRoom.swift:177` still deep-link to `.sessions`).
- `DashboardSection.named(_:)` keeps working for whatever cases remain (the debug harness and `SessionStoreTests` use it); removing a case is expected to change what `named` resolves, and its test must be updated in the same task that removes the case.
- All 600 tests stay green at every commit. Branch: a new `settings-cleanup` off main. Commit per task. No merge, bump or release.

## The target

| Page | Cards | The one question |
|---|---|---|
| General | Startup, Opening, Voice, Tour | how the app behaves |
| What shows | What shows, In the island, Not shown, Presets, Beside the notch, Which one gets the space, What interrupts, Start over | what appears, and where |
| Island | Look, Motion, Accent | how the island looks |
| Displays | unchanged | per-screen shape |
| Keyboard | unchanged | shortcuts |
| About | unchanged | version and privacy |

Gone as pages: **Glance** and **Arrangement** (their cards move to What shows).

---

### Task 1: Split the arrangement editor into two builders

**Files:**
- Modify: `Chalant/Views/DashboardLayout.swift`

**Interfaces:**
- Produces, on a `LayoutCards` view struct (or as two `@ViewBuilder` computed properties on a shared type; pick one and keep it consistent): `islandArrangement` (the "In the island", "Not shown", "Presets" and "Start over" cards) and `collapsedOrder` (the "Beside the notch" precedence card). Both keep taking `@ObservedObject var layout: IslandLayoutStore`.
- `LayoutSection` keeps existing and keeps rendering exactly what it renders today, now by composing the two builders. Nothing else changes yet.

**Why first:** it proves the split compiles and behaves before any page moves, so a later task cannot blame a regression on the extraction.

- [ ] **Step 1: Extract**

Read the whole file first. Move the card bodies into the two builders without touching the drag handlers, `rowEditor`, `collapsedRow`, `hidden`, `add`, or any gesture/state code. `LayoutSection.body` becomes the same `VStack(spacing: Theme.Space.settingsGroup)` rendering `islandArrangement` then `collapsedOrder` in the same visual order it has today (verify the current order by reading, do not assume).

- [ ] **Step 2: Full suite green**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant 2>&1 | grep -E "error:|with [0-9]+ failure" | tail -3`

- [ ] **Step 3: Commit** (`refactor(settings): the arrangement editor splits into its two halves`)

---

### Task 2: What shows absorbs Glance

**Files:**
- Modify: `Chalant/Views/DashboardSections.swift` (`WhatShowsSection` gains Glance's cards; `GlanceSection` deleted)
- Modify: `Chalant/Views/Dashboard.swift` (the `DashboardSection` enum and the detail `switch`)
- Modify: `ChalantTests/SessionStoreTests.swift` if `testDashboardSectionNamedMatchesTheDebugHarnessSpellings` references a removed case

**Interfaces:**
- Consumes: nothing new.
- Produces: `WhatShowsSection` renders, after its existing cards, the two cards lifted verbatim from `GlanceSection` ("Beside the notch" and "What interrupts"), with their `@AppStorage` declarations moved along with them.

- [ ] **Step 1: Move the cards**

Lift `GlanceSection`'s body cards and every `@AppStorage` property they read (`glanceSession`, `collapsedSong`, `glanceAgents`, `glanceBattery`, `glanceMusic`, `glanceNextEvent`, the while-playing picker's key, and any other it declares: read the struct and move all of them) into `WhatShowsSection`. Keep every label, key, note and the `FeatureFlags.sessionsVisible` guard around the agents toggle exactly as they are. Delete `struct GlanceSection` once nothing references it.

- [ ] **Step 2: Remove the page**

In `Dashboard.swift`: delete `case glance` from `DashboardSection`, its `title` and `symbol` entries, and its arm of the detail `switch`. `visibleCases` and `named(_:)` need no edit beyond losing the case.

- [ ] **Step 3: Fix the test that pins section names**

`ChalantTests/SessionStoreTests.swift:3326` (`testDashboardSectionNamedMatchesTheDebugHarnessSpellings`) asserts specific spellings; if it names "glance", update that assertion to a section that still exists and say so in the report. `testEveryDashboardSectionIconResolves` iterates `allCases` and needs no edit.

- [ ] **Step 4: Full suite green**
- [ ] **Step 5: Commit** (`feat(settings): the glance moves in with what shows`)

---

### Task 3: What shows absorbs the arrangement

**Files:**
- Modify: `Chalant/Views/DashboardSections.swift` (`WhatShowsSection` renders the two builders)
- Modify: `Chalant/Views/DashboardLayout.swift` (delete `LayoutSection`)
- Modify: `Chalant/Views/Dashboard.swift` (enum + switch + the call site that passes `layout`)

**Interfaces:**
- Consumes: `islandArrangement` and `collapsedOrder` from Task 1.
- Produces: `WhatShowsSection` gains `@ObservedObject var layout: IslandLayoutStore`; `Dashboard.swift` passes `model.layout` to it.

- [ ] **Step 1: Render the builders in order**

`WhatShowsSection`'s body becomes, top to bottom: its existing content cards, then `islandArrangement` (In the island, Not shown, Presets, Start over), then Glance's "Beside the notch", then `collapsedOrder`, then "What interrupts". Rename `collapsedOrder`'s card title from "Beside the notch" to **"Which one gets the space"** so the page does not carry two cards with the same name; its existing note about precedence stays and now reads as that card's explanation.

- [ ] **Step 2: Remove the page**

Delete `case layout` from `DashboardSection` (title "Arrangement", symbol), its `switch` arm, and `struct LayoutSection`. Keep every other type in `DashboardLayout.swift`.

- [ ] **Step 3: Full suite green**
- [ ] **Step 4: Commit** (`feat(settings): arrangement moves in with what shows`)

---

### Task 4: Fewer cards inside the pages

**Files:**
- Modify: `Chalant/Views/DashboardSections.swift`

**Interfaces:** none; card grouping only.

- [ ] **Step 1: Merge General's two opening cards**

`GeneralSection` has "Opening the island" (the remember-last-tab toggle, since round 3 removed the finish toggle) and "Opening" (open on hover, open delay, close delay). They are one topic. Merge into a single card titled **"Opening"**, ordered: Open on hover, Open, Close, then a `SettingDivider()` and Remember last tab with its note. Delete the now-empty second card.

- [ ] **Step 2: Merge What shows' Blocks and Tools**

`WhatShowsSection`'s "Blocks" and "Tools" cards are both lists of things you can switch off. Merge into one card titled **"What shows"**, keeping every row in its current order: the Blocks rows first (Media, Ambience, Calendar today, Reminders + its list picker, Weather + its note), then a `SettingDivider()`, then the Tools rows (Shortcuts, Clipboard, Shelf, Notes, Focus & timers, Battery when present, and the Chat rows behind `FeatureFlags.chatVisible`). Keep every `FeatureFlags` guard exactly as it is.

- [ ] **Step 3: Full suite green**
- [ ] **Step 4: Commit** (`feat(settings): one card per topic, not two`)

---

### Task 5 (controller): The proof

- Rebuild, reinstall, relaunch.
- Screenshot all six remaining pages. Verify against this plan's table: six sidebar entries, every setting still present and operable, no duplicate card titles, the arrangement editor still drags, the weather toggle still works.
- Spot-check three settings end to end (flip one on each of three pages, confirm the island obeys).
- Full suite green.

## Self-review notes

- The founder's two rulings are both honored: no setting is deleted (their "fewer pages, same power" choice), and the retired full-customization rule is why no NEW setting is added here.
- Task 1 exists purely so the extraction is proven before the moves; Tasks 2 and 3 are then pure relocation.
- Test impact is named where it exists (the section-name test in Task 2) rather than left to be discovered.
- `LayoutSection`'s drag handlers and `IslandLayoutStore` are deliberately untouched: the editor is the most stateful thing in Settings and this plan moves where it renders, never how it works.
