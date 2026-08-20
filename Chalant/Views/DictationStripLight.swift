import AppKit
import SwiftUI

/// The dictation strip's light: Slipstream.
///
/// The island's outline carries a thin white core and one tight accent glow,
/// near dark in silence and vivid on the voice, masked so the lit stretch of
/// edge starts around the strip's centre and spreads toward the ends as the
/// sentence goes on (`DictationStripLevel.spread`). A dim pool of accent
/// light rests at the floor of the glass and kicks wider with the voice.
/// Every syllable ticks the whole lit edge brighter at once (the pulse) and
/// fires a pair of glints racing the top edge. At rest nothing moves: the
/// strip waits, dark and taut. (A resting sheen that swept the top edge was
/// built and cut the same day: the founder saw it "sliding from left",
/// 2026-08-20. Nothing on this strip may travel except on a syllable.)
///
/// Drawn on Core Animation layers, not SwiftUI views, for the reason written
/// on `RimLayerView`: the halo's first cut (1.17.0) was blurred SwiftUI
/// strokes re-laid-out on every 30 Hz meter tick, which cost the main thread
/// 20% in `NSHostingView.layout` and the founder felt it as lag. Here every
/// tick is a handful of layer property sets; the render server does the
/// blur, and the glints and sheen run entirely on CA animations.
struct DictationStripLight: NSViewRepresentable {
    let shape: IslandShape
    let accent: Color
    let level: CGFloat
    let fill: CGFloat
    let pulse: CGFloat
    let pace: CGFloat
    let beat: Int
    let sway: CGFloat
    let size: CGSize

    func makeNSView(context: Context) -> LightHostView {
        let view = LightHostView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: LightHostView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: LightHostView) {
        view.apply(
            shape: shape, accent: NSColor(accent), level: level, fill: fill,
            pulse: pulse, pace: pace, beat: beat, sway: sway, size: size
        )
    }

    final class LightHostView: NSView {
        /// How far the glow can spill past the strip; the mask must cover it
        /// or the light is cut square at the strip's bounds.
        static let spill: CGFloat = 100
        /// Between meter ticks (33 ms) the layers glide rather than step; the
        /// smoothing itself lives in `DictationStripLevel.Voice`.
        static let tickGlide: CFTimeInterval = 0.05

        private let container = CALayer()
        private let glow = CAShapeLayer()
        private let core = CAShapeLayer()
        private let spread = CAGradientLayer()
        private let poolContainer = CALayer()
        private let poolMask = CAShapeLayer()
        private let poolGlow = CAGradientLayer()
        /// The second blob of the living pool, counter-phase to the first,
        /// so the light reads as liquid rather than a metronome.
        private let poolGlow2 = CAGradientLayer()
        /// Two per side, round-robin, so a quick talker's glints can overlap.
        private var glintLayers: [CAGradientLayer] = []
        private var currentShape: IslandShape?
        private var stripSize: CGSize = .zero
        private var firedBeat: Int = -1
        private var glintTurn = 0
        private(set) var appliedLevel: CGFloat = 0
        private(set) var appliedFill: CGFloat = 0

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The layers the tests read.
        var strokeLayers: [CAShapeLayer] { [glow, core] }
        var spreadMask: CAGradientLayer { spread }
        var poolLayer: CAGradientLayer { poolGlow }
        var glints: [CAGradientLayer] { glintLayers }

        func apply(
            shape: IslandShape, accent: NSColor, level: CGFloat, fill: CGFloat,
            pulse: CGFloat, pace: CGFloat, beat: Int, sway: CGFloat, size: CGSize
        ) {
            wantsLayer = true
            if container.superlayer == nil { build() }
            currentShape = shape
            stripSize = size
            appliedLevel = level
            appliedFill = fill

            let slip = DictationStripLevel.slip(level: level, pulse: pulse)
            let pool = DictationStripLevel.pool(level: level, pulse: pulse, pace: pace)
            let tint = accent.cgColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.tickGlide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            glow.strokeColor = accent.withAlphaComponent(0.8).cgColor
            glow.lineWidth = slip.glowWidth
            glow.opacity = Float(slip.glowOpacity)
            glow.shadowColor = tint
            glow.shadowRadius = slip.glowBlur
            glow.shadowOpacity = 0.9
            core.lineWidth = slip.coreWidth
            core.opacity = Float(slip.coreOpacity)
            core.shadowColor = tint
            core.shadowRadius = slip.coreBlur
            core.shadowOpacity = 0.85
            // The pool is alive: both blobs drift and wobble on the sway
            // phase, in place, so the speaker always sees something moving
            // while the strip listens.
            let life = DictationStripLevel.poolSway(phase: sway, level: level)
            let floor = CGPoint(x: bounds.midX, y: bounds.maxY)
            let poolRadius = size.height * pool.radius
            let poolColors = [
                accent.withAlphaComponent(1).cgColor,
                accent.withAlphaComponent(0.4).cgColor,
                accent.withAlphaComponent(0).cgColor,
            ]
            poolGlow.opacity = Float(pool.opacity)
            poolGlow.transform = CATransform3DMakeScale(pool.stretch, 1, 1)
            poolGlow.position = CGPoint(x: floor.x + life.drift, y: floor.y)
            let r1 = poolRadius * life.wobble
            poolGlow.bounds = CGRect(x: 0, y: 0, width: r1 * 2, height: r1 * 2)
            poolGlow.colors = poolColors
            poolGlow2.opacity = Float(pool.opacity * 0.7)
            poolGlow2.transform = CATransform3DMakeScale(pool.stretch, 1, 1)
            poolGlow2.position = CGPoint(
                x: floor.x + life.drift * DictationStripLevel.counterDrift, y: floor.y
            )
            let r2 = poolRadius * DictationStripLevel.counterScale * (2 - life.wobble)
            poolGlow2.bounds = CGRect(x: 0, y: 0, width: r2 * 2, height: r2 * 2)
            poolGlow2.colors = poolColors
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.1)
            spread.locations = Self.spreadLocations(fill: fill, stripWidth: size.width)
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rebuildPaths()
            CATransaction.commit()

            if beat != firedBeat {
                if firedBeat >= 0 { fireGlints(fill: fill, pace: pace, pulseStrength: max(pulse, 0.4)) }
                firedBeat = beat
            }
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
            core.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
            spread.startPoint = CGPoint(x: 0, y: 0.5)
            spread.endPoint = CGPoint(x: 1, y: 0.5)
            spread.colors = [
                NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor,
                NSColor.clear.cgColor, NSColor.clear.cgColor,
            ]
            container.masksToBounds = false
            container.mask = spread
            for stroke in strokeLayers { container.addSublayer(stroke) }

            for blob in [poolGlow, poolGlow2] {
                blob.type = .radial
                blob.startPoint = CGPoint(x: 0.5, y: 0.5)
                blob.endPoint = CGPoint(x: 1, y: 1)
                blob.locations = [0, 0.6, 1]
            }
            poolMask.fillColor = NSColor.black.cgColor
            poolContainer.mask = poolMask
            poolContainer.addSublayer(poolGlow2)
            poolContainer.addSublayer(poolGlow)

            for side in [-1, 1] {
                for _ in 0..<2 {
                    let glint = CAGradientLayer()
                    glint.startPoint = CGPoint(x: side < 0 ? 1 : 0, y: 0.5)
                    glint.endPoint = CGPoint(x: side < 0 ? 0 : 1, y: 0.5)
                    glint.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
                    glint.cornerRadius = DictationStripLevel.glintWidth / 2
                    glint.opacity = 0
                    glint.name = side < 0 ? "left" : "right"
                    glintLayers.append(glint)
                }
            }

            layer?.masksToBounds = false
            layer?.addSublayer(poolContainer)
            layer?.addSublayer(container)
            for glint in glintLayers { layer?.addSublayer(glint) }
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
            glow.frame = bounds
            glow.path = path
            // strokeBorder kept the core inside the shape; a shape layer
            // strokes astride the path, so the core pulls in by half its
            // width to land on the edge rather than over it.
            core.frame = bounds
            let coreInset = core.lineWidth / 2
            core.path = currentShape.path(in: bounds.insetBy(dx: coreInset, dy: coreInset)).cgPath
            poolContainer.frame = bounds
            poolMask.frame = bounds
            poolMask.path = path
            let glintY = DictationStripLevel.glintInset + DictationStripLevel.glintWidth / 2
            for glint in glintLayers {
                glint.bounds = CGRect(
                    x: 0, y: 0,
                    width: DictationStripLevel.glintLength, height: DictationStripLevel.glintWidth
                )
                glint.position = CGPoint(x: bounds.midX, y: glintY)
            }
            let s = Self.spill
            spread.frame = bounds.insetBy(dx: -s, dy: -s)
        }

        /// A syllable landed: a pair of glints races the top edge outward
        /// from the centre and is gone before the next word.
        private func fireGlints(fill: CGFloat, pace: CGFloat, pulseStrength: CGFloat) {
            guard bounds.width > 0 else { return }
            let corner = DictationStripLevel.cornerRadius(height: bounds.height)
            let reach = min(
                DictationStripLevel.spread(fill: fill) * bounds.width,
                bounds.width / 2 - corner - 6
            )
            guard reach > 8 else { return }
            let duration = DictationStripLevel.glintDuration(pace: pace)
            for side: CGFloat in [-1, 1] {
                let pool = glintLayers.filter { ($0.name == "left") == (side < 0) }
                let glint = pool[glintTurn % pool.count]
                let from = CGPoint(x: bounds.midX, y: glint.position.y)
                let to = CGPoint(x: bounds.midX + side * reach, y: glint.position.y)
                let race = CABasicAnimation(keyPath: "position")
                race.fromValue = from
                race.toValue = to
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [Float(0.75 + 0.25 * pulseStrength), Float(0.2 + 0.45 * pulseStrength), 0]
                fade.keyTimes = [0, 0.6, 1]
                for animation in [race, fade] as [CAAnimation] {
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                }
                glint.removeAllAnimations()
                glint.add(race, forKey: "race")
                glint.add(fade, forKey: "fade")
            }
            glintTurn += 1
        }
    }
}

/// The goodbye: on release the light gathers into a point at the strip's
/// centre for the first beat of the phase, then the point shoots up into the
/// notch with a short trail. Once, and gone before the pour is.
struct DictationSentLight: View {
    let accent: Color
    /// 0 gathering at the strip's centre; `sentGather` the shot begins;
    /// 1 above the notch and gone.
    let phase: CGFloat
    let stripHeight: CGFloat

    var body: some View {
        let d = DictationStripLevel.sentDiameter
        let grow = min(1, phase / DictationStripLevel.sentGather)
        let u = max(0, (phase - DictationStripLevel.sentGather) / (1 - DictationStripLevel.sentGather))
        let rise = u * u
        let centerY = stripHeight / 2 - (stripHeight / 2 + DictationStripLevel.sentOvershoot) * rise
        let trail = DictationStripLevel.sentTrail * u
        ZStack(alignment: .top) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5 * Double(1 - u)), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 1.6, height: max(trail, 0.1))
                .offset(y: centerY)
                .opacity(u > 0 ? 1 : 0)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.95), accent.opacity(0.55), accent.opacity(0)],
                        center: .center, startRadius: 0, endRadius: d / 2
                    )
                )
                .frame(width: max(d * grow, 0.1), height: max(d * grow, 0.1))
                .blur(radius: 2)
                .offset(y: centerY - d * grow / 2)
                .opacity(Double(1 - u))
        }
        .allowsHitTesting(false)
    }
}
