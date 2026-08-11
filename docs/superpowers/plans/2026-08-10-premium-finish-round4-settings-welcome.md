# Premium Finish, Round 4: Settings and Welcome: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Settings window and the welcome tour speak the island's finish: air instead of boxes, hairline rows, mono group labels, white-means-active, thin monochrome controls. No layout moves, nothing to relearn.

**Architecture:** All six settings components (`SettingCard`, `SettingRow`, `SettingToggle`, `SettingPicker`, `SettingNote`, `SettingDivider`) live in `Chalant/Views/Dashboard.swift:296-410` and are shared by all eight section views. Restyling the components re-dresses every page at once with zero call-site changes. The sidebar and the welcome tour are their own small tasks.

**Tech Stack:** SwiftUI (macOS 14+), XCTest, xcodegen.

## Global Constraints

- Founder's laws: no pills (active is white, never a capsule background), air over lines, tokens for every size, one symbol per meaning, no em dashes anywhere.
- Call sites do not change: the ~40 uses of `SettingToggle`/`SettingNote`/`SettingDivider` across `DashboardSections.swift` keep their exact spellings and their explicit `SettingDivider()` placements. Components restyle in place.
- `SectionHeader` (Components.swift:149) is shared with island surfaces (FocusPanel and kin): do NOT change it. If the settings group label needs different treatment, give `SettingCard` its own label view.
- The window keeps its `NavigationSplitView`, its eight sections, and their order. No setting moves, appears, or disappears.
- Sessions/chat and `FeatureFlags` untouched. Round 3's weather toggle and privacy copy stay exactly as they are.
- All 599 tests stay green. Branch `premium-finish`. Commit per task. No merge, bump, or release.

---

### Task 1: The settings components wear the finish

**Files:**
- Modify: `Chalant/Views/Dashboard.swift:296-410` (the shared row components)
- Test: `ChalantTests/MotionPourTests.swift` (extend; the round's active test file)

**Interfaces:**
- Consumes: `Theme.Fonts.headline/subhead/timeMono`, `Theme.Space.zone`, `Theme.Fonts.micro`.
- Produces: restyled components; every public initializer keeps its exact signature (`SettingCard(title:content:)`, `SettingRow(label:control:)`, `SettingToggle(label:isOn:)`, `SettingPicker(label:selection:options:width:)`, `SettingNote(_:)`, `SettingDivider()`), so no call site changes.

- [ ] **Step 1: Write the failing test**

Append to `MotionPourTests`:

```swift
    /// The finish reached the settings window (round 4): the group
    /// label is the island's own quiet mono voice, and the card draws
    /// no box. Pinned because a boxed card is the one thing that made
    /// the window read as a different app than the island.
    func testTheSettingsFinishTokensExist() {
        XCTAssertEqual(Theme.Space.settingsRow, 13)
        XCTAssertEqual(Theme.Space.settingsGroup, 30)
        _ = Theme.Fonts.groupLabel
    }
```

- [ ] **Step 2: Run it, verify it fails to build** (`settingsRow`, `settingsGroup`, `groupLabel` missing)

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/MotionPourTests 2>&1 | grep -E "error:|Test Case" | head -6`

- [ ] **Step 3: Add the tokens, then restyle**

In `Theme.Fonts`, after `timeMono`:

```swift
        /// A settings group's name: the same quiet mono voice the
        /// island uses for numbers, sized down and spaced out.
        static let groupLabel = Font.system(size: 11, weight: .medium, design: .monospaced)
```

In `Theme.Space`, after `zone`:

```swift
        /// A settings row's own breathing room, above and below its
        /// label. The window used to pack rows at card density; the
        /// finish gives each row the air the island's zones have.
        static let settingsRow: CGFloat = 13
        /// Between one settings group and the next.
        static let settingsGroup: CGFloat = 30
```

In `Dashboard.swift`, restyle exactly these five things and nothing else:

1. `SettingCard.body`: the group label becomes its own `Text(title.uppercased()).font(Theme.Fonts.groupLabel).tracking(1.6).foregroundStyle(Theme.textGhost)` (NOT `SectionHeader`, which stays untouched for island callers); the content `VStack` keeps `alignment: .leading` but drops `.padding(Self.inset)` and `.chalantCard()` entirely, so no box and no border; spacing between label and content becomes `Theme.Space.l`; the whole card keeps `.frame(maxWidth: .infinity, alignment: .leading)`. Delete the now-unused `inset` property (and its comment, which describes the boxed era).
2. `SettingRow.body`: add `.padding(.vertical, Theme.Space.settingsRow)` to the `HStack`, and the label becomes `Theme.textPrimary` (the name of a setting is the loudest thing in its row now that the box is gone).
3. `SettingToggle`: `.tint(Color.white.opacity(0.9))` replacing `.tint(accent)`; delete the now-unused `@Environment(\.chalantAccent)` property.
4. `SettingNote`: `.foregroundStyle(Theme.textTertiary)` (was `textHint`), and add `.padding(.bottom, Theme.Space.xs)` so a note sits with the row it explains rather than floating between two.
5. `SettingDivider`: `.fill(Theme.hairlineFaint)` stays; it is the row separator the founder's "lines are a last resort" rule allows inside a list.

Leave `SettingPicker`, `SettingsSwatch`, and every section view alone.

- [ ] **Step 4: Targeted test green, then full suite green**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant 2>&1 | grep -E "error:|with [0-9]+ failure" | tail -3`
Expected: 600 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Chalant/Views/Theme.swift Chalant/Views/Dashboard.swift ChalantTests/MotionPourTests.swift
git commit -m "feat(finish): the settings window drops its boxes for air"
```

---

### Task 2: The sidebar says where you are in white

**Files:**
- Modify: `Chalant/Views/Dashboard.swift:170-182` (the `List(selection:)` in the `NavigationSplitView` sidebar)

**Interfaces:**
- Consumes: `DashboardSection.visibleCases` (exists, dark-ship aware).
- Produces: a sidebar whose selected row is white text with no capsule. Selection still binds to `$selection.section`.

**Why:** the system draws a blue capsule behind the selected row, which is the one pill left in the app.

- [ ] **Step 1: Kill the capsule, keep the List**

Keep `List(selection: $selection.section)` and the `ForEach(DashboardSection.visibleCases)` with `.tag(section)` exactly as they are (that binding is what makes keyboard navigation and the detail switch work). Change only the row content and its background:

- The row label becomes an `HStack(spacing: Theme.Space.m)` of `Image(systemName: section.symbol).font(Theme.Fonts.iconThin(.m))` and `Text(section.title).font(Theme.Fonts.body)`, tinted `selection.section == section ? Theme.textPrimary : Theme.textGhost`, with `.frame(maxWidth: .infinity, alignment: .leading)` and `.contentShape(Rectangle())`.
- Add `.listRowBackground(Color.clear)` to the row so the system's selection fill has nothing to draw into.
- Keep `.tag(section)`, keep `.navigationSplitViewColumnWidth(...)`, keep `.scrollContentBackground(.hidden)` and `.background(Theme.backdropTop)`, keep the toolbar block untouched.

- [ ] **Step 2: Full suite green**

- [ ] **Step 3: Commit** (`feat(finish): the sidebar marks where you are in white, not blue`)

**Note for the controller's proof:** if AppKit still paints its selection fill under the row despite the clear row background, that is a known List-on-macOS behavior and the fallback is a `ScrollView` + `VStack` of `Button`s (losing arrow-key navigation, which is an acceptable trade for eight rows). Do NOT implement the fallback pre-emptively; the screenshot decides.

---

### Task 3: The welcome tour in the same voice

**Files:**
- Modify: `Chalant/Views/WelcomeView.swift`

**Interfaces:**
- Consumes: `Theme.Fonts.headline/subhead`, `Theme.Space.zone`.
- Produces: a restyled tour. No behavior, no copy, no step count changes.

- [ ] **Step 1: Restyle only**

- Step titles (`Text("Say it.")` at line 46, `Text("Say yes once.")` at line 64, and the `title` inside the `step(title:lines:)` helper): `Theme.Fonts.title` becomes `Theme.Fonts.headline`, keeping `Theme.textPrimary`.
- Body copy (`Theme.Fonts.body` on the permissions paragraph at line 68 and the `step` helper's lines): becomes `Theme.Fonts.subhead`, keeping its current `Theme.textSecondary`.
- The footnotes currently at `Theme.Fonts.caption` + `Theme.textHint` become `Theme.Fonts.caption` + `Theme.textTertiary`.
- The outer `VStack` spacing at line 16 becomes `Theme.Space.xl`; each step's inner `VStack` spacing becomes `Theme.Space.l`.
- The permissions button keeps its capsule: it is a real button, not a selection state, and the founder's no-pills law is about active-state chrome. Only its label font follows the body change (`Theme.Fonts.subhead`).
- Do not touch: `ChalantWordmark`, the `verb(...)` rows' glyph treatment, `PermissionPrimer`, the step count, `onExitCommand`, the `frame(height: 250)`.

- [ ] **Step 2: Full suite green**

- [ ] **Step 3: Commit** (`feat(finish): the first hello speaks the island's voice`)

---

### Task 4 (controller): The round proof

- Rebuild Release, reinstall, relaunch.
- Screenshot every settings page (General, What shows, Island, Displays, Arrangement, Glance, Keyboard, About) and the welcome tour (Settings > General > Show the welcome tour again), against the mockup's settings section.
- Confirm: no boxed cards, mono group labels, white-not-blue sidebar selection, thin monochrome toggles, air between rows, weather toggle still present and working, nothing moved.
- Full suite green; idle CPU unchanged.

## Self-review notes

- Spec coverage for round 4: "boxed cards become hairline-separated rows" (T1), "group labels go mono uppercase" (T1), "sidebar selection becomes white-text-no-pill" (T2), "toggles restyle thin and monochrome" (T1), "welcome tour adopts the same tokens" (T3), "no settings move, appear or disappear" (Global Constraints, verified at T4).
- Zero call-site churn by design: every component initializer keeps its signature, and the explicit `SettingDivider()` placements in `DashboardSections.swift` keep working because `SettingCard` does not auto-separate rows.
- `SectionHeader` is explicitly protected: it belongs to island surfaces and its island callers must not inherit a settings decision.
- T2 names its own fallback but forbids implementing it blind; the screenshot at T4 decides.
