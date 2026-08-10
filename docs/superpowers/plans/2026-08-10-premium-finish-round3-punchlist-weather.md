# Premium Finish, Round 3: The Punch List and the Weather: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the founder's round-2 feel-check findings (the immortal crash banner, seek snap-back, bulky volume sliders, the doubled time readout, the unwanted empty-state lines, the too-dead music zone) and land the weather line on Today.

**Architecture:** Punch-list items are surgical fixes in existing files. Weather is one new controller (`Chalant/Features/WeatherController.swift`, keyless Open-Meteo + CoreLocation) consumed by `TodayView`'s header and one new Settings toggle. All logic lands as testable statics first.

**Tech Stack:** SwiftUI, CoreLocation, URLSession, XCTest, xcodegen.

## Global Constraints

- The founder's design laws hold: no pills, air over lines, one speaker icon, tokens only, no em dashes anywhere, flat black shell (the new music glow is a bounded exception the founder explicitly asked for: "a little bit of color blob... without making it too much").
- Motion respects `Theme.Feel` and Reduce Motion; no new TimelineViews; no `.frame` animation in high-rate contexts.
- Sessions/chat and `FeatureFlags` untouched. All tests green at every commit (593 at round start; deletions in Tasks 4-5 lower the count deliberately, each removal named in its brief).
- Privacy copy changes with the weather feature, honestly (one sentence, in the Privacy card).
- Branch `premium-finish`. Commit per task. No merge, bump, or release.

---

### Task 1: The crash banner says it once

**Files:**
- Modify: `Chalant/Features/CrashWatch.swift` (add `markSeen`)
- Modify: `Chalant/NotchViewModel.swift:299-310` (`reportLastCrashIfAny`)
- Test: `ChalantTests/MotionPourTests.swift` (extend; rename-free, it is the round's active test file)

**Interfaces:**
- Produces: `CrashWatch.markSeen(_ date: Date)` static (writes the seen key) and instance `markSeenNow()` (marks the current `unreported` date seen WITHOUT clearing `unreported`, so the session's "crash report" voice verbs keep working).

**Why:** the card's X only clears the activity row; `acknowledge()` is reachable only through the voice verbs (`ActionEngine.swift:161-171`), so `chalant.crashSeenAt` never advances and every launch re-reports the same Aug 6 crash. The class doc already promises "says so once."

- [ ] **Step 1: Failing test**

```swift
    func testACrashIsMarkedSeenWithoutForgettingItThisSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "chalant.crashSeenAt")
        let date = Date(timeIntervalSince1970: 1_754_500_000)
        CrashWatch.markSeen(date)
        XCTAssertEqual(
            defaults.object(forKey: "chalant.crashSeenAt") as? Date, date)
        defaults.removeObject(forKey: "chalant.crashSeenAt")
    }
```

- [ ] **Step 2: Verify it fails to build** (`markSeen` missing)
- [ ] **Step 3: Implement**

In CrashWatch, below `acknowledge()`:

```swift
    /// The report has been put in front of the user (the card pushed,
    /// the glance flashed): record that, so the next launch stays
    /// quiet, but keep `unreported` for this session so "crash report"
    /// can still read it out. The card's X never called acknowledge(),
    /// which is how one August crash greeted every launch for days.
    static func markSeen(_ date: Date) {
        UserDefaults.standard.set(date, forKey: seenKey)
    }

    func markSeenNow() {
        if let date = unreported?.date { Self.markSeen(date) }
    }
```

Change `seenKey` from `private static let` to `static let` if the test needs it by name; otherwise keep private and test through `markSeen`. In `reportLastCrashIfAny` (NotchViewModel), after the `flashGlance(...)` line, add `crashWatch.markSeenNow()` with a one-line comment: shown is seen; the card and verbs still work this session.

- [ ] **Step 4: Targeted test green, full suite green**
- [ ] **Step 5: Commit** (`fix(finish): a crash is announced once, not every launch forever`)

---

### Task 2: Seek without the snap-back

**Files:**
- Modify: `Chalant/Views/IslandRows.swift` (`MusicRow`)
- Test: `ChalantTests/MotionPourTests.swift` (extend)

**Interfaces:**
- Produces: `MusicRow.displayPosition(live: Double, pending: (target: Double, at: Date)?, now: Date) -> Double` static.

**Why:** ScrubBar clears its drag state on release; the row then shows `livePosition`, which is stale until the player's ~1s poll catches up, so the bar visibly snaps back then jumps forward. The old Slider held its override until the seek applied; the pour needs the same manners.

- [ ] **Step 1: Failing tests**

```swift
    func testAFreshSeekHoldsTheBarAtItsTarget() {
        let now = Date()
        XCTAssertEqual(
            MusicRow.displayPosition(live: 84, pending: (target: 140, at: now), now: now),
            140)
    }

    func testTheSeekReleasesOnceThePlayerCatchesUp() {
        let now = Date()
        XCTAssertEqual(
            MusicRow.displayPosition(
                live: 139.2, pending: (target: 140, at: now), now: now),
            139.2, "within two seconds of the target, the live clock rules again")
    }

    func testTheSeekNeverHoldsLongerThanThreeSeconds() {
        let then = Date(timeIntervalSinceNow: -3.5)
        XCTAssertEqual(
            MusicRow.displayPosition(live: 84, pending: (target: 140, at: then), now: Date()),
            84, "a player that never catches up gets the truth back after 3s")
    }
```

- [ ] **Step 2: Verify build failure**
- [ ] **Step 3: Implement**

```swift
    /// What the bar and clock show: an optimistic seek target until the
    /// player's slow poll catches up (within 2s of the target), capped
    /// at 3s so a player that ignored the seek cannot pin a lie.
    static func displayPosition(
        live: Double, pending: (target: Double, at: Date)?, now: Date
    ) -> Double {
        guard let pending else { return live }
        if now.timeIntervalSince(pending.at) > 3 { return live }
        if abs(live - pending.target) <= 2 { return live }
        return pending.target
    }
```

In `MusicRow`: add `@State private var pendingSeek: (target: Double, at: Date)?`. In the `TimelineView` closure: `let shown = Self.displayPosition(live: music.position(at: context.date), pending: pendingSeek, now: context.date)`; if `shown == live` for a non-nil pending whose hold expired or converged, clear `pendingSeek` (do the clear inside the ScrubBar's `onSeek`-adjacent flow or an `.onChange(of: shown)`; keep it simple: clearing lazily is fine since `displayPosition` already ignores stale pendings). `ScrubBar`'s `onSeek` closure becomes: `pendingSeek = (target: $0, at: Date()); music.seek(to: $0)`. The elapsed clock and the bar both read `shown`.

- [ ] **Step 4: Tests green, full suite green**
- [ ] **Step 5: Commit** (`fix(finish): a seek holds its ground until the player arrives`)

---

### Task 3: Volume sliders in the island's own voice

**Files:**
- Modify: `Chalant/Views/Components.swift` (add `ThinSlider` beside `ScrubBar`)
- Modify: `Chalant/Views/IslandRows.swift` (both volume call sites)
- Test: `ChalantTests/MotionPourTests.swift` (extend)

**Interfaces:**
- Produces: `struct ThinSlider: View` with init `(value: Binding<Double>, in range: ClosedRange<Double>, onCommit: ((Double) -> Void)?)` and `ThinSlider.value(atX: CGFloat, width: CGFloat, in range: ClosedRange<Double>) -> Double`.

**Why:** the AppKit mini `Slider` wears a fat knob and thick track that shout next to the 2pt scrub line (founder: "a bit too bulky").

- [ ] **Step 1: Failing test**

```swift
    func testThinSliderMathMapsAndClampsAcrossItsRange() {
        XCTAssertEqual(ThinSlider.value(atX: 42, width: 84, in: 0...100), 50)
        XCTAssertEqual(ThinSlider.value(atX: -5, width: 84, in: 0...100), 0)
        XCTAssertEqual(ThinSlider.value(atX: 200, width: 84, in: 0...1), 1)
        XCTAssertEqual(ThinSlider.value(atX: 10, width: 0, in: 0...1), 0)
    }
```

- [ ] **Step 2: Verify build failure**
- [ ] **Step 3: Implement**

```swift
/// The island's own slider: a 2pt track, a 6pt dot that appears on
/// hover or drag, drag anywhere on a 16pt target. The AppKit mini
/// slider's knob read as furniture next to the scrub line; this is the
/// same voice at volume size. Adjustable to assistive tech like a
/// slider, because it is one.
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onCommit: ((Double) -> Void)?
    @State private var dragging = false
    @State private var hovered = false

    static func value(atX x: CGFloat, width: CGFloat, in range: ClosedRange<Double>) -> Double {
        guard width > 0 else { return range.lowerBound }
        let unit = min(1, max(0, Double(x / width)))
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let unit = span > 0 ? (value - range.lowerBound) / span : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 2)
                Capsule().fill(Color.white.opacity(0.6))
                    .frame(width: geo.size.width * unit, height: 2)
                if hovered || dragging {
                    Circle().fill(Color.white.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .offset(x: geo.size.width * unit - 3)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Self.value(atX: drag.location.x, width: geo.size.width, in: range)
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit?(value)
                    }
            )
        }
        .frame(width: 84, height: 16)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered || dragging)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(Int((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001) * 100)) percent"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            let delta = direction == .increment ? step : -step
            value = min(range.upperBound, max(range.lowerBound, value + delta))
            onCommit?(value)
        }
    }
}
```

Call sites in `IslandRows.swift`:
- Media volume: replace the mini `Slider` (keep the speaker glyph) with `ThinSlider(value:in: 0...100, onCommit:)` wired to the existing preview/commit semantics: the binding's set calls `music.previewVolume($0)` via a computed Binding exactly as today, `onCommit` calls `music.commitVolume($0)` and clears `volumeOverride`.
- Ambience volume: `ThinSlider(value: $ambience.volume, in: 0...1, onCommit: nil)` (its binding already applies live), keeping the speaker glyph and the `ambience.active != nil` conditional and transition.

- [ ] **Step 4: Tests green, full suite green**
- [ ] **Step 5: Commit** (`feat(finish): volume speaks in the island's own thin voice`)

---

### Task 4: One clock, the elapsed one

**Files:**
- Modify: `Chalant/Views/IslandRows.swift` (times row)
- Modify: `ChalantTests/FinishTokensTests.swift` (delete the three remaining-time tests)

**Why:** founder: two readouts is one too many; the minus clock goes.

- [ ] **Step 1:** In the times `HStack` under the ScrubBar, delete the trailing `Text(Self.remainingClock(...))`; the row keeps `Text(Self.clock(shown))` left and the `Spacer()`. Delete `static func remainingClock` from `MusicRow` and the three tests that pinned it (`testRemainingTimeReadsAsMinusMinutesSeconds`, `testRemainingTimeNeverGoesPositiveOrBreaksOnLiveStreams`, `testRemainingTimeGrowsHoursOnlyWhenNeeded`). `clock` stays (the elapsed readout and ScrubBar's accessibility value use it).
- [ ] **Step 2:** Full suite green (count drops by 3; that is expected and correct).
- [ ] **Step 3: Commit** (`feat(finish): one clock; the countdown leaves`)

---

### Task 5: The empty day is just the date

**Files:**
- Modify: `Chalant/Views/ExpandedView.swift` (`TodayView`)
- Modify: `ChalantTests/SessionStoreTests.swift` (delete `testTheEmptyDayClaimsOnlyWhatItActuallyLookedAt`)

**Why:** founder: "Clear water. Nothing due. You don't need those."

- [ ] **Step 1:** In `TodayView`, delete the `clearDay` view and its use (the `if !hasEvents, !hasReminders, canSeeAnything { clearDay }` block) and delete `clearDayDetail` and any properties only it used (`canSeeAnything` stays if the denial rows use it; check). The empty day shows the date header alone (weather joins it in Task 7). Delete the pinned-strings test in SessionStoreTests.
- [ ] **Step 2:** Full suite green (count drops by 1).
- [ ] **Step 3: Commit** (`feat(finish): an empty day is just the date`)

---

### Task 6: The living blob

**Files:**
- Modify: `Chalant/Views/IslandRows.swift` (`MusicRow`)

**Why:** founder: "a little bit of color blob in the background to make it feel alive without making it too much, by matching the color of the media."

- [ ] **Step 1:** Reintroduce `@Environment(\.chalantAccent) private var accent` in `MusicRow`. Behind the whole music zone (a `.background` on the row's outer VStack), add, only while `playing.isPlaying`:

```swift
    // The one drop of color the founder asked back: the album's own
    // light, pooled soft behind the zone, breathing slowly while the
    // music plays. Feel-gated: Still means a quiet, motionless pool.
    RadialGradient(
        colors: [accent.opacity(0.14), .clear],
        center: .init(x: 0.22, y: 0.35),
        startRadius: 8, endRadius: 220
    )
    .blur(radius: 18)
    .opacity(breathing ? 1.0 : 0.7)
    .allowsHitTesting(false)
```

with `@State private var breathing = false` driven by `.onAppear`/`.onChange(of: playing.isPlaying)`: when playing and `Theme.Feel.current.ambient`, run `withAnimation(.easeInOut(duration: 3.2 * Theme.Motion.ambientSlow).repeatForever(autoreverses: true)) { breathing = true }`; otherwise set `breathing = false` without animation. Wrap the gradient in `if playing.isPlaying { ... }` with `.transition(.opacity)` so it fades with `Theme.Motion.content` when playback stops. No TimelineView. The accent is already saturation-clamped by AccentExtractor, so the blob cannot go loud.

- [ ] **Step 2:** Full suite green. Idle check note for the round proof: the repeatForever animation must stop when playback stops or the island unmounts (verify `breathing = false` path).
- [ ] **Step 3: Commit** (`feat(finish): the album's light pools behind the music, alive but quiet`)

---

### Task 7: Weather on Today

**Files:**
- Create: `Chalant/Features/WeatherController.swift`
- Modify: `Chalant/Views/ExpandedView.swift` (`TodayView` header), `Chalant/NotchViewModel.swift` (own the controller), `Chalant/Views/DashboardSections.swift` (What shows toggle + privacy sentence), `project.yml` (`NSLocationUsageDescription`), then `xcodegen`
- Test: `ChalantTests/WeatherTests.swift` (create)

**Interfaces:**
- Produces: `WeatherController: ObservableObject` with `@Published private(set) var reading: Reading?`; `struct Reading: Codable, Equatable { var temperature: Double; var code: Int; var at: Date }`; statics `WeatherController.skyWord(code: Int) -> String`, `decode(_ data: Data) -> (temperature: Double, code: Int)?`, `usableReading(_ reading: Reading?, now: Date) -> Reading?` (nil once 3h stale), `line(_ reading: Reading, celsius: Bool) -> String` (e.g. `"106° Clear"`), `wantsCelsius(locale: Locale) -> Bool`.

- [ ] **Step 1: Failing tests** (TDD on all statics)

```swift
import XCTest

@testable import Chalant

@MainActor
final class WeatherTests: XCTestCase {
    func testTheSkyWordsCoverTheWMOTable() {
        XCTAssertEqual(WeatherController.skyWord(code: 0), "Clear")
        XCTAssertEqual(WeatherController.skyWord(code: 2), "Partly cloudy")
        XCTAssertEqual(WeatherController.skyWord(code: 3), "Cloudy")
        XCTAssertEqual(WeatherController.skyWord(code: 45), "Fog")
        XCTAssertEqual(WeatherController.skyWord(code: 61), "Rain")
        XCTAssertEqual(WeatherController.skyWord(code: 71), "Snow")
        XCTAssertEqual(WeatherController.skyWord(code: 81), "Showers")
        XCTAssertEqual(WeatherController.skyWord(code: 95), "Storm")
        XCTAssertEqual(WeatherController.skyWord(code: 999), "Sky")
    }

    func testDecodeReadsOpenMeteoCurrent() {
        let json = #"{"current":{"temperature_2m":41.3,"weather_code":2}}"#
        let decoded = WeatherController.decode(Data(json.utf8))
        XCTAssertEqual(decoded?.temperature, 41.3)
        XCTAssertEqual(decoded?.code, 2)
        XCTAssertNil(WeatherController.decode(Data("{}".utf8)))
    }

    func testAReadingGoesStaleAfterThreeHours() {
        let fresh = WeatherController.Reading(
            temperature: 30, code: 0, at: Date(timeIntervalSinceNow: -60))
        let stale = WeatherController.Reading(
            temperature: 30, code: 0, at: Date(timeIntervalSinceNow: -3.5 * 3600))
        XCTAssertNotNil(WeatherController.usableReading(fresh, now: Date()))
        XCTAssertNil(WeatherController.usableReading(stale, now: Date()))
        XCTAssertNil(WeatherController.usableReading(nil, now: Date()))
    }

    func testTheLineReadsLikeTheMockup() {
        let reading = WeatherController.Reading(temperature: 41.3, code: 0, at: Date())
        XCTAssertEqual(WeatherController.line(reading, celsius: false), "106° Clear")
        XCTAssertEqual(WeatherController.line(reading, celsius: true), "41° Clear")
    }

    func testUnitFollowsTheLocale() {
        XCTAssertFalse(WeatherController.wantsCelsius(locale: Locale(identifier: "en_US")))
        XCTAssertTrue(WeatherController.wantsCelsius(locale: Locale(identifier: "en_GB")))
    }
}
```

Note: `decode` always receives celsius from the API (request omits `temperature_unit`, Open-Meteo defaults to celsius); `line(_:celsius:)` converts to F itself (`t * 9 / 5 + 32`), rounding to whole degrees. That keeps one canonical stored unit and makes the F/C test honest (41.3C = 106.34F → "106°").

- [ ] **Step 2: xcodegen, verify build failure, then implement `WeatherController`**

Shape: `@MainActor final class WeatherController: NSObject, ObservableObject, CLLocationManagerDelegate`. On `start()`: read cache from UserDefaults (`chalant.weather.reading`, JSON-encoded `Reading`), request location authorization if undetermined, then `requestLocation()` on grant; on `didUpdateLocations` fetch `https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code` (2 decimal places on coordinates, approximate is the point), decode via the tested static, publish + cache. Re-fetch on a 30-minute `Timer` (tolerance 60s) and on `NSWorkspace.didWakeNotification`. Denied or failed: publish stays whatever the cache allows; `usableReading` filters staleness at read time. All statics exactly as the tests pin them. WMO table: 0 Clear; 1,2 Partly cloudy; 3 Cloudy; 45,48 Fog; 51...67 Rain; 71...77 Snow; 80...82 Showers; 85,86 Snow; 95...99 Storm; default Sky.

- [ ] **Step 3: Wire the UI**

- `NotchViewModel`: `let weather = WeatherController()`; call `weather.start()` in the startup path near `events.startGlanceTicker()`, gated on the defaults key `"showWeather"` (unset means on) so the toggle governs the fetch, not just the line.
- `TodayView` header right side (the empty `Spacer()` end): when `let reading = WeatherController.usableReading(model-provided reading, now: Date())` and the `showWeather` toggle is on, show `Image(systemName: "sun.max")` in `Theme.Fonts.iconThin(.m)` + `Text(WeatherController.line(reading, celsius: WeatherController.wantsCelsius(locale: .current)))` in `Theme.Fonts.subhead`, both `Theme.textSecondary`. TodayView gains an `@ObservedObject var weather: WeatherController` handed from ExpandedView the way `events` already is.
- `DashboardSections.swift` What shows BLOCKS card: `SettingToggle(label: "Weather", isOn: $showWeather)` (`@AppStorage("showWeather") = true`) after the Reminders row, with a `SettingNote` naming Open-Meteo; Privacy card first note gains the honest sentence: `"Weather asks Open-Meteo for the sky above your approximate area. Nothing else leaves this Mac."`
- `project.yml` Info properties: `NSLocationUsageDescription: Chalant reads your approximate location to show the weather beside your day.` Then `xcodegen`.

- [ ] **Step 4: Full suite green** (targeted WeatherTests first, then all)
- [ ] **Step 5: Commit** (`feat(finish): the sky joins the date`)

---

### Task 8 (controller): The round proof

- Rebuild Release, reinstall, relaunch. macOS will ask about location: the founder clicks Allow (or the line simply stays absent; both are correct).
- Verify by eye: banner gone on second relaunch (the definitive test of Task 1), seek holds, thin sliders, one clock, no empty-state lines, the blob breathing while music plays and gone when paused, weather beside the date.
- Idle CPU with music paused ~0.6-0.9%; with music playing, no worse than the pre-existing ~16%.

## Self-review notes

- Every founder item maps: banner (T1), seek (T2), bulky sliders (T3), doubled clock (T4), Clear water/Nothing due (T5), color blob (T6), weather (T7).
- Deletions are explicit: `remainingClock` + 3 tests (T4), `clearDay`/`clearDayDetail` + 1 test (T5). Net test count: 593 - 4 + 1 (T1) + 3 (T2) + 1 (T3) + 5 (T7) = 599.
- `ThinSlider` keeps the media preview/commit semantics by reusing the existing Binding, so drag-preview volume behavior does not regress.
- The blob is the one sanctioned deviation from "flat black"; it is playback feedback (like the deleted equalizer was), founder-requested, accent-clamped, and Feel-gated.
