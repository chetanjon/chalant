import SwiftUI

/// The standard card treatment: quiet surface fill with a faint hairline.
private struct MoaiCard: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairlineFaint, lineWidth: 1)
            )
    }
}

extension View {
    func moaiCard(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(MoaiCard(radius: radius))
    }
}

/// The field treatment: brighter fill than a card, hairline stroke
/// that warms to the accent while the field is in use.
private struct MoaiField: ViewModifier {
    var active: Bool
    @Environment(\.moaiAccent) private var accent

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .fill(Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(
                        active ? accent.opacity(0.5) : Theme.hairlineFaint,
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func moaiField(active: Bool = false) -> some View {
        modifier(MoaiField(active: active))
    }
}

/// Rows and chips answer the cursor: the surface lifts, the edge
/// sharpens. Owns its own hover state so every instance is independent.
private struct HoverHighlight: ViewModifier {
    var radius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.03 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.10 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .onHover { hovered = $0 }
            .animation(Theme.Motion.hover, value: hovered)
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = Theme.Radius.row) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
}

/// Choreographed open: rows breathe in one after another, top to
/// bottom, just behind the shell. Under Still it's a plain fade.
private struct StaggeredReveal: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        let ambient = Theme.Feel.current.ambient
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !ambient ? 0 : 4)
            .onAppear {
                let delay = ambient ? 0.06 + 0.045 * Double(index) : 0
                withAnimation(Theme.Motion.content.delay(delay)) { shown = true }
            }
            .onDisappear { shown = false }
    }
}

extension View {
    func staggeredReveal(_ index: Int) -> some View {
        modifier(StaggeredReveal(index: index))
    }
}

/// Every custom button presses back: a soft sink on click. Under
/// Still (or system Reduce Motion) only the opacity dips.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let still = !Theme.Feel.current.ambient
        return configuration.label
            .scaleEffect(configuration.isPressed && !still ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.hover, value: configuration.isPressed)
    }
}

/// The universal small glyph button: a comfortable 22pt hit target
/// around the icon, a tint lift and faint halo on hover, and a press
/// sink. Every bare-glyph control in the app routes through this.
struct HoverGlyphButton: View {
    let symbol: String
    var scale: Theme.Fonts.IconScale = .s
    var tint: Color = Theme.textSecondary
    var weight: Font.Weight = .semibold
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Fonts.icon(scale, weight: weight))
                .foregroundStyle(hovered ? lifted : tint)
                .frame(minWidth: 22, minHeight: 22)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }

    /// One step up the text hierarchy; colors outside it keep their
    /// tint and rely on the halo for feedback.
    private var lifted: Color {
        if tint == Theme.textTertiary { return Theme.textSecondary }
        if tint == Theme.textSecondary { return Theme.textPrimary }
        return tint
    }
}

/// The one close affordance, everywhere a surface can be dismissed.
struct CloseButton: View {
    var scale: Theme.Fonts.IconScale = .xs
    let action: () -> Void

    var body: some View {
        HoverGlyphButton(
            symbol: "xmark",
            scale: scale,
            tint: Theme.textTertiary,
            weight: .bold,
            action: action
        )
    }
}

/// Small icon-only row action (copy, delete, share...).
struct IconActionButton: View {
    let symbol: String
    var tint: Color = Theme.textSecondary
    var dim = false
    let action: () -> Void

    var body: some View {
        HoverGlyphButton(
            symbol: symbol,
            scale: .s,
            tint: dim ? Theme.textTertiary : tint,
            action: action
        )
    }
}

/// A circular countdown, trimmed from twelve o'clock. One component
/// for every ring in the app, from the 11pt wing to the focus dial.
struct ProgressRing<Center: View>: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    let tint: Color
    var trackOpacity: Double = 0.10
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            center()
        }
        .frame(width: size, height: size)
    }
}

extension ProgressRing where Center == EmptyView {
    init(
        progress: Double,
        size: CGFloat,
        lineWidth: CGFloat,
        tint: Color,
        trackOpacity: Double = 0.10
    ) {
        self.init(
            progress: progress,
            size: size,
            lineWidth: lineWidth,
            tint: tint,
            trackOpacity: trackOpacity,
            center: { EmptyView() }
        )
    }
}

/// A soundscape chip that says what it is: icon plus name, or
/// icon-only with a tooltip where the row is tight.
struct NoiseButton: View {
    let color: NoiseEngine.NoiseColor
    let selected: Bool
    var compact = false
    let action: () -> Void

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    private var name: String {
        switch color {
        case .brown: return "Brown"
        case .white: return "White"
        case .pink: return "Pink"
        case .rain: return "Rain"
        case .cafe: return "Café"
        }
    }

    private var symbol: String {
        switch color {
        case .brown: return "water.waves"
        case .white: return "waveform"
        case .pink: return "waveform.path"
        case .rain: return "cloud.rain.fill"
        case .cafe: return "cup.and.saucer.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(Theme.Fonts.icon(.xs))
                if !compact {
                    Text(name)
                        .font(Theme.Fonts.caption)
                }
            }
            .foregroundStyle(
                selected ? accent : (hovered ? Theme.textSecondary : Theme.textTertiary)
            )
            .padding(.horizontal, compact ? Theme.Space.xs : Theme.Space.s)
            .frame(minHeight: 22)
            .background(
                Capsule().fill(
                    selected
                        ? accent.opacity(0.12)
                        : Color.white.opacity(hovered ? 0.06 : 0)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(name)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// Two blobs of the album color drifting on slow orbits inside the
/// glass. Lives only while the island is open, so it costs nothing
/// when collapsed.
struct AuroraView: View {
    let accent: Color

    var body: some View {
        // Radial gradients, not live blurs: a blur filter re-renders
        // every tick and stutters the expand animation; a gradient
        // composites for free and looks the same at these opacities.
        // 12 fps: the blobs drift on 7-11s orbits, so anything faster
        // burns CPU for motion the eye can't resolve.
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let calm = Theme.Motion.ambientSlow
            let t = context.date.timeIntervalSinceReferenceDate / calm
            let dim = calm > 1 ? 0.85 : 1.0
            // Lively pushes a wider drift and lets the second blob's
            // hue wander — same TimelineView, same frame cost.
            let lively = Theme.Feel.current == .lively
            let drift: CGFloat = lively ? 1.15 : 1.0
            ZStack {
                blob(size: CGSize(width: 340, height: 240), fade: 0.16 * dim)
                    .offset(
                        x: -170 + CGFloat(sin(t / 9)) * 28 * drift,
                        y: -70 + CGFloat(cos(t / 7)) * 18 * drift
                    )
                blob(size: CGSize(width: 380, height: 260), fade: 0.12 * dim)
                    .hueRotation(.degrees(-14 + (lively ? sin(t / 13) * 4 : 0)))
                    .saturation(1.2)
                    .offset(
                        x: 160 + CGFloat(cos(t / 11)) * 32 * drift,
                        y: 100 + CGFloat(sin(t / 8)) * 20 * drift
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func blob(size: CGSize, fade: Double) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [accent.opacity(fade), accent.opacity(0)],
                    center: .center,
                    startRadius: 8,
                    endRadius: size.width / 2
                )
            )
            .frame(width: size.width, height: size.height)
    }
}

/// Three dots doing a gentle wave while Moai works.
struct ThinkingDots: View {
    @Environment(\.moaiAccent) private var accent
    @State private var bouncing = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .scaleEffect(bouncing ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: bouncing
                    )
            }
        }
        .onAppear { bouncing = true }
    }
}
