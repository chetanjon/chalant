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
