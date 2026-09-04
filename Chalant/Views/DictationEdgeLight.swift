import AppKit
import SwiftUI

/// The light along the top edge of the screen while you dictate.
///
/// **Replaces the floating strip (2026-09-03).** The pill was rejected on
/// three axes at once, so this draws no object: a lit line at the very top
/// of the display, brightest in the middle, reaching further toward the ends
/// as the sentence goes on, with a soft bloom falling from it onto the
/// wallpaper. Nothing travels, exactly as the pill's own rule demanded:
/// the bright point never moves, only its reach and its brightness change.
///
/// Two Core Animation layers and nothing else, for the reason written on
/// `DictationStripLight`: the meter ticks 30 times a second, and a SwiftUI
/// gradient re-laid-out at that rate cost the main thread 20% once already.
/// Here a tick is four property sets with implicit animation off; the render
/// server does the work.
struct DictationEdgeLight: NSViewRepresentable {
    let accent: Color
    let level: CGFloat
    let fill: CGFloat
    let size: CGSize

    func makeNSView(context: Context) -> EdgeHostView {
        let view = EdgeHostView()
        view.apply(accent: accent, level: level, fill: fill, size: size)
        return view
    }

    func updateNSView(_ view: EdgeHostView, context: Context) {
        view.apply(accent: accent, level: level, fill: fill, size: size)
    }

    final class EdgeHostView: NSView {
        private let line = CAGradientLayer()
        private let bloom = CAGradientLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            line.startPoint = CGPoint(x: 0, y: 0.5)
            line.endPoint = CGPoint(x: 1, y: 0.5)
            // **A radial dome, not a band (2026-09-03).** The first cut made
            // the bloom a full-width vertical gradient: it fell off top to
            // bottom but not side to side, so it painted a rectangle the
            // whole width of the screen, which the founder saw as a box. A
            // radial gradient centred at the top middle is light gathering
            // under the notch and fading to nothing at the edges, which is
            // the whole point of the design.
            bloom.type = .radial
            bloom.startPoint = CGPoint(x: 0.5, y: 1)
            bloom.endPoint = CGPoint(x: 1, y: -1)
            layer?.addSublayer(bloom)
            layer?.addSublayer(line)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override var isOpaque: Bool { false }
        /// The light is decoration over whatever the user is really doing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(accent: Color, level: CGFloat, fill: CGFloat, size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let peak = DictationStripLevel.edgePeak(level: level)
            let shoulder = peak * DictationStripLevel.edgeShoulderShare
            let reach = DictationStripLevel.spread(fill: fill)
            let base = NSColor(accent)

            // Implicit animation off: at 30 Hz a half-second default fade
            // turns every tick into a queue of overlapping animations, which
            // is what makes a meter feel like syrup.
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let lineTop = size.height - DictationStripLevel.edgeLineHeight
            line.frame = CGRect(x: 0, y: lineTop,
                                width: size.width, height: DictationStripLevel.edgeLineHeight)
            // The shoulders sit at `reach`, but the fade to nothing carries
            // on well past them so the ends melt into the dark rather than
            // stopping (founder, 2026-09-03: "spread it wider instead of
            // looking like a cutoff end"). A wide, low tail either side.
            let shoulderAt = min(0.42, Double(reach))
            line.colors = [
                base.withAlphaComponent(0).cgColor,
                base.withAlphaComponent(shoulder * 0.5).cgColor,
                base.withAlphaComponent(peak).cgColor,
                base.withAlphaComponent(shoulder * 0.5).cgColor,
                base.withAlphaComponent(0).cgColor,
            ]
            line.locations = [
                0,
                NSNumber(value: 0.5 - shoulderAt),
                0.5,
                NSNumber(value: 0.5 + shoulderAt),
                1,
            ]

            // The dome is as wide as the swell reaches, so louder speech
            // spills its glow further out; the frame is centred on the
            // middle of the edge and only as wide as `reach` allows.
            let domeWidth = size.width * CGFloat(reach) * 2.4
            bloom.frame = CGRect(x: (size.width - domeWidth) / 2,
                                 y: lineTop - DictationStripLevel.edgeBloomHeight,
                                 width: domeWidth, height: DictationStripLevel.edgeBloomHeight)
            // Three stops, fully transparent by 70% down, so the light
            // dissolves inside the frame and the bottom of the frame is
            // empty (founder, 2026-09-03: "there is an end to the bar, like
            // a cutoff in the bottom, remove that so it looks like an
            // aurora"). A two-stop fade let the frame edge clip a still-lit
            // region, which drew the flat line they saw as a box bottom.
            bloom.colors = [
                base.withAlphaComponent(peak * DictationStripLevel.edgeBloomShare).cgColor,
                base.withAlphaComponent(peak * DictationStripLevel.edgeBloomShare * 0.28).cgColor,
                base.withAlphaComponent(0).cgColor,
            ]
            bloom.locations = [0, 0.42, 0.7]
            CATransaction.commit()
        }
    }
}
