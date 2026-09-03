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
            // Top to bottom: the bloom is brightest where it meets the line.
            bloom.startPoint = CGPoint(x: 0.5, y: 1)
            bloom.endPoint = CGPoint(x: 0.5, y: 0)
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
            line.colors = [
                base.withAlphaComponent(0).cgColor,
                base.withAlphaComponent(shoulder).cgColor,
                base.withAlphaComponent(peak).cgColor,
                base.withAlphaComponent(shoulder).cgColor,
                base.withAlphaComponent(0).cgColor,
            ]
            line.locations = [
                0,
                NSNumber(value: Double(0.5 - reach)),
                0.5,
                NSNumber(value: Double(0.5 + reach)),
                1,
            ]

            bloom.frame = CGRect(x: 0, y: lineTop - DictationStripLevel.edgeBloomHeight,
                                 width: size.width, height: DictationStripLevel.edgeBloomHeight)
            bloom.colors = [
                base.withAlphaComponent(peak * DictationStripLevel.edgeBloomShare).cgColor,
                base.withAlphaComponent(0).cgColor,
            ]
            bloom.locations = [0, 1]
            CATransaction.commit()
        }
    }
}
