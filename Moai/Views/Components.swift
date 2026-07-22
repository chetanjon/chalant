import AppKit
import SwiftUI

/// Real translucency behind the expanded island: whatever sits under
/// the notch softly bleeds through, the way system HUDs do.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Chips that wrap like words: each row fills leading to trailing,
/// and overflow starts a new line instead of crushing labels.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? max(0, x - spacing) : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

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

/// The one uppercase micro section header. Trailing rule optional;
/// tint lifts to the accent where a phase owns the pane. The rule
/// itself starts with a breath of the accent and fades to hairline,
/// a little warmth without a single filled surface.
struct SectionHeader: View {
    let title: String
    var tint: Color = Theme.textTertiary
    var trailingRule = false

    @Environment(\.moaiAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title.uppercased())
                .font(Theme.Fonts.micro)
                .tracking(1.3)
                .foregroundStyle(tint)
            if trailingRule {
                LinearGradient(
                    colors: [accent.opacity(0.30), Color.white.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
            }
        }
    }
}

/// An empty pane: one quiet hint line, plus a CTA only where the
/// pane itself offers the next step.
struct EmptyPaneHint<CTA: View>: View {
    let message: String
    @ViewBuilder var cta: () -> CTA

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Text(message)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textHint)
                .multilineTextAlignment(.center)
            cta()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

extension EmptyPaneHint where CTA == EmptyView {
    init(message: String) {
        self.init(message: message) { EmptyView() }
    }
}

extension View {
    /// List-row content insets, one treatment for every row card.
    func rowInsets() -> some View {
        padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
    }
}

/// One line that glides when it overflows: title, a dot, subtitle.
/// It only exists while music plays, playback feedback, so it keeps
/// moving under the Still feel; the system Reduce Motion setting
/// shows it statically truncated instead.
struct MarqueeText: View {
    let title: String
    var subtitle = ""

    @State private var contentWidth: CGFloat = 0
    @State private var appeared = Date()

    var body: some View {
        GeometryReader { geo in
            content(available: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func content(available: CGFloat) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            staticLine
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if contentWidth <= available {
            line
                .background(widthReader)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                line
                    .background(widthReader)
                    .offset(x: -offset(at: context.date, span: contentWidth - available))
                    .frame(width: available, height: nil, alignment: .leading)
                    .clipped()
            }
            .mask(fadeMask(available))
            .frame(maxHeight: .infinity)
        }
    }

    private var line: some View {
        HStack(spacing: Theme.Space.snug) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
            if !subtitle.isEmpty {
                Text("·")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textGhost)
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var staticLine: some View {
        Text(subtitle.isEmpty ? title : "\(title) · \(subtitle)")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Measured the way the island measures itself: onChange of
    /// geometry, preferences silently fail in this hierarchy.
    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, width in
                    contentWidth = width
                }
        }
    }

    /// Ping-pong: rest at the start, glide to the end, rest, glide
    /// back. Reads quieter than the looping-copy marquee.
    private func offset(at date: Date, span: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        let glide = Double(span) / 20.0
        let cycle = 2.0 + glide + 1.5 + glide
        var t = date.timeIntervalSince(appeared)
            .truncatingRemainder(dividingBy: cycle)
        if t < 2 { return 0 }
        t -= 2
        if t < glide { return span * CGFloat(t / glide) }
        t -= glide
        if t < 1.5 { return span }
        t -= 1.5
        return span * CGFloat(1 - t / glide)
    }

    private func fadeMask(_ width: CGFloat) -> some View {
        let edge = min(8 / max(width, 16), 0.45)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: edge),
                .init(color: .white, location: 1 - edge),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
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

/// A list that hugs a few rows and scrolls many, so a nearly empty
/// panel never wears a fixed-height void (one lonely note sat above
/// 200 points of black, and the island read as stuck).
struct HuggingList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                content()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    content()
                }
            }
        }
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

    private var name: String { color.displayName }
    private var symbol: String { color.symbol }

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
