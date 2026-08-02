import AppKit
import Foundation

/// One display's island: everything about how it is drawn there, and
/// nothing about what the app is doing. The feature stores, the layout,
/// and `state` itself stay on `NotchViewModel`, which is one object
/// because the things it owns (an HTTP server, a filesystem scanner, an
/// EventKit grant) can only be one. What was singular only by accident —
/// this screen's resolved style, its notch geometry, whether the
/// pointer is over it — moves here instead (island-per-display-plan,
/// 2026-08-02).
///
/// One of these exists per display that wears an island, built and torn
/// down by `NotchWindowController.rebuildIslands()` as displays come and
/// go. `displayID` stays a `var` because `apply(_:to:)` re-confirms it
/// (to the same value) on every re-measure rather than because the face
/// itself ever moves between screens — nothing does, any more
/// (island-per-display-plan, W-C, 2026-08-02).
///
/// Not unit tested directly: it holds `unowned let model`, so
/// constructing one means constructing a `NotchViewModel`, which starts
/// an `ActivityServer`, a filesystem scanner and an EventKit prompt.
/// Every rule worth asserting about a face is written as a static on
/// `NotchViewModel` that takes plain values instead — `collapsedSpan`,
/// `state(_:expandedOn:face:)`, `islandIsShowing(style:expandedHere:
/// hasSomethingToSay:)` — and those are what the tests call.
@MainActor
final class IslandFace: ObservableObject {
    unowned let model: NotchViewModel

    /// Which display this face is dressing right now, written by
    /// `NotchWindowController.apply(_:to:)` alongside `NotchViewModel`'s
    /// own `islandDisplayID` (kept there too: the Displays pane's
    /// "island here" badge still reads it, and removing it is a later
    /// round's job, not this one's).
    var displayID: CGDirectDisplayID?

    /// This screen's resolved style, already turned out of `.auto`.
    @Published var style: DisplayConfigStore.Style = .notch
    /// Measured from this screen's cutout, or the configured emulated
    /// size where it has none.
    @Published var notchSize = NotchViewModel.defaultNotchSize
    /// Bottom-corner radius of the collapsed island here.
    @Published var cornerRadius: CGFloat = Theme.Island.radiusCollapsed
    /// Room down each side of the expanded island here.
    @Published var contentPadding: CGFloat = Theme.Space.xl
    /// The pointer is on this display's island right now.
    @Published var isHovering = false
    /// Pointer position across this island, 0...1, published by the
    /// window controller's hover poll, quantized so casual movement
    /// costs a few re-renders per second, not twenty. nil = no light.
    @Published var pointerUnit: CGFloat?
    /// A drag is hovering this island: light the accent edge.
    @Published var isDropTargeted = false
    /// This island opened itself for an incoming drag; if the drag
    /// leaves without dropping it closes again.
    var dragExpanded = false

    init(model: NotchViewModel) {
        self.model = model
    }

    /// What this face should render as: `model.state` when this
    /// display is the one `expand(on:)`/`hoverChanged(_:on:)` last gave
    /// the expansion to, `.collapsed` for every other face at the same
    /// instant — the whole of "hovering one display must not expand
    /// four" (2026-08-02).
    var state: NotchViewModel.IslandState {
        NotchViewModel.state(model.state, expandedOn: model.expandedDisplayID, face: displayID)
    }

    /// True where the island wraps a notch, real or emulated: the
    /// render-facing half of this face's own `style`, not the model's.
    var hasPhysicalNotch: Bool { style == .notch }

    /// How much room island content leaves clear at the top, mirroring
    /// `NotchViewModel.contentTopReserve`'s old reasoning but reading
    /// this face's own geometry.
    var contentTopReserve: CGFloat {
        hasPhysicalNotch ? notchSize.height : Theme.Space.m
    }
}
