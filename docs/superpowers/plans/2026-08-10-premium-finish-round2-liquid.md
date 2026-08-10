# Premium Finish, Round 2: The Liquid: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One pour: the island moves between collapsed, expanded, and per-tab heights on a single damped curve (`Theme.Motion.island`), the pill's top corners animate instead of snapping, expanded content arrives staggered with the pour, and the hover door stops reading a stale height after a state flip.

**Architecture:** The shell is already one view whose frame and `IslandShape` animate on `face.state`, with the content-measured height retargeting the same spring (`ExpandedView.swift:193-221`). This round unifies the tab-change curve onto that same spring, widens `IslandShape.animatableData` to cover the pill's top corners, wires the existing unused `staggeredReveal` into the expanded zones, and fixes one stale read in `NotchWindowController.stateChanged`.

**Tech Stack:** SwiftUI (macOS 14+), XCTest, xcodegen. Build/test: `xcodebuild test -project Chalant.xcodeproj -scheme Chalant`.

## Global Constraints

- One curve for geometry: everything that changes the island's SIZE OR SHAPE animates with `Theme.Motion.island`. `Theme.Motion.content` remains for changes inside a zone that do not move the shell.
- No bounce: `Theme.Motion.island` tiers keep damping >= 0.9 on still/serene/balanced (already true; do not change the tier values).
- Respect `Theme.Feel` and Reduce Motion exactly as the existing code does; add no new motion that ignores them.
- Never animate `.frame` inside a high-rate `TimelineView`; do not add TimelineViews.
- The island's height stays content-measured through the ONE writer at `ExpandedView.swift:193-221`; never add a second writer, never capture a `GeometryProxy` into `DispatchQueue.main.async` (the frozen-proxy trap documented at `ExpandedView.swift:222-253`).
- Hover doors keep reading the TARGET `expandedSize` (deliberate: a door that lags the pour invites mid-pour collapse). Do not change door sizing semantics.
- No em dashes anywhere. All 592 tests stay green. Sessions/chat and `FeatureFlags` untouched. Branch `premium-finish`, commit per task.
- Perf gate at the round proof (controller): `sample Chalant 5` during pours shows `NSHostingView.layout` under 10% of main-thread samples; idle CPU with music paused stays ~0.6%.

---

### Task 1: The pill's top corners join the pour

**Files:**
- Modify: `Chalant/Views/IslandShape.swift:32-39`
- Test: `ChalantTests/MotionPourTests.swift` (create; run `xcodegen` after creating it)

**Interfaces:**
- Produces: `IslandShape.animatableData` covering eave, bottomRadius, belly, topRadius, tipRadius. No callers change; SwiftUI reads the conformance.

- [ ] **Step 1: Write the failing test**

Create `ChalantTests/MotionPourTests.swift`:

```swift
import SwiftUI
import XCTest

@testable import Chalant

/// Round 2 of the premium finish: the pour. These tests pin the shape's
/// animatable surface so a corner can never again snap while the rest
/// of the island glides (the pill's top radius did exactly that).
@MainActor
final class MotionPourTests: XCTestCase {
    func testEveryShapeParameterRidesTheAnimation() {
        var shape = IslandShape(eave: 12, bottomRadius: 16, belly: 0)
        shape.topRadius = 16
        shape.tipRadius = 5
        var data = shape.animatableData
        data.first.first = 22          // eave
        data.first.second = 40         // bottomRadius
        data.second.first.first = 0    // belly
        data.second.first.second = 30  // topRadius
        data.second.second = 8         // tipRadius
        shape.animatableData = data
        XCTAssertEqual(shape.eave, 22)
        XCTAssertEqual(shape.bottomRadius, 40)
        XCTAssertEqual(shape.belly, 0)
        XCTAssertEqual(shape.topRadius, 30)
        XCTAssertEqual(shape.tipRadius, 8)
    }
}
```

- [ ] **Step 2: Run it, verify it fails to build** (the nested `AnimatablePair` accessors do not exist yet)

Run: `xcodegen >/dev/null && xcodebuild test -project Chalant.xcodeproj -scheme Chalant -only-testing:ChalantTests/MotionPourTests 2>&1 | grep -E "error:|Test Case" | head -8`

- [ ] **Step 3: Widen `animatableData`**

Replace `IslandShape.animatableData` (IslandShape.swift:32-39) with:

```swift
    /// Every parameter rides the animation. topRadius and tipRadius
    /// were left out once, and the pill's top corners snapped between
    /// states while the bottom glided (round 2, the pour, fixed it).
    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(eave, bottomRadius),
                AnimatablePair(AnimatablePair(belly, topRadius), tipRadius))
        }
        set {
            eave = newValue.first.first
            bottomRadius = newValue.first.second
            belly = newValue.second.first.first
            topRadius = newValue.second.first.second
            tipRadius = newValue.second.second
        }
    }
```

- [ ] **Step 4: Run the test, verify green, then the full suite**
- [ ] **Step 5: Commit** (`feat(pour): the pill's top corners animate with everything else`)

---

### Task 2: One curve for the tab pour

**Files:**
- Modify: `Chalant/Views/TabRow.swift:155` (inside `SwitcherItem`'s button action)
- Modify: `Chalant/Views/ExpandedView.swift:266-268`

**Interfaces:**
- Consumes: `Theme.Motion.island` (exists).
- Produces: tab switches whose content slide, height change, and shell retarget all share the island spring. No API changes.

- [ ] **Step 1: The switch transaction**

In TabRow.swift, change `withAnimation(Theme.Motion.content) { model.tab = tab }` to `withAnimation(Theme.Motion.island) { model.tab = tab }` and add one comment line above it: `// The pour: a tab change moves the shell, so it rides the island's own curve.`

- [ ] **Step 2: The geometry-moving values**

In ExpandedView.swift, the `.animation` list at 266-268: `value: model.tab`, `value: chatFull`, and `value: model.pane` each become `Theme.Motion.island` (they change the island's height). Leave `value: face.isDropTargeted` on hover and every `Theme.Motion.content` line below them (music/ambience presence, pendingContext, answer) untouched: those move content inside a zone, and where they resize the island the measured write already pours.

- [ ] **Step 3: Full suite green** (`xcodebuild test ... | grep -E "error:|with [0-9]+ failure" | tail -3`)
- [ ] **Step 4: Commit** (`feat(pour): tab switches pour on the island's one curve`)

---

### Task 3: Content arrives with the pour

**Files:**
- Modify: `Chalant/Views/ExpandedView.swift` (the zone VStack in `glanceContent`, ~line 85, the `ForEach(layoutRows)` the task-8 report named)
- Read first: `Chalant/Views/Components.swift:357-378` (`staggeredReveal`)

**Interfaces:**
- Consumes: `staggeredReveal(_ index: Int)` (exists, currently zero call sites).
- Produces: expanded zones fading in staggered on expansion. No API changes.

- [ ] **Step 1: Wire the stagger**

In `glanceContent`, give each rendered zone its `staggeredReveal(index)` using the row's position: change `ForEach(layoutRows)` to `ForEach(Array(layoutRows.enumerated()), id: \.element)` (check `layoutRows`'s element type first; it must stay `Identifiable`-stable so rows do not re-identify, and if `enumerated` would break identity, apply the index via the existing row-building switch instead) and attach `.staggeredReveal(offset)` to each row view. The reveal fires on `onAppear`, which happens once per expansion: exactly the pour-in. Tab switches replace only the panel zone, so only that zone re-reveals, which is correct.

- [ ] **Step 2: Check the feel**

`staggeredReveal` animates with `Theme.Motion.content` plus a 0.06 + 0.045 x index delay (Components.swift:357-378). Do not modify the component. If `Theme.Feel.current == .still`, the component already animates minimally through `Motion.content`'s still tier; no extra gating.

- [ ] **Step 3: Full suite green**
- [ ] **Step 4: Commit** (`feat(pour): the zones arrive with the pour, not before it`)

---

### Task 4: The door stops reading last open's height

**Files:**
- Modify: `Chalant/NotchWindowController.swift:880-905` (`stateChanged`), with `:974-981` (`expandedZone`) as read-only context

**Interfaces:**
- Consumes: `viewModel.expandedSize` (published, target-valued).
- Produces: after a state flip, the `pointerInside` re-derivation uses the height belonging to THIS open, not the previous one. No API changes.

- [ ] **Step 1: Read and fix**

`stateChanged` runs one run-loop turn late and re-derives `pointerInside` from `expandedZone`, which reads `viewModel.expandedSize.height`; at that moment the measured write for the new open may not have landed, so the door check uses the PREVIOUS open's height. Fix minimally: make the re-derivation tolerant of the height arriving a moment later by re-running the containment check once when `expandedSize` next changes after an expand (a one-shot Combine sink on `viewModel.$expandedSize`, `.dropFirst().first()`, installed only in the expanded branch and cancelled on collapse), or an equivalent single deferred re-check. Do NOT poll, do NOT capture GeometryProxies, do NOT change `expandedZone`'s target-size semantics.

- [ ] **Step 2: Full suite green**
- [ ] **Step 3: Commit** (`fix(pour): the door re-checks against this open's height, not the last one's`)

---

### Task 5 (controller): The round proof

- Rebuild Release, install over `~/Downloads/installations/Chalant.app`, relaunch.
- Record the pour: hover-open, tab-switch across three tabs, close; capture video and stills.
- Perf: `sample Chalant 5` during continuous pours; `NSHostingView.layout` share of main-thread samples must be under 10%. Idle CPU with music paused ~0.6%.
- The founder's feel check gates the round.

## Self-review notes

- Spec coverage: one damped curve (T2), pill corner snap (T1), staggered content (T3), hover-zone correctness mid-pour (T4 plus the standing target-size ruling in Global Constraints), perf bar (T5). The spec's "pours between collapsed and expanded" already exists via `.animation(value: face.state)` + the retargeting height write; this round leaves that machinery untouched.
- Names cross-checked: `Theme.Motion.island` used by T2 exists (Theme.swift:320-327); `staggeredReveal(_:)` signature (Components.swift:357) matches T3's usage; `IslandShape` fields in T1's test match IslandShape.swift:13-29.
- T3 carries an explicit identity caution instead of a blind `enumerated()` swap; T4 names the one acceptable mechanism and three forbidden ones.
