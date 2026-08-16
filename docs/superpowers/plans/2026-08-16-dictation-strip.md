# Dictation Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When left Option is held to dictate, Chalant's island grows into a low black strip whose rim glow, base pool and one centre dot breathe with the voice, on the display showing the app being dictated into; it closes on release. The floating `ListeningPanel` is deleted.

**Architecture:** `NotchViewModel` gains a `.dictating` sibling to `.listening` (never a reuse: reuse would start `VoiceController`'s recognizer, and two engines listening at once is the doubled-text failure). `DictationController` talks to it through a small `@MainActor` protocol, `DictationSurface`, declared in `Dictation/` and implemented in `Chalant/`, so the package still knows nothing about the app's view model. `NotchRootView` renders a `dictatingContent` for the new state. Level drives three visual formulas through one `0...1` number.

**Tech Stack:** Swift 5.9 app target (`Chalant/`), Swift 6 package (`Dictation/`), SwiftUI, AppKit. XCTest for the app target (`ChalantTests/`), swift-testing for Core. `xcodegen` regenerates the project after any new file.

**Spec:** `docs/superpowers/specs/2026-08-16-dictation-strip-design.md`

## Global Constraints

- The strip opens on **the display showing the app being dictated into**; fallback order: pointer's display, `NSScreen.main`, any screen. A display whose island style is `.off` is skipped to the next fallback.
- **No words in the strip.** Level only.
- One symbol: one accent dot. No bars, no waveform.
- Level formulas, exactly: rim glow radius `2 + level*22`, opacity `0.10 + level*0.55`; base pool opacity `level*0.22`; dot diameter `6 + level*6`, glow radius `4 + level*14`.
- Open/close on `Theme.Motion.island`. Level changes animate `.easeOut(duration: 0.1)`.
- `.dictating` must NOT call `voice.begin()` or anything on `VoiceController`.
- Every text style comes from `Theme.Fonts` and every colour from `Theme`; a raw number in a view is a bug (Theme's own rule).
- After adding any file: `xcodegen generate` before building.
- **Never commit to `main`.** All work on `feat/dictation-strip`. Commits end with the two trailer lines used throughout this repo (see any recent commit).
- No em dashes anywhere, in code, comments or copy.

---

## File Structure

| File | Responsibility |
|---|---|
| `Dictation/ChalantDictationApp/UI/DictationSurface.swift` (create) | The protocol dictation talks to. What it needs from whatever shows it. Ungated. |
| `Dictation/ChalantDictationApp/UI/ListeningPanel.swift` (delete) | Replaced. |
| `Dictation/ChalantDictationApp/DictationController.swift` (modify) | Owns a `DictationSurface` instead of a `ListeningPanel`; resolves app name and display at key-down. |
| `Chalant/Features/DictationDisplay.swift` (create) | Pure display-resolution rule + the impure lookup that feeds it. |
| `Chalant/Features/DictationStripLevel.swift` (create) | The three level formulas, pure, tested. |
| `Chalant/NotchViewModel.swift` (modify) | `.dictating` state, `dictationLevel`, `dictationInfo`, `beginDictating/updateDictating/endDictating`. |
| `Chalant/Views/NotchRootView.swift` (modify) | `islandSize` for `.dictating`, `dictatingContent`, the glow overlay. |
| `Chalant/Features/Dictation.swift` (modify) | Hands `DictationController` a surface backed by the view model. |
| `Chalant/ChalantApp.swift` (modify) | Sets `Dictation.shared.surface` once the notch controller exists. |
| `ChalantTests/DictationStripTests.swift` (create) | Display rule, level formulas, `.dictating` per-face state. |

---

### Task 1: The three level formulas, pure and pinned

**Files:**
- Create: `Chalant/Features/DictationStripLevel.swift`
- Test: `ChalantTests/DictationStripTests.swift`

**Interfaces:**
- Produces: `enum DictationStripLevel` with `static func rim(_ level: CGFloat) -> (radius: CGFloat, opacity: Double)`, `static func pool(_ level: CGFloat) -> Double`, `static func dot(_ level: CGFloat) -> (diameter: CGFloat, glow: CGFloat)`, and `static func clamp(_ level: CGFloat) -> CGFloat`.

- [ ] **Step 1: Write the failing test**

```swift
// ChalantTests/DictationStripTests.swift
import XCTest
@testable import Chalant

final class DictationStripTests: XCTestCase {

    // MARK: - Level formulas (spec, "Motion")

    func testRimAtSilenceIsTheRestingRim() {
        let rim = DictationStripLevel.rim(0)
        XCTAssertEqual(rim.radius, 2, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.10, accuracy: 0.001)
    }

    func testRimAtFullReachesTheMaxima() {
        let rim = DictationStripLevel.rim(1)
        XCTAssertEqual(rim.radius, 24, accuracy: 0.001)
        XCTAssertEqual(rim.opacity, 0.65, accuracy: 0.001)
    }

    func testPoolIsInvisibleAtSilenceAndCappedAtFull() {
        XCTAssertEqual(DictationStripLevel.pool(0), 0, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.pool(1), 0.22, accuracy: 0.001)
    }

    func testDotGrowsFromSixToTwelve() {
        XCTAssertEqual(DictationStripLevel.dot(0).diameter, 6, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).diameter, 12, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(0).glow, 4, accuracy: 0.001)
        XCTAssertEqual(DictationStripLevel.dot(1).glow, 18, accuracy: 0.001)
    }

    /// The audio engine reports raw peak, which can exceed 1 on a hot mic
    /// and be negative on a broken one. The formulas must never be fed
    /// either.
    func testLevelIsClampedBeforeUse() {
        XCTAssertEqual(DictationStripLevel.clamp(-0.5), 0)
        XCTAssertEqual(DictationStripLevel.clamp(3.0), 1)
        XCTAssertEqual(DictationStripLevel.clamp(0.4), 0.4, accuracy: 0.0001)
        XCTAssertEqual(DictationStripLevel.rim(3.0).radius, 24, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "error:|Test Suite|passed|failed" | head`
Expected: compile error, `cannot find 'DictationStripLevel' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
// Chalant/Features/DictationStripLevel.swift
import CoreGraphics

/// The three things the voice drives on the dictation strip, from one number.
///
/// **The strip is the meter.** There are no bars: the island's rim glow, a
/// pool of light at its base, and one centre dot all swell with the level.
/// Pinned here as formulas rather than scattered in the view, so nobody
/// retunes one and not the others, and so a test can hold the maxima the
/// founder approved on the mockup (2026-08-16).
enum DictationStripLevel {

    /// Raw peak from the audio engine can exceed 1 on a hot mic and be
    /// negative on a broken one. Every formula clamps first.
    static func clamp(_ level: CGFloat) -> CGFloat {
        min(1, max(0, level))
    }

    /// The rim glow, drawn as a shadow in the accent around the island shape.
    static func rim(_ level: CGFloat) -> (radius: CGFloat, opacity: Double) {
        let l = clamp(level)
        return (radius: 2 + l * 22, opacity: 0.10 + Double(l) * 0.55)
    }

    /// The pool of light gathering at the base of the strip.
    static func pool(_ level: CGFloat) -> Double {
        Double(clamp(level)) * 0.22
    }

    /// The one dot at the centre. Diameter and its own glow radius.
    static func dot(_ level: CGFloat) -> (diameter: CGFloat, glow: CGFloat) {
        let l = clamp(level)
        return (diameter: 6 + l * 6, glow: 4 + l * 14)
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests**

Run: `xcodegen generate >/dev/null && xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "error:|Test Suite 'DictationStripTests'|passed|failed" | head`
Expected: `Test Suite 'DictationStripTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Chalant/Features/DictationStripLevel.swift ChalantTests/DictationStripTests.swift Chalant.xcodeproj
git commit -m "feat(strip): the three level formulas, pinned

The strip is the meter: rim glow, base pool and one dot all swell from one
0...1 number. Pinned as formulas with the maxima the founder approved on the
mockup, so nobody retunes one and not the others. Clamped, because raw peak
exceeds 1 on a hot mic.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

---

### Task 2: Which display, as a pure rule

**Files:**
- Create: `Chalant/Features/DictationDisplay.swift`
- Modify: `ChalantTests/DictationStripTests.swift` (append)

**Interfaces:**
- Produces: `enum DictationDisplay` with `static func resolve(target: CGDirectDisplayID?, pointerOn: CGDirectDisplayID?, main: CGDirectDisplayID?, any: CGDirectDisplayID?, isOff: (CGDirectDisplayID) -> Bool) -> CGDirectDisplayID?` and `static func displayShowing(pid: pid_t) -> CGDirectDisplayID?`.

- [ ] **Step 1: Write the failing test**

Append inside `DictationStripTests`:

```swift
    // MARK: - Which display (spec, "Which display")

    private let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2, c: CGDirectDisplayID = 3

    func testTheTargetAppsDisplayWinsOverEverything() {
        let picked = DictationDisplay.resolve(
            target: a, pointerOn: b, main: c, any: c, isOff: { _ in false })
        XCTAssertEqual(picked, a)
    }

    func testFallsBackToThePointerThenMainThenAny() {
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: b, main: c, any: a, isOff: { _ in false }), b)
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: nil, main: c, any: a, isOff: { _ in false }), c)
        XCTAssertEqual(DictationDisplay.resolve(target: nil, pointerOn: nil, main: nil, any: a, isOff: { _ in false }), a)
        XCTAssertNil(DictationDisplay.resolve(target: nil, pointerOn: nil, main: nil, any: nil, isOff: { _ in false }))
    }

    /// A screen the user has set to "Off" gets no island, so the strip must
    /// go to the next fallback rather than nowhere.
    func testSkipsADisplayWhoseIslandIsOff() {
        let picked = DictationDisplay.resolve(
            target: a, pointerOn: b, main: c, any: c, isOff: { $0 == a })
        XCTAssertEqual(picked, b)
    }

    func testEveryDisplayOffMeansNowhere() {
        XCTAssertNil(DictationDisplay.resolve(target: a, pointerOn: b, main: c, any: c, isOff: { _ in true }))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "error:|passed|failed" | head`
Expected: compile error, `cannot find 'DictationDisplay' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
// Chalant/Features/DictationDisplay.swift
import AppKit
import CoreGraphics

/// Which screen the dictation strip opens on.
///
/// **Not `NSScreen.main`, and not the pointer's display.** The old floating
/// panel used `.main`, which on the founder's desk is the external monitor
/// while their eyes are on the app they are dictating into, and that is the
/// whole reason they reported dictation as invisible. Voice commands are
/// addressed to the island, so the pointer rule (`NotchViewModel.defaultOwner`)
/// is right for them. Dictation is addressed to another app: the strip belongs
/// on the screen showing that app.
enum DictationDisplay {

    /// The rule, pure so it can be tested. Fallback order after the target's
    /// own display: pointer, main, any. A display whose island is switched
    /// off is skipped to the next.
    static func resolve(
        target: CGDirectDisplayID?,
        pointerOn: CGDirectDisplayID?,
        main: CGDirectDisplayID?,
        any: CGDirectDisplayID?,
        isOff: (CGDirectDisplayID) -> Bool
    ) -> CGDirectDisplayID? {
        for candidate in [target, pointerOn, main, any] {
            if let candidate, !isOff(candidate) { return candidate }
        }
        return nil
    }

    /// The display holding the frontmost on-screen window of `pid`, or nil.
    ///
    /// `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` lists windows
    /// front to back, so the first one belonging to the pid with real bounds
    /// is the one the user is looking at. Bounds are in global top-left
    /// coordinates; `NSScreen.frame` is bottom-left, so the match converts.
    static func displayShowing(pid: pid_t) -> CGDirectDisplayID? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 1, h > 1
            else { continue }
            // Centre of the window, flipped into NSScreen space.
            let point = NSPoint(x: x + w / 2, y: totalHeight - (y + h / 2))
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                return screen.displayID
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Regenerate and run the tests**

Run: `xcodegen generate >/dev/null && xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "error:|Test Suite 'DictationStripTests'|passed|failed" | head`
Expected: `Test Suite 'DictationStripTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Chalant/Features/DictationDisplay.swift ChalantTests/DictationStripTests.swift Chalant.xcodeproj
git commit -m "feat(strip): the strip opens where the target app is

Not NSScreen.main and not the pointer's display. The old panel used .main,
which on the founder's desk is the external monitor while their eyes are on the
app they are dictating into: that is why dictation looked invisible. Pure rule,
tested, with the fallback order pinned and off displays skipped.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

---

### Task 3: `.dictating` in the view model

**Files:**
- Modify: `Chalant/NotchViewModel.swift:29-33` (the `IslandState` enum), and near `startListening()` at `:1471`
- Modify: `ChalantTests/DictationStripTests.swift` (append)

**Interfaces:**
- Consumes: `DictationDisplay.resolve` (Task 2) is NOT used here; the caller passes a resolved display.
- Produces on `NotchViewModel`: `case dictating` in `IslandState`; `@Published var dictationLevel: CGFloat`; `@Published var dictationInfo: DictationInfo?` where `struct DictationInfo: Equatable { var appName: String; var micName: String? }`; `func beginDictating(into appName: String, mic: String?, on display: CGDirectDisplayID?)`; `func updateDictating(level: CGFloat, mic: String?)`; `func endDictating()`.

- [ ] **Step 1: Write the failing test**

Append inside `DictationStripTests`:

```swift
    // MARK: - .dictating is an owned expansion, like .listening

    func testDictatingRendersOnlyOnItsOwnerDisplay() {
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: a, face: a), .dictating)
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: a, face: b), .collapsed)
        XCTAssertEqual(NotchViewModel.state(.dictating, expandedOn: nil, face: a), .collapsed)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "error:|passed|failed" | head`
Expected: compile error, `type 'NotchViewModel.IslandState' has no member 'dictating'`

- [ ] **Step 3: Add the state and the three methods**

In `Chalant/NotchViewModel.swift`, change the enum at line 29:

```swift
    enum IslandState {
        case collapsed
        case listening
        /// Hold-to-dictate is live. A SIBLING of `.listening`, never a reuse:
        /// `.listening` runs `voice.begin()`, which starts VoiceController's
        /// own recognizer, and two engines listening at once is the
        /// doubled-text failure the dictation merge exists to end.
        case dictating
        case expanded
    }
```

Then, directly above `private func startListening()` (line 1471), add:

```swift
    // MARK: - Dictating

    /// What the strip shows beside the level: where the words are going and
    /// which ear is live.
    struct DictationInfo: Equatable {
        var appName: String
        var micName: String?
    }

    /// The voice, 0...1, driven by DictationController's meter timer.
    @Published var dictationLevel: CGFloat = 0
    @Published var dictationInfo: DictationInfo?

    /// Open the strip. Owns a display like an expansion does, ducks the room
    /// like listening does, and touches nothing on `voice`.
    func beginDictating(into appName: String, mic: String?, on display: CGDirectDisplayID?) {
        guard state == .collapsed else { return }
        expandedDisplayID = display ?? defaultOwnerDisplay()
        dictationInfo = DictationInfo(appName: appName, micName: mic)
        dictationLevel = 0
        quietTheRoom()
        state = .dictating
    }

    func updateDictating(level: CGFloat, mic: String?) {
        guard state == .dictating else { return }
        dictationLevel = level
        if let mic, mic != dictationInfo?.micName {
            // The ear can hop mid-hold; the strip must say so in place.
            dictationInfo?.micName = mic
        }
    }

    func endDictating() {
        guard state == .dictating else { return }
        restoreTheRoom()
        dictationLevel = 0
        dictationInfo = nil
        state = .collapsed
        expandedDisplayID = nil
    }
```

- [ ] **Step 4: Fix every exhaustive switch the compiler now flags**

Run: `xcodebuild build -scheme Chalant -configuration Debug 2>&1 | grep -E "error:.*switch must be exhaustive|error:.*dictating" | head`

For each site listed, add a `.dictating` arm that does what `.listening` does at that site. Known sites from reading the code:

- `Chalant/Views/NotchRootView.swift:216-221` (`islandSize`): add `case .dictating: return Self.dictatingSize` where `private static let dictatingSize = CGSize(width: 520, height: 68)` is declared beside `listeningSize` at line 187. (520 is the default `expandedWidth`; Task 4 reads the per-display value.)

Any other site: treat `.dictating` as `.listening`.

Run again until it prints nothing, then: `xcodebuild build -scheme Chalant -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -scheme Chalant -destination 'platform=macOS' -only-testing:ChalantTests/DictationStripTests 2>&1 | grep -E "Test Suite 'DictationStripTests'|passed|failed" | head`
Expected: `Test Suite 'DictationStripTests' passed`

- [ ] **Step 6: Commit**

```bash
git add Chalant/NotchViewModel.swift Chalant/Views/NotchRootView.swift ChalantTests/DictationStripTests.swift
git commit -m "feat(strip): a .dictating state, sibling to .listening

Never a reuse: .listening runs voice.begin(), which starts VoiceController's
own recognizer, and two engines listening at once is the doubled-text failure
the merge exists to end. .dictating owns a display like an expansion and ducks
the room like listening, and touches nothing on voice.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

---

### Task 4: The strip itself in `NotchRootView`

**Files:**
- Modify: `Chalant/Views/NotchRootView.swift` (near line 187 for size, 216 for `islandSize`, 439 for the shadow, 528 for the content switch)

**Interfaces:**
- Consumes: `model.state == .dictating`, `model.dictationLevel`, `model.dictationInfo` (Task 3); `DictationStripLevel.*` (Task 1).
- Produces: nothing new for later tasks; this is the leaf.

- [ ] **Step 1: The strip's size, per display**

At line 187, replace the constant added in Task 3 with a computed size that respects the display's configured island width:

```swift
    /// The dictation strip: the configured island width, 68pt tall. Low on
    /// purpose; the founder chose the slim strip over the full listening
    /// surface (2026-08-16), and 68 is the least that fits one row of
    /// `Fonts.micro` with the notch clearance above it.
    private var dictatingSize: CGSize {
        CGSize(width: model.expandedSize.width, height: 68)
    }
```

and in `islandSize` (line ~219) make the arm `case .dictating: return dictatingSize`.

- [ ] **Step 2: The rim glow and base pool on the island shape**

Find the `.shadow(` at line 439 that reads:

```swift
                    .shadow(
                        color: Color.black.opacity(face.state == .collapsed ? 0 : 0.45),
                        radius: 14, y: 7
                    )
```

Directly BEFORE that `.shadow(`, add the two level-driven layers:

```swift
                    // The strip IS the meter. Rim glow and base pool both come
                    // from one number through the pinned formulas; there are no
                    // bars. Zero everywhere except while dictating, so the
                    // resting island is untouched.
                    .shadow(
                        color: accent.opacity(face.state == .dictating ? DictationStripLevel.rim(model.dictationLevel).opacity : 0),
                        radius: face.state == .dictating ? DictationStripLevel.rim(model.dictationLevel).radius : 0
                    )
                    .overlay(
                        islandShape.fill(
                            RadialGradient(
                                colors: [accent.opacity(DictationStripLevel.pool(model.dictationLevel)), .clear],
                                center: .bottom, startRadius: 0, endRadius: dictatingSize.width * 0.6
                            )
                        )
                        .opacity(face.state == .dictating ? 1 : 0)
                        .allowsHitTesting(false)
                    )
                    .animation(.easeOut(duration: 0.1), value: model.dictationLevel)
```

- [ ] **Step 3: The content**

At line ~528, directly after the `if face.state == .listening { ... }` block, add:

```swift
            if face.state == .dictating {
                dictatingContent
                    .frame(width: dictatingSize.width, height: dictatingSize.height)
                    .transition(contentTransition(insertionDelay: 0.09))
            }
```

Then, after `private var listeningContent: some View { ... }` (ends near line 812), add:

```swift
    /// The dictation strip's one row: where the words are going, one dot
    /// that is the accent, which ear is live. Nothing else. No words while
    /// talking, no finish hint (letting go is the instruction), no second
    /// symbol. Law 3, one symbol per meaning; law 5, a control appears only
    /// when it can do something.
    private var dictatingContent: some View {
        let dot = DictationStripLevel.dot(model.dictationLevel)
        return HStack {
            Text(model.dictationInfo?.appName ?? "")
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.textGhost)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.l)
            Circle()
                .fill(accent)
                .frame(width: dot.diameter, height: dot.diameter)
                .shadow(color: accent.opacity(0.35 + Double(DictationStripLevel.clamp(model.dictationLevel)) * 0.5), radius: dot.glow)
                .animation(.easeOut(duration: 0.1), value: model.dictationLevel)
            Spacer(minLength: Theme.Space.l)
            Text(model.dictationInfo?.micName ?? "")
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.textGhost.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, face.contentTopReserve + Theme.Space.notchClearance)
        .padding(.bottom, Theme.Space.m)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -scheme Chalant -configuration Debug 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v didFailWithError | head`
Expected: `BUILD SUCCEEDED`. If `Theme.Space.xxl` or `Theme.Space.notchClearance` does not exist, `grep -n "static let" Chalant/Views/Theme.swift | grep -i "space\|clearance"` and use the nearest existing token; do not invent a number.

- [ ] **Step 5: Commit**

```bash
git add Chalant/Views/NotchRootView.swift
git commit -m "feat(strip): the island breathes with the voice

Rim glow, base pool and one dot, all from one number through the pinned
formulas. Zero everywhere except while dictating, so the resting island is
untouched. One row of content: app name, dot, mic name. No words, no finish
hint, no second symbol.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

---

### Task 5: The seam: `DictationSurface`, and the controller stops owning a panel

**Files:**
- Create: `Dictation/ChalantDictationApp/UI/DictationSurface.swift`
- Delete: `Dictation/ChalantDictationApp/UI/ListeningPanel.swift`
- Modify: `Dictation/ChalantDictationApp/DictationController.swift` (lines 25, 186-191, 237, 289, 297, 490, 497-508)

**Interfaces:**
- Produces: `@MainActor protocol DictationSurface: AnyObject { func show(into appName: String, mic: String?, on display: CGDirectDisplayID?); func update(level: CGFloat, mic: String?); func hide() }`, and `DictationController.init(surface: any DictationSurface)`.
- Produces: `struct InsertionTarget` gains `var appName: String?` (read where the strip is shown).

- [ ] **Step 1: The protocol**

```swift
// Dictation/ChalantDictationApp/UI/DictationSurface.swift
import CoreGraphics
import Foundation

/// What dictation needs from whatever shows that it is listening.
///
/// Dictation used to draw its own floating `ListeningPanel`. It now lights up
/// Chalant's island instead, but `Dictation/` must not import the app's view
/// model, so this is the seam: three calls, matching the three the panel had.
/// Ungated, because there is nothing macOS-26 about it.
@MainActor
protocol DictationSurface: AnyObject {
    /// The key went down. `display` is where the target app is showing, or
    /// nil to let the surface choose.
    func show(into appName: String, mic: String?, on display: CGDirectDisplayID?)
    /// On the meter timer while the key is held. `level` is raw peak.
    func update(level: CGFloat, mic: String?)
    /// The key came up, or the session stood down.
    func hide()
}
```

- [ ] **Step 2: Delete the panel**

Run: `git rm Dictation/ChalantDictationApp/UI/ListeningPanel.swift`

- [ ] **Step 3: The controller owns a surface**

In `Dictation/ChalantDictationApp/DictationController.swift`:

Replace line 25 `private let panel = ListeningPanel()` with:

```swift
    /// Whatever shows that dictation is listening. Chalant hands in its
    /// island; the panel this used to own is gone.
    private let surface: any DictationSurface

    init(surface: any DictationSurface) {
        self.surface = surface
    }
```

At lines 186-191, where `target = InsertionTarget(...)` is built, capture the app name and display too:

```swift
        let front = NSWorkspace.shared.frontmostApplication
        target = InsertionTarget(
            bundleID: front?.bundleIdentifier,
            processID: front?.processIdentifier,
            capturedAt: Date(),
            appName: front?.localizedName
        )
        // Where the strip opens: the display showing the app being dictated
        // into. Resolved here, at key-down, because that is when we know it.
        let targetDisplay = front.flatMap { DictationDisplayLookup.shared?.displayShowing(pid: $0.processIdentifier) }
```

(`DictationDisplayLookup` is a tiny seam so the package does not import the app's `DictationDisplay`; see Step 4.)

Replace `panel.show()` at line 237 with:

```swift
        surface.show(into: target?.appName ?? target?.bundleID ?? "", mic: await audio.currentDevice?.name, on: targetDisplay)
```

Replace every `panel.hide()` (lines 289, 297, 490) with `surface.hide()`.

Replace the meter body at lines 497-508 with:

```swift
    private func startMeter() {
        meterTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transcriber != nil else { return }
                let level = await self.audio.peak
                let mic = await self.audio.currentDevice?.name
                self.surface.update(level: CGFloat(level), mic: mic)
            }
        }
        timer.tolerance = 0.01
        meterTimer = timer
    }
```

- [ ] **Step 4: The display lookup seam and `InsertionTarget.appName`**

Add to the bottom of `DictationSurface.swift`:

```swift
/// How the controller asks which display a pid is showing on, without the
/// package knowing how the app answers. Set once at launch by the app.
@MainActor
protocol DictationDisplayLookup: AnyObject {
    func displayShowing(pid: pid_t) -> CGDirectDisplayID?
}

extension DictationDisplayLookup {
    /// The app installs its implementation here. Nil in tests and before
    /// launch finishes, in which case the surface picks a display itself.
    nonisolated(unsafe) static var shared: (any DictationDisplayLookup)? {
        get { _dictationDisplayLookup }
        set { _dictationDisplayLookup = newValue }
    }
}
@MainActor private var _dictationDisplayLookup: (any DictationDisplayLookup)?
```

Find `struct InsertionTarget` (`grep -rn "struct InsertionTarget" Dictation/`) and add `public var appName: String? = nil` as the last stored property, with a matching trailing `init` parameter defaulting to nil so existing callers compile.

- [ ] **Step 5: Build the package alone**

Run: `cd Dictation && swift build 2>&1 | grep -E "error:" | head; cd ..`
Expected: no errors. (The app target will not build yet; `Dictation.swift` still constructs `DictationController()` with no argument. That is Task 6.)

- [ ] **Step 6: Commit**

```bash
git add Dictation/ChalantDictationApp/UI/DictationSurface.swift Dictation/ChalantDictationApp/DictationController.swift Dictation/Sources/ChalantDictationCore/Insert/TargetGuard.swift
git commit -m "feat(strip): dictation talks to a surface, and the panel is gone

Three calls, matching the three the panel had, behind a protocol so the
package does not import the app's view model. ListeningPanel deleted rather
than flagged: the merge design's reason for keeping it is spent, and a second
listening surface is exactly the class of leftover this app has paid for.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

(If `InsertionTarget` lives in a different file than `TargetGuard.swift`, add that file instead.)

---

### Task 6: Wire the island in as the surface

**Files:**
- Modify: `Chalant/Features/Dictation.swift` (the `DictationStack` class, lines ~107-137)
- Modify: `Chalant/ChalantApp.swift` (near line 91-96)
- Create: `Chalant/Features/IslandDictationSurface.swift`

**Interfaces:**
- Consumes: `NotchViewModel.beginDictating/updateDictating/endDictating` (Task 3), `DictationDisplay` (Task 2), `DictationSurface` and `DictationDisplayLookup` (Task 5).

- [ ] **Step 1: The adapter**

```swift
// Chalant/Features/IslandDictationSurface.swift
import AppKit
import CoreGraphics

/// The island, as dictation sees it. Three calls in, three view-model calls
/// out, and the display rule applied on the way.
@MainActor
final class IslandDictationSurface: DictationSurface, DictationDisplayLookup {
    private weak var model: NotchViewModel?
    private let displays: DisplayConfigStore

    init(model: NotchViewModel, displays: DisplayConfigStore) {
        self.model = model
        self.displays = displays
    }

    func show(into appName: String, mic: String?, on display: CGDirectDisplayID?) {
        let pointerOn = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID
        let resolved = DictationDisplay.resolve(
            target: display,
            pointerOn: pointerOn,
            main: NSScreen.main?.displayID,
            any: NSScreen.screens.first?.displayID,
            isOff: { [displays] id in displays.config(for: id).style == .off }
        )
        model?.beginDictating(into: appName, mic: mic, on: resolved)
    }

    func update(level: CGFloat, mic: String?) {
        model?.updateDictating(level: level, mic: mic)
    }

    func hide() {
        model?.endDictating()
    }

    func displayShowing(pid: pid_t) -> CGDirectDisplayID? {
        DictationDisplay.displayShowing(pid: pid)
    }
}
```

If `DisplayConfigStore.config(for:)` does not exist under that name, run `grep -n "func config\|func style" Chalant/Features/DisplayConfigStore.swift` and use the accessor that returns a `Config` for a display id.

- [ ] **Step 2: `Dictation` carries the surface, and `DictationStack` uses it**

In `Chalant/Features/Dictation.swift`, add to the `Dictation` class (below `static let shared`):

```swift
    /// The island. Set once by the app after the notch controller exists;
    /// before that, dictation cannot start, which is fine: it is off by
    /// default and the switch is in the island's own settings.
    var surface: (any DictationSurface)?
```

In `start(defaults:)`, replace `let live = DictationStack()` with:

```swift
        guard let surface else {
            Self.log.error("dictation cannot start: no surface installed yet")
            return
        }
        let live = DictationStack(surface: surface)
```

In `DictationStack`, replace `private let controller = DictationController()` with:

```swift
    private let controller: DictationController

    init(surface: any DictationSurface) {
        controller = DictationController(surface: surface)
    }
```

- [ ] **Step 3: The app installs it**

In `Chalant/ChalantApp.swift`, the block at lines 91-96 currently calls `Dictation.shared.start()` BEFORE the notch controller is created. Reorder so the surface exists first. Replace:

```swift
        Dictation.shared.start()

        // The island itself
        let controller = NotchWindowController()
        controller.show()
        notchController = controller
```

with:

```swift
        // The island itself
        let controller = NotchWindowController()
        controller.show()
        notchController = controller

        // Dictation lights up the island rather than drawing its own panel,
        // so it needs the island to exist before it can start. The surface
        // also answers "which display is this pid on" for the strip.
        let surface = IslandDictationSurface(
            model: controller.viewModel,
            displays: controller.viewModel.displays
        )
        Dictation.shared.surface = surface
        IslandDictationSurface.shared = surface
        Dictation.shared.start()
```

If `controller.viewModel.displays` is not the `DisplayConfigStore`'s name, run `grep -n "DisplayConfigStore" Chalant/NotchViewModel.swift Chalant/NotchWindowController.swift` and use the real property.

- [ ] **Step 4: Regenerate, build, run all tests**

Run: `xcodegen generate >/dev/null && xcodebuild build -scheme Chalant -configuration Debug 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v didFailWithError | head`
Expected: `BUILD SUCCEEDED`

Run: `xcodebuild test -scheme Chalant -destination 'platform=macOS' 2>&1 | grep -E "Test Suite 'All tests'|error:" | tail -3; cd Dictation && swift test 2>&1 | grep "Test run with"; cd ..`
Expected: `Test Suite 'All tests' passed`, and `Test run with 205 tests ... passed`

- [ ] **Step 5: Commit**

```bash
git add Chalant/Features/IslandDictationSurface.swift Chalant/Features/Dictation.swift Chalant/ChalantApp.swift Chalant.xcodeproj
git commit -m "feat(strip): the island is dictation's surface

The app installs IslandDictationSurface once the notch controller exists, and
dictation starts after that rather than before. Show resolves the display
through DictationDisplay with the per-display off rule; update and hide map
straight onto the view model.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
```

---

### Task 7: See it, then hand it to the founder

**Files:**
- Modify: `Dictation/MANUAL-TEST-LOG.md` (append)
- Create: `scripts/preview-strip`

- [ ] **Step 1: A Release build in a scratch DerivedData**

Run: `rm -rf build/strip && xcodebuild -project Chalant.xcodeproj -scheme Chalant -configuration Release -derivedDataPath build/strip build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`. Then confirm the identity matches the installed app so TCC grants carry: `codesign -dvv build/strip/Build/Products/Release/Chalant.app 2>&1 | grep "Authority=Developer"`.

- [ ] **Step 2: The preview script**

```bash
#!/bin/bash
# See the dictation strip. Quits the installed Chalant (two taps = doubled
# text), launches the Release test build, and puts the real one back after.
set -e
cd "$(dirname "$0")/.." || exit 1
APP="build/strip/Build/Products/Release/Chalant.app"
[ -d "$APP" ] || { echo "no strip build; ask Claude"; exit 1; }
osascript -e 'quit app "Chalant"' 2>/dev/null || true; sleep 2
defaults write com.cj.chalant dictationEnabled -bool true
open "$APP"; sleep 4
cat <<'EOF'

  Click into any text field. Hold LEFT OPTION and talk.

  The island should grow into a low strip ON THE SCREEN WITH THAT APP,
  and its rim should light up with your voice. One dot in the middle.
  App name on the left, mic on the right. Let go: it closes.

  Then: cover the mic with your thumb and hold again. The strip should
  open and STAY DARK. That is the pass, not a failure.

  Press Return when done.
EOF
read -r _
osascript -e 'quit app "Chalant"' 2>/dev/null || true; sleep 2
open -a /Applications/Chalant.app 2>/dev/null || true
echo "Your real Chalant is back. Tell Claude what you saw."
```

Run: `chmod +x scripts/preview-strip`

- [ ] **Step 3: The manual-test entry, written BEFORE the founder runs it**

Append to `Dictation/MANUAL-TEST-LOG.md`:

```markdown
## 2026-08-16 — the dictation strip (spec: 2026-08-16-dictation-strip-design.md)

Status: BUILT, NOT YET SEEN BY A HUMAN. `scripts/preview-strip`.

What a pass looks like, per the spec:
- [ ] hold with the target app on the external display: strip on THAT display
- [ ] hold with the target app on the Mac's screen: strip THERE, not the monitor
- [ ] rim, pool and dot visibly follow the voice; quiet room = faint, speech = lit
- [ ] mic covered: strip opens and stays dark (this is the pass condition)
- [ ] a 0.7s hold still visibly opens and closes
- [ ] music playing: ducks on hold, restores on release
- [ ] no words appear in the strip at any point

Result (founder, dated):
```

- [ ] **Step 4: Commit and open the PR**

```bash
git add scripts/preview-strip Dictation/MANUAL-TEST-LOG.md
git commit -m "chore(strip): preview script and the manual-test entry, awaiting a human

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RN7ww7gG3bGHWp8BhmUgk8"
git push -u origin feat/dictation-strip
gh pr create --title "The dictation strip: the island breathes with your voice" --body "Implements docs/superpowers/specs/2026-08-16-dictation-strip-design.md. Not yet seen by a human; run scripts/preview-strip. Left open, not merged."
```

Then tell the founder: run `~/Downloads/moai/scripts/preview-strip`, and report which display the strip opened on, whether it lit with their voice, and whether it stayed dark with the mic covered.

---

## Self-review

**Spec coverage.** Strip content (Task 4), level formulas (1, 4), motion curve (4 uses the island's existing size animation; level uses 0.1s easeOut), which display (2, 6), sibling state (3), the seam and panel deletion (5), app name from `localizedName` (5), per-display `.off` skipping (2, 6), quiet the room (3), pure tests (1, 2, 3), manual tests (7). The settings mismatch is noted in the spec as not-fixed and has no task, correctly.

**Placeholders.** None. Every step has code or an exact command. Two "if the name differs, grep for it" notes are honest hedges about names I could not read tonight, each with the exact grep to run.

**Type consistency.** `DictationSurface.show(into:mic:on:)` matches in Tasks 5 and 6. `beginDictating(into:mic:on:)` matches in Tasks 3 and 6. `DictationStripLevel.rim/pool/dot/clamp` match in Tasks 1 and 4. `DictationDisplay.resolve(target:pointerOn:main:any:isOff:)` matches in Tasks 2 and 6. `InsertionTarget.appName` is added in Task 5 and read in Task 5.
