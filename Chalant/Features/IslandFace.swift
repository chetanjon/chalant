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
/// Exactly one of these exists today, built by `NotchWindowController`
/// for the one panel that still travels between displays. That is why
/// `displayID` is a `var`: this face currently follows the travelling
/// island from screen to screen rather than naming one fixed display for
/// good. A per-display map, and the panel that stops travelling, are a
/// later round (W-C/W-D); this is only the shape the render state moves
/// onto first, with the app behaving exactly as it did before.
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

    /// What this face should render as. A passthrough for now: with
    /// exactly one face ever built, "the display that is open" is
    /// always this one, whenever the shared `state` is anything but
    /// collapsed. `NotchViewModel.expandedDisplayID` exists already, but
    /// nothing keeps it current yet — `expand(on:)`/`hoverChanged(_:on:)`
    /// are a later round's job. Once those set and clear it for real,
    /// this becomes `NotchViewModel.state(model.state, expandedOn:
    /// model.expandedDisplayID, face: displayID)`, so a second face
    /// never reads another's expansion as its own (2026-08-02).
    var state: NotchViewModel.IslandState { model.state }

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
