# Premium Finish, Round 1: The Look — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the island to the founder-approved mockup (spec: `docs/superpowers/specs/2026-08-10-premium-finish-design.md`): air instead of dividers, typography instead of pills, thin icons, monospace time with remaining-time, full-width progress, text-only ambience chips.

**Architecture:** All new values land as named tokens in `Chalant/Views/Theme.swift` first, then each island row view (`IslandRows.swift`, `TabRow.swift`, `TodayView` in `ExpandedView.swift`) is restyled to consume them. New logic (remaining-time text, scrub-position math) is extracted into testable statics before the views use them.

**Tech Stack:** SwiftUI (macOS 14+), XCTest, xcodegen. Build/test with `xcodebuild test -project Chalant.xcodeproj -scheme Chalant`.

## Global Constraints

- Flat pure black island: no borders, glow, shadows, gradients or translucency on the shell or its rows (standing rule since 1.0.1; this round DELETES several existing glows).
- No raw `.system(size:)` or raw spacing numbers in views; every value is a `Theme` token.
- No pills: active means white (`Theme.textPrimary`), inactive means dim. No capsule backgrounds on chips, tabs or labels.
- One symbol per meaning: `speaker.wave.2.fill` is the only volume icon.
- No em dashes anywhere, in code comments or UI copy.
- Sessions and Chat stay dark-shipped; do not touch `FeatureFlags`, their views, or the gate.
- Motion: respect `Theme.Feel` and Reduce Motion; never animate `.frame` inside a high-rate `TimelineView`.
- All 587 existing tests stay green. No version bump, no merge, no release.
- Branch: `premium-finish`. Commit after every task.

---

### Task 1: The round-1 tokens

**Files:**
- Modify: `Chalant/Views/Theme.swift` (Fonts enum ~line 98, Space enum ~line 149, Radius enum ~line 177, Island enum ~line 187)
- Test: `ChalantTests/FinishTokensTests.swift` (create)

**Interfaces:**
- Produces: `Theme.Fonts.headline` (18pt semibold), `Theme.Fonts.subhead` (15pt regular), `Theme.Fonts.timeMono` (13pt medium monospaced), `Theme.Fonts.iconThin(_ scale:)` (regular-weight icon font), `Theme.Space.zone` (26), `Theme.Radius.artwork` (14), `Theme.Island.radiusExpanded` (40). Later tasks consume these exact names.

- [ ] **Step 1: Write the failing test**

Create `ChalantTests/FinishTokensTests.swift`:

```swift
import SwiftUI
import XCTest

@testable import Chalant

/// The premium-finish tokens (spec 2026-08-10). Pinned so a future
/// cleanup cannot quietly drift the approved look.
@MainActor
final class FinishTokensTests: XCTestCase {
    func testTheFinishTokensExistAtTheirApprovedValues() {
        XCTAssertEqual(Theme.Space.zone, 26)
        XCTAssertEqual(Theme.Radius.artwork, 14)
        XCTAssertEqual(Theme.Island.radiusExpanded, 40)
        // Fonts are opaque; existence is the assertion. A wrong size
        // shows up in the screenshot proof, a deleted token here.
        _ = Theme.Fonts.headline
        _ = Theme.Fonts.subhead
        _ = Theme.Fonts.timeMono
        _ = Theme.Fonts.iconThin(.m)
    }
}
```

- [ ] **Step 2: Run it, verify it fails to build**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/FinishTokensTests 2>&1 | grep -E "error:|Test Case" | head -8`
Expected: build errors naming `zone`, `headline`, `subhead`, `timeMono`, `iconThin` as missing.

- [ ] **Step 3: Add the tokens**

In `Theme.Fonts`, after `static let title` (~line 105):

```swift
        /// The island's loudest voice (the song title, the date).
        /// Part of the premium finish (spec 2026-08-10): typography
        /// carries hierarchy now that the pills are gone.
        static let headline = Font.system(size: 18, weight: .semibold)
        /// The quiet line under a headline (the artist, a detail).
        static let subhead = Font.system(size: 15)
```

In the monospaced block, after `static let labelMono` (~line 119):

```swift
        /// Time on the island: elapsed, remaining, temperatures.
        static let timeMono = Font.system(size: 13, weight: .medium, design: .monospaced)
```

After `static func icon(_ scale:...)` (~line 135):

```swift
        /// Thin outline glyphs, the finish's icon voice. Regular, not
        /// semibold: the row reads by brightness, never by bulk.
        static func iconThin(_ scale: IconScale) -> Font {
            .system(size: scale.rawValue, weight: .regular)
        }
```

In `Theme.Space`, after `static let xxl` (~line 155):

```swift
        /// Between the island's zones (music, ambience, switcher,
        /// panel). Air is the only divider; the hairlines are gone
        /// (founder, 2026-08-10).
        static let zone: CGFloat = 26
```

In `Theme.Radius`, change `artwork`:

```swift
        static let artwork: CGFloat = 14
```

In `Theme.Island`, change `radiusExpanded` (keep the existing comment above it):

```swift
        static let radiusExpanded: CGFloat = 40
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/FinishTokensTests 2>&1 | grep -E "Test Case|failure" | tail -4`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Chalant/Views/Theme.swift ChalantTests/FinishTokensTests.swift
git commit -m "feat(finish): the round-1 tokens, pinned"
```

---

### Task 2: Remaining time

**Files:**
- Modify: `Chalant/Views/IslandRows.swift:220-228` (the `clock` helper in `MusicRow`)
- Test: `ChalantTests/FinishTokensTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `MusicRow.clock(_ seconds: Double) -> String` (now internal, was private) and `MusicRow.remainingClock(elapsed: Double, duration: Double) -> String` returning `"-5:02"` style. Task 4 renders these.

- [ ] **Step 1: Write the failing tests**

Append to `FinishTokensTests`:

```swift
    func testRemainingTimeReadsAsMinusMinutesSeconds() {
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 1358, duration: 1660), "-5:02")
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 0, duration: 61), "-1:01")
    }

    func testRemainingTimeNeverGoesPositiveOrBreaksOnLiveStreams() {
        // Elapsed past the duration (a seek race) clamps to -0:00.
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 200, duration: 100), "-0:00")
        // A live stream reports no duration; the clock stays honest.
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 100, duration: 0), "-0:00")
    }

    func testRemainingTimeGrowsHoursOnlyWhenNeeded() {
        XCTAssertEqual(MusicRow.remainingClock(elapsed: 0, duration: 3723), "-1:02:03")
    }
```

- [ ] **Step 2: Run, verify they fail to build**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/FinishTokensTests 2>&1 | grep -E "error:" | head -4`
Expected: `remainingClock` not found.

- [ ] **Step 3: Implement**

In `IslandRows.swift`, replace the `private static func clock` in `MusicRow` (~line 222) with:

```swift
    /// Hours appear only when needed: videos and live streams run
    /// long, songs stay "3:41".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The right side of the progress line counts down (founder's
    /// mockup, 2026-08-10): what is left, not what the whole is.
    static func remainingClock(elapsed: Double, duration: Double) -> String {
        "-" + clock(max(0, duration - elapsed))
    }
```

- [ ] **Step 4: Run, verify green**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/FinishTokensTests 2>&1 | grep -E "Test Case|failure" | tail -6`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Chalant/Views/IslandRows.swift ChalantTests/FinishTokensTests.swift
git commit -m "feat(finish): remaining-time clock for the progress line"
```

---

### Task 3: ScrubBar, the full-width 2pt progress line

**Files:**
- Modify: `Chalant/Views/Components.swift` (append at end)
- Test: `ChalantTests/FinishTokensTests.swift` (extend)

**Interfaces:**
- Consumes: `Theme` tokens from Task 1.
- Produces: `struct ScrubBar: View` with init `ScrubBar(position: Double, duration: Double, tint: Color, onSeek: @escaping (Double) -> Void)`, and `ScrubBar.position(atX: CGFloat, width: CGFloat, duration: Double) -> Double`. Task 4 renders it.

- [ ] **Step 1: Write the failing tests for the drag math**

```swift
    func testScrubMathMapsTheBarToTheTrackAndClampsTheEnds() {
        XCTAssertEqual(ScrubBar.position(atX: 150, width: 300, duration: 200), 100)
        XCTAssertEqual(ScrubBar.position(atX: -20, width: 300, duration: 200), 0)
        XCTAssertEqual(ScrubBar.position(atX: 900, width: 300, duration: 200), 200)
        XCTAssertEqual(ScrubBar.position(atX: 10, width: 0, duration: 200), 0)
    }
```

- [ ] **Step 2: Run, verify build failure** (`ScrubBar` unknown)

- [ ] **Step 3: Implement in `Components.swift`**

```swift
/// The finish's progress line: a full-width 2pt track, no knob, drag
/// anywhere to seek. Replaces the mini Slider in the music row (spec
/// 2026-08-10); a hit target 16pt tall hides behind the 2pt drawing so
/// fingers on trackpads do not have to land on a hairline.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let tint: Color
    let onSeek: (Double) -> Void
    @State private var dragPosition: Double?

    static func position(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(duration, max(0, Double(x / width) * duration))
    }

    var body: some View {
        GeometryReader { geo in
            let shown = dragPosition ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                    .frame(height: 2)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * fraction, height: 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragPosition = Self.position(
                            atX: value.location.x, width: geo.size.width,
                            duration: duration)
                    }
                    .onEnded { _ in
                        if let target = dragPosition { onSeek(target) }
                        dragPosition = nil
                    }
            )
        }
        .frame(height: 16)
        .accessibilityLabel("Playback position")
    }
}
```

- [ ] **Step 4: Run the test file, verify green**

- [ ] **Step 5: Commit**

```bash
git add Chalant/Views/Components.swift ChalantTests/FinishTokensTests.swift
git commit -m "feat(finish): ScrubBar, the knobless full-width progress line"
```

---

### Task 4: MusicRow in the new finish

**Files:**
- Modify: `Chalant/Views/IslandRows.swift:8-292` (`MusicRow`, `NowPlayingBars`)

**Interfaces:**
- Consumes: `Theme.Fonts.headline/subhead/timeMono/iconThin`, `ScrubBar`, `MusicRow.clock`, `MusicRow.remainingClock`.
- Produces: the restyled row; no API changes. `NowPlayingBars` is deleted (verify first that `grep -rn "NowPlayingBars" Chalant/` shows only IslandRows.swift; if another user exists, keep the struct and only remove this row's use).

- [ ] **Step 1: Restyle the body**

Replace `MusicRow.body` and `artworkView` so the row becomes (structure, using the read file as the base):

- Top `HStack(spacing: Theme.Space.xl)`: artwork button (56x56, `Theme.Radius.artwork`, NO radial glow background, NO sheen overlay, NO stroke overlay, NO shadow), then `VStack(alignment: .leading, spacing: 2)` with `Text(playing.track).font(Theme.Fonts.headline).foregroundStyle(Theme.textPrimary)` and `Text(playing.artist).font(Theme.Fonts.subhead).foregroundStyle(Theme.textSecondary)`, then `Spacer()`, then the transport `HStack(spacing: Theme.Space.xxl)`: previous (`backward.fill`, `iconThin(.m)` tint `Theme.textPrimary`), play/pause as a BARE glyph (`pause.fill`/`play.fill`, `Theme.Fonts.icon(.l)`, `Theme.textPrimary`, no white circle, no shadow), next, then the volume pair exactly as today (speaker glyph + mini slider) but slider `.frame(width: 84)` and `.tint(Color.white.opacity(0.5))`.
- Below, `VStack(spacing: Theme.Space.m)`: the `TimelineView(.periodic(from: .now, by: 0.5))` now wraps `ScrubBar(position: scrubPosition ?? livePosition, duration: max(playing.duration, 1), tint: Color.white.opacity(0.9), onSeek: { music.seek(to: $0) })` full width, then an `HStack`: `Text(Self.clock(livePosition)).font(Theme.Fonts.timeMono).foregroundStyle(Theme.textSecondary)`, `Spacer()`, `Text(Self.remainingClock(elapsed: livePosition, duration: playing.duration)).font(Theme.Fonts.timeMono).foregroundStyle(Theme.textSecondary)`.
- The equalizer (`NowPlayingBars`) leaves the row. Shuffle keeps its button but tint `Theme.textTertiary`/`Theme.textPrimary` (no accent).
- Keep: `scrubPosition`/`volumeOverride` state, `music.openMusicApp()` artwork tap, helps, `.animation(Theme.Motion.content, value: playing.isPlaying)`.
- Delete `struct NowPlayingBars` after the grep check above confirms it has no other user.

- [ ] **Step 2: Build and run the full suite**

Run: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant 2>&1 | grep -E "error:|with [0-9]+ failure" | tail -3`
Expected: 0 failures.

- [ ] **Step 3: Screenshot proof**

Build and install the Debug app, hover-expand the island with the cursor tool while music plays, capture, and compare against the mockup's music zone: stacked titles, bare transport, volume beside it, full-width line, times beneath, no glow anywhere.

- [ ] **Step 4: Commit**

```bash
git add Chalant/Views/IslandRows.swift
git commit -m "feat(finish): the music zone, air and typography instead of glow"
```

---

### Task 5: AmbienceRow as text chips

**Files:**
- Modify: `Chalant/Views/IslandRows.swift:297-366` (`AmbienceRow`)

**Interfaces:**
- Consumes: `Theme.Fonts.subhead`, tokens.
- Produces: restyled row; `NoiseButton` becomes unused by this row (leave the component, Settings' welcome tour may still use it; check `grep -rn "NoiseButton" Chalant/` and note the result in the commit body).

- [ ] **Step 1: Restyle**

Replace `AmbienceRow.body` with:

```swift
    var body: some View {
        HStack(spacing: Theme.Space.xxl) {
            ForEach(NoiseEngine.NoiseColor.chipChoices, id: \.self) { color in
                Button {
                    ambience.toggle(color)
                } label: {
                    Text(color.displayName)
                        .font(ambience.active == color
                              ? Theme.Fonts.bodyEmphasis : Theme.Fonts.body)
                        .foregroundStyle(ambience.active == color
                                         ? Theme.textPrimary : Theme.textSecondary)
                }
                .buttonStyle(PressableStyle())
                .help(ambience.active == color
                      ? "Stop \(color.displayName)" : "Play \(color.displayName)")
            }
            if let failure = ambience.failure {
                Text("No sound")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
                    .help("Tried to play, but \(failure).")
            }
            Spacer(minLength: 0)
            // The founder's rule, already true here and staying true:
            // the volume control exists only while a sound is on.
            if ambience.active != nil {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(Theme.Fonts.icon(.xs))
                        .foregroundStyle(Theme.textTertiary)
                    Slider(value: $ambience.volume, in: 0...1)
                        .controlSize(.mini)
                        .tint(Color.white.opacity(0.5))
                        .frame(width: 84)
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: ambience.active)
    }
```

(The "Ambience" label zone and the capsule chip track are deleted; the chips carry the row. The active chip's tap stops it, exactly as `toggle` already behaves.)

- [ ] **Step 2: Full suite green** (same command as Task 4 Step 2)

- [ ] **Step 3: Screenshot proof** (chips text-only, active white; toggle a sound off and confirm the slider leaves)

- [ ] **Step 4: Commit**

```bash
git add Chalant/Views/IslandRows.swift
git commit -m "feat(finish): ambience chips are words; the slider lives only while sound plays"
```

---

### Task 6: The switcher, icons only, white means active

**Files:**
- Modify: `Chalant/Views/TabRow.swift:17-192`

**Interfaces:**
- Consumes: `Theme.Fonts.iconThin`.
- Produces: restyled `Switcher`/`SwitcherItem`; `Switcher.symbol`/`label` keep their signatures (tests reference them).

- [ ] **Step 1: Restyle**

- In `Switcher.body`: remove the inner track's `.padding(.horizontal, Theme.Space.xs)` and `.background(Capsule().fill(Theme.surface))`; raise the item spacing to `Theme.Space.xxl`.
- In `SwitcherItem.body`: the label becomes icon-only (delete the `if on || hovered { Text(...) }` block and the surrounding HStack if empty); glyph via `GlyphImage(symbol: Switcher.symbol(tab), scale: .m)` with `.font(Theme.Fonts.iconThin(.l))` if GlyphImage accepts a font, otherwise set tint/weight the way GlyphImage's API allows (read Components.swift first); foreground becomes `on ? Theme.textPrimary : hovered ? Theme.textSecondary : Theme.textGhost`; DELETE the accent capsule `.background(...)` and `.overlay(Capsule().strokeBorder(...))`; keep `.padding(.vertical, 7)`, `.contentShape(Rectangle())`, `.help(Switcher.label(tab))` (the name still lives in the tooltip), the slide-direction logic, and `PressableStyle`.
- Keep the focus button and the gear exactly as they are, but the gear's tint moves to `Theme.textGhost`.

- [ ] **Step 2: Full suite green**

- [ ] **Step 3: Screenshot proof** (icon row with no track, active icon white, gear far right)

- [ ] **Step 4: Commit**

```bash
git add Chalant/Views/TabRow.swift
git commit -m "feat(finish): the switcher speaks in brightness, not pills"
```

---

### Task 7: Today wears the date as its headline

**Files:**
- Modify: `Chalant/Views/ExpandedView.swift:686-800` (`TodayView` header and clearDay; read the whole struct first, it ends near line 860)

**Interfaces:**
- Consumes: `Theme.Fonts.headline/subhead`.
- Produces: restyled header. The weather slot arrives in Round 3; the header's right side stays empty this round.

- [ ] **Step 1: Restyle the header**

Replace the `header` computed property: delete `SectionHeader(title: "Today")` and the hairline `Rectangle()`; the row becomes `Text(Self.dateFormatter.string(from: Date())).font(Theme.Fonts.headline).foregroundStyle(Theme.textPrimary)` then `Spacer()`. Restyle `clearDay` so its primary line uses `Theme.Fonts.subhead` with `Theme.textSecondary` and its detail line `Theme.Fonts.subhead` with `Theme.textTertiary`. Do not touch `clearDayDetail` (tests pin its strings).

- [ ] **Step 2: Full suite green** (`testTheEmptyDayClaimsOnlyWhatItActuallyLookedAt` must still pass untouched)

- [ ] **Step 3: Screenshot proof** (date as headline, no TODAY eyebrow, no hairline)

- [ ] **Step 4: Commit**

```bash
git add Chalant/Views/ExpandedView.swift
git commit -m "feat(finish): the date is Today's headline"
```

---

### Task 8: Air between the zones

**Files:**
- Modify: `Chalant/Views/ExpandedView.swift` (the expanded stack that lays out MusicRow / AmbienceRow / Switcher / panel; find it via `grep -n "MusicRow\|AmbienceRow\|Switcher(" Chalant/Views/ExpandedView.swift`)
- Modify: `Chalant/Views/IslandLayout.swift` only if the glance rows share the spacing (read before touching)

**Interfaces:**
- Consumes: `Theme.Space.zone`.
- Produces: the finished round-1 island.

- [ ] **Step 1: Apply zone spacing**

Set the vertical spacing between the island's zones to `Theme.Space.zone` (today it uses a smaller `Theme.Space` step; find the containing `VStack(spacing:)` and change it). Remove any `Divider()` or hairline `Rectangle` between zones if one exists (grep `Divider\(|hairline` within ExpandedView's island body; the settings window keeps its own).

- [ ] **Step 2: Full suite green**

- [ ] **Step 3: The round proof**

- Rebuild Release, install over `~/Downloads/installations/Chalant.app`, relaunch.
- Hover-expand, capture the whole island with music playing and Brown on; capture again with ambience off (slider gone).
- Place the captures beside the mockup page and check every rule: air only, no pills, thin icons, mono times with remaining, media volume present, radius 40.
- `ps -o %cpu` idle check: within 0.5 points of the pre-round baseline (~0.6%).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(finish): round 1 lands, the island breathes"
```

---

## Self-review notes

- Spec coverage for Round 1: air/no dividers (T8), no pills (T5, T6), type tokens (T1), thin icons (T1, T4, T6), music zone incl. media volume and remaining time (T2, T3, T4), ambience text chips + conditional slider (T5), tab row icons only (T6), Today headline (T7), radius 40 (T1, applied by the shell via `Theme.Island.radiusExpanded`). Weather, liquid motion and Settings re-dress are Rounds 2-4 by design.
- Names cross-checked: `remainingClock` (T2) is what T4 renders; `ScrubBar.position(atX:width:duration:)` (T3) is what its own gesture and test call; token names in T1 match every later consumer.
- Deletions are guarded: `NowPlayingBars` and `NoiseButton` each get a grep-before-delete step rather than a blind removal.
