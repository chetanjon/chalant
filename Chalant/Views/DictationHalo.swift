import SwiftUI

/// The dictation strip's light: the island's own outline, glowing.
///
/// Three strokes of the shape (an outer glow that spills both ways, a thin
/// white core on the edge, an inner bleed clipped inside), all read off the
/// smoothed voice through `DictationStripLevel.halo`, and all masked so the
/// lit stretch of edge starts around the strip's centre and spreads toward
/// the ends as the sentence goes on (`DictationStripLevel.spread`). At rest,
/// with ambient motion on, the whole thing breathes: go ahead.
///
/// Opacity, blur and mask only, on the shell; no layout. The breath is a
/// Core Animation repeat, not a TimelineView, for the reason written on
/// `RimLayerView`.
struct DictationHalo: View {
    let shape: IslandShape
    let accent: Color
    let level: CGFloat
    let fill: CGFloat
    let size: CGSize

    @State private var breathIn = false

    /// How far the outer glow can spill past the strip; the mask must cover it
    /// or the glow is cut square at the strip's bounds.
    private static let spill: CGFloat = 100

    var body: some View {
        let halo = DictationStripLevel.halo(level)
        ZStack {
            shape
                .stroke(accent, lineWidth: halo.outerWidth)
                .blur(radius: halo.outerBlur)
                .opacity(halo.outerOpacity)
            shape
                .strokeBorder(accent, lineWidth: 6)
                .blur(radius: halo.innerBlur)
                .opacity(halo.innerOpacity)
                .clipShape(shape)
            shape
                .strokeBorder(Color.white, lineWidth: halo.coreWidth)
                .opacity(halo.coreOpacity)
                .shadow(color: accent.opacity(0.8), radius: halo.coreShadow)
        }
        .mask { spreadMask }
        .opacity(breathIn ? 1 : DictationStripLevel.breathFloor)
        .animation(.easeOut(duration: 0.1), value: level)
        .animation(.easeOut(duration: 0.1), value: fill)
        .allowsHitTesting(false)
        .onAppear {
            if Theme.Feel.current.ambient {
                withAnimation(
                    .easeInOut(duration: DictationStripLevel.breathHalfCycle)
                        .repeatForever(autoreverses: true)
                ) { breathIn = true }
            } else {
                breathIn = true
            }
        }
    }

    /// Lit at the centre, fading to nothing `spread` of the strip's width out
    /// on each side. Wider than the strip by the spill so the outer glow is
    /// masked by the same gradient rather than clipped.
    private var spreadMask: some View {
        let width = size.width + Self.spill * 2
        let half = DictationStripLevel.spread(fill: fill) * size.width / width
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: max(0, 0.5 - half)),
                .init(color: .white, location: 0.5),
                .init(color: .clear, location: min(1, 0.5 + half)),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: width, height: size.height + Self.spill * 2)
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
