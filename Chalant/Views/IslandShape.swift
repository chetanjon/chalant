import SwiftUI

/// The droplet silhouette: liquid clinging to the notch. Concave
/// meniscus shoulders where the island meets the screen edge, rounded
/// bottom corners, and a slight belly sag so the glass hangs with
/// weight. All three parameters animate, so the island morphs rather
/// than jumping between states.
///
/// The shoulders flare `eave` points beyond the rect on each side;
/// SwiftUI shapes may draw outside their bounds, and the host panel
/// leaves room for it.
struct IslandShape: InsettableShape {
    var eave: CGFloat
    var bottomRadius: CGFloat
    var belly: CGFloat
    /// How far above the frame the path closes. Real hardware hides its
    /// own top edge under the bezel; an emulated notch has to do the
    /// same deliberately. See `path(in:)` for why closing across the
    /// top is not an option.
    /// Rounds the two top corners and switches the silhouette from a
    /// notch to a free-floating pill. Zero — the default — keeps the
    /// notch shape, which clings to the screen edge and has no top edge
    /// of its own to round.
    var topRadius: CGFloat = 0
    var topOverscan: CGFloat = 6
    /// Radius on the two eave tips, where the shape meets the screen
    /// edge. Clamped to `eave`, so a small island cannot round itself
    /// inside out.
    var tipRadius: CGFloat = 5
    var insetAmount: CGFloat = 0

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

    /// The free-floating shape: a rounded bar, top corners and bottom
    /// corners each with their own radius, keeping the belly so a pill
    /// still hangs with the same weight the notch does.
    private func pillPath(in rect: CGRect) -> Path {
        let kappa: CGFloat = 0.5523
        let half = min(rect.width, rect.height) / 2
        let top = min(topRadius, half)
        let bottom = min(bottomRadius, half)
        let x0 = rect.minX, x1 = rect.maxX
        let y0 = rect.minY, y1 = rect.maxY

        var p = Path()
        p.move(to: CGPoint(x: x0 + top, y: y0))
        p.addLine(to: CGPoint(x: x1 - top, y: y0))
        p.addCurve(
            to: CGPoint(x: x1, y: y0 + top),
            control1: CGPoint(x: x1 - top * (1 - kappa), y: y0),
            control2: CGPoint(x: x1, y: y0 + top * (1 - kappa))
        )
        p.addLine(to: CGPoint(x: x1, y: y1 - bottom))
        p.addCurve(
            to: CGPoint(x: x1 - bottom, y: y1),
            control1: CGPoint(x: x1, y: y1 - bottom * (1 - kappa)),
            control2: CGPoint(x: x1 - bottom * (1 - kappa), y: y1)
        )
        p.addCurve(
            to: CGPoint(x: x0 + bottom, y: y1),
            control1: CGPoint(x: x0 + rect.width * 0.65, y: y1 + belly),
            control2: CGPoint(x: x0 + rect.width * 0.35, y: y1 + belly)
        )
        p.addCurve(
            to: CGPoint(x: x0, y: y1 - bottom),
            control1: CGPoint(x: x0 + bottom * (1 - kappa), y: y1),
            control2: CGPoint(x: x0, y: y1 - bottom * (1 - kappa))
        )
        p.addLine(to: CGPoint(x: x0, y: y0 + top))
        p.addCurve(
            to: CGPoint(x: x0 + top, y: y0),
            control1: CGPoint(x: x0, y: y0 + top * (1 - kappa)),
            control2: CGPoint(x: x0 + top * (1 - kappa), y: y0)
        )
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // A pill is a different object, not a notch with its eaves set
        // to zero: it has a real top edge of its own, all four corners
        // turned, and nothing to cling to. Zero here keeps the notch
        // silhouette, which is what a screen with a cutout wants.
        if topRadius > 0 { return pillPath(in: rect) }
        // Cubic control offset that approximates a circular quarter arc.
        let kappa: CGFloat = 0.5523
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        let e = eave
        let x0 = rect.minX, x1 = rect.maxX
        let y0 = rect.minY, y1 = rect.maxY

        // The eave tips are rounded, not pointed. Each is a 90° meeting
        // of the meniscus (arriving horizontally) and the side running
        // up off-screen, and it lands right on the screen edge where it
        // reads as a sharp spike at the top-left and top-right. Real
        // hardware turns that corner with a radius; so does this.
        let tr = max(0, min(tipRadius, e))

        var p = Path()
        // Start above the frame on the left, come down to the tip.
        p.move(to: CGPoint(x: x0 - e, y: y0 - topOverscan))
        p.addLine(to: CGPoint(x: x0 - e, y: y0 - tr))
        p.addQuadCurve(
            to: CGPoint(x: x0 - e + tr, y: y0),
            control: CGPoint(x: x0 - e, y: y0)
        )
        // Left meniscus: from the eave tip down into the left side.
        p.addCurve(
            to: CGPoint(x: x0, y: y0 + e),
            control1: CGPoint(x: x0 - e * (1 - kappa), y: y0),
            control2: CGPoint(x: x0, y: y0 + e * (1 - kappa))
        )
        p.addLine(to: CGPoint(x: x0, y: y1 - r))
        // Bottom-left corner.
        p.addCurve(
            to: CGPoint(x: x0 + r, y: y1),
            control1: CGPoint(x: x0, y: y1 - r * (1 - kappa)),
            control2: CGPoint(x: x0 + r * (1 - kappa), y: y1)
        )
        // Bellied bottom edge.
        p.addCurve(
            to: CGPoint(x: x1 - r, y: y1),
            control1: CGPoint(x: x0 + rect.width * 0.35, y: y1 + belly),
            control2: CGPoint(x: x0 + rect.width * 0.65, y: y1 + belly)
        )
        // Bottom-right corner.
        p.addCurve(
            to: CGPoint(x: x1, y: y1 - r),
            control1: CGPoint(x: x1 - r * (1 - kappa), y: y1),
            control2: CGPoint(x: x1, y: y1 - r * (1 - kappa))
        )
        p.addLine(to: CGPoint(x: x1, y: y0 + e))
        // Right meniscus: back up to the eave tip, stopping short so the
        // tip can be turned with a radius rather than a point.
        p.addCurve(
            to: CGPoint(x: x1 + e - tr, y: y0),
            control1: CGPoint(x: x1, y: y0 + e * (1 - kappa)),
            control2: CGPoint(x: x1 + e * (1 - kappa), y: y0)
        )
        p.addQuadCurve(
            to: CGPoint(x: x1 + e, y: y0 - tr),
            control: CGPoint(x: x1 + e, y: y0)
        )
        // The top closes ABOVE the frame, never straight across it.
        //
        // `closeSubpath()` alone ran a line from this eave tip back to
        // the left one. The right meniscus arrives here heading +x and
        // that line leaves heading -x: a 180° reversal at each tip.
        // A miter join has no finite solution at 180°, so strokeBorder
        // falls back to bevel and cuts each corner flat — the "sharp
        // turn at the top". It is stroked up to seven times over in
        // NotchRootView, so it reads as a hard edge, not a hairline.
        //
        // On a MacBook y0 sits on the top pixel row under the bezel and
        // none of it was ever visible. An external display has no bezel
        // and renders the lot. Lifting the closing edge above the frame
        // puts it and both reversals off-screen, which is exactly what
        // the hardware does implicitly; the two corners left behind are
        // ordinary 90° turns that miter cleanly. The visible silhouette
        // is unchanged — the meniscus still starts at y0.
        p.addLine(to: CGPoint(x: x1 + e, y: y0 - topOverscan))
        p.addLine(to: CGPoint(x: x0 - e, y: y0 - topOverscan))
        p.closeSubpath()
        return p
    }
}
