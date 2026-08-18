import AppKit
import SwiftUI

/// The dictation strip's light: the island's own outline, glowing.
///
/// Four strokes of the shape (a wide bloom and a tighter glow that spill
/// both ways, a thin white core on the edge, an inner bleed clipped inside),
/// all read off the smoothed voice through `DictationStripLevel.halo`, and
/// all masked so the lit stretch of edge starts around the strip's centre and
/// spreads toward the ends as the sentence goes on (`DictationStripLevel
/// .spread`). At rest, with ambient motion on, the whole thing breathes: go
/// ahead.
///
/// Drawn on Core Animation layers, not SwiftUI views, for the reason written
/// on `RimLayerView`: the first cut (1.17.0) was four blurred SwiftUI strokes
/// re-laid-out on every 30 Hz meter tick, which cost the main thread 20% in
/// `NSHostingView.layout` and 35-45% of a core overall, and the founder felt
/// it as lag. Here every tick is a handful of layer property sets; the render
/// server does the blur.
struct DictationHalo: NSViewRepresentable {
    let shape: IslandShape
    let accent: Color
    let level: CGFloat
    let fill: CGFloat
    let size: CGSize

    func makeNSView(context: Context) -> HaloHostView {
        let view = HaloHostView()
        view.apply(shape: shape, accent: NSColor(accent), level: level, fill: fill, size: size)
        return view
    }

    func updateNSView(_ view: HaloHostView, context: Context) {
        view.apply(shape: shape, accent: NSColor(accent), level: level, fill: fill, size: size)
    }

    final class HaloHostView: NSView {
        /// How far the bloom can spill past the strip; the mask must cover it
        /// or the glow is cut square at the strip's bounds.
        static let spill: CGFloat = 100
        /// Between meter ticks (33 ms) the layers glide rather than step; the
        /// smoothing itself lives in `DictationStripLevel.Voice`.
        static let tickGlide: CFTimeInterval = 0.05

        private let container = CALayer()
        private let bloom = CAShapeLayer()
        private let outer = CAShapeLayer()
        private let inner = CAShapeLayer()
        private let innerClip = CAShapeLayer()
        private let core = CAShapeLayer()
        private let spread = CAGradientLayer()
        private var currentShape: IslandShape?
        private var stripSize: CGSize = .zero
        private var breathing = false
        private(set) var appliedLevel: CGFloat = 0
        private(set) var appliedFill: CGFloat = 0

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The layers the tests read, outermost first.
        var strokeLayers: [CAShapeLayer] { [bloom, outer, inner, core] }
        var spreadMask: CAGradientLayer { spread }

        func apply(shape: IslandShape, accent: NSColor, level: CGFloat, fill: CGFloat, size: CGSize) {
            wantsLayer = true
            if container.superlayer == nil { build() }
            currentShape = shape
            stripSize = size
            appliedLevel = level
            appliedFill = fill

            let halo = DictationStripLevel.halo(level)
            let tint = accent.cgColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.tickGlide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            bloom.strokeColor = accent.withAlphaComponent(0.35).cgColor
            bloom.lineWidth = halo.bloomWidth
            bloom.shadowColor = tint
            bloom.shadowRadius = halo.bloomBlur
            bloom.shadowOpacity = Float(halo.bloomOpacity)
            outer.strokeColor = accent.withAlphaComponent(0.5).cgColor
            outer.lineWidth = halo.outerWidth
            outer.shadowColor = tint
            outer.shadowRadius = halo.outerBlur
            outer.shadowOpacity = Float(halo.outerOpacity)
            inner.strokeColor = accent.withAlphaComponent(0.5).cgColor
            inner.lineWidth = halo.innerWidth
            inner.shadowColor = tint
            inner.shadowRadius = halo.innerBlur
            inner.shadowOpacity = Float(halo.innerOpacity)
            core.lineWidth = halo.coreWidth
            core.opacity = Float(halo.coreOpacity)
            core.shadowColor = tint
            core.shadowRadius = halo.coreShadow
            core.shadowOpacity = 0.8
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.1)
            spread.locations = Self.spreadLocations(fill: fill, stripWidth: size.width)
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rebuildPaths()
            CATransaction.commit()
            armBreath()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rebuildPaths()
            CATransaction.commit()
        }

        private func build() {
            for stroke in strokeLayers {
                stroke.fillColor = nil
                stroke.lineJoin = .round
                stroke.shadowOffset = .zero
            }
            core.strokeColor = NSColor.white.cgColor
            innerClip.fillColor = NSColor.black.cgColor
            inner.mask = innerClip
            spread.startPoint = CGPoint(x: 0, y: 0.5)
            spread.endPoint = CGPoint(x: 1, y: 0.5)
            spread.colors = [
                NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor,
                NSColor.clear.cgColor, NSColor.clear.cgColor,
            ]
            container.masksToBounds = false
            container.mask = spread
            for stroke in strokeLayers { container.addSublayer(stroke) }
            layer?.masksToBounds = false
            layer?.addSublayer(container)
        }

        /// Lit at the centre, fading to nothing `spread` of the strip's width
        /// out on each side, in the coordinates of a mask that is wider than
        /// the strip by the spill on both sides.
        static func spreadLocations(fill: CGFloat, stripWidth: CGFloat) -> [NSNumber] {
            let maskWidth = stripWidth + spill * 2
            let half = DictationStripLevel.spread(fill: fill) * stripWidth / max(maskWidth, 1)
            return [0, max(0, 0.5 - half), 0.5, min(1, 0.5 + half), 1].map { NSNumber(value: Double($0)) }
        }

        private func rebuildPaths() {
            guard let currentShape, bounds.width > 0, bounds.height > 0 else { return }
            container.frame = bounds
            let path = currentShape.path(in: bounds).cgPath
            for stroke in strokeLayers {
                stroke.frame = bounds
                stroke.path = path
            }
            // strokeBorder kept the core inside the shape; a shape layer
            // strokes astride the path, so the core pulls in by half its
            // width to land on the edge rather than over it.
            let coreInset = core.lineWidth / 2
            core.path = currentShape.path(in: bounds.insetBy(dx: coreInset, dy: coreInset)).cgPath
            innerClip.frame = bounds
            innerClip.path = path
            let s = Self.spill
            spread.frame = bounds.insetBy(dx: -s, dy: -s)
        }

        /// The "go ahead" at rest: the whole halo swings between the breath
        /// floor and full on Core Animation while ambient motion is on. Under
        /// Still there is no breath; the halo still follows the level.
        private func armBreath() {
            let ambient = Theme.Feel.current.ambient
            let armed = container.animation(forKey: "breath") != nil
            if ambient == breathing && ambient == armed { return }
            breathing = ambient
            container.removeAnimation(forKey: "breath")
            guard ambient else { container.opacity = 1; return }
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = Float(DictationStripLevel.breathFloor)
            breath.toValue = 1.0
            breath.duration = DictationStripLevel.breathHalfCycle
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.isRemovedOnCompletion = false
            container.add(breath, forKey: "breath")
        }
    }
}

/// The "sent" light: on release, a soft point gathers at the strip's centre
/// and rises into the notch while the strip pours shut. Once, and gone before
/// the pour is.
struct DictationSentLight: View {
    let accent: Color
    /// 0 at the strip's centre and fully lit; 1 at the top edge and gone.
    let phase: CGFloat
    let stripHeight: CGFloat

    var body: some View {
        let d = DictationStripLevel.sentDiameter
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.9), accent.opacity(0.55), accent.opacity(0)],
                    center: .center, startRadius: 0, endRadius: d / 2
                )
            )
            .frame(width: d, height: d)
            .blur(radius: 3)
            .offset(y: (stripHeight / 2 - d / 2) - (stripHeight / 2) * phase)
            .opacity(Double(1 - phase))
            .allowsHitTesting(false)
    }
}
