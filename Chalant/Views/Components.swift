import AppKit
import SwiftUI

/// Real translucency behind the expanded island: whatever sits under
/// the notch softly bleeds through, the way system HUDs do. Pinned to
/// `.vibrantDark` rather than following the system appearance: the
/// island's whole surface is built as near-black glass, and a light
/// desktop reflected through an unpinned light-mode blur would fight
/// `Theme.textPrimary` for contrast on the one system that has no
/// real Liquid Glass to fall back on (pre-macOS 26).
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
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
private struct ChalantCard: ViewModifier {
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
    func chalantCard(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(ChalantCard(radius: radius))
    }
}

/// The field treatment: brighter fill than a card, hairline stroke
/// that warms to the accent while the field is in use.
private struct ChalantField: ViewModifier {
    var active: Bool
    @Environment(\.chalantAccent) private var accent

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
    func chalantField(active: Bool = false) -> some View {
        modifier(ChalantField(active: active))
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

    @Environment(\.chalantAccent) private var accent

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

/// "now", "7m", "3h": how long ago, in the fewest characters a row can
/// spare. Every strip that timestamps a row reads it the same way.
enum RelativeAge {
    static func short(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// One line: title, a dot, subtitle. It holds still by default.
///
/// The glide is off unless asked for: at the glance's fixed 100pt
/// width, a name spends most of its journey behind the edge fade, and
/// it reads as broken text rather than as motion (user, 2026-07-28).
/// The system Reduce Motion setting keeps it still regardless.
struct MarqueeText: View {
    let title: String
    var subtitle = ""

    @AppStorage("glideLongTitles") private var glideLongTitles = false
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
        if glideLongTitles, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            gliding(available: available)
        } else {
            staticLine
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func gliding(available: CGFloat) -> some View {
        if contentWidth <= available {
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

    /// The same three parts held to the width they are given. The title
    /// yields first and from the end, so the countdown beside it always
    /// survives whole and a name reads from its start: cutting a name
    /// through the middle is the thing that looked broken.
    private var staticLine: some View {
        HStack(spacing: Theme.Space.snug) {
            Text(title)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !subtitle.isEmpty {
                Text("·")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textGhost)
                    .fixedSize()
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
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

/// Samples an SVG circular arc (rx == ry) into `path` as a polyline,
/// via the standard endpoint-to-center parameterization. Kept as an
/// explicit sample so arc direction can never be held backwards the
/// way SwiftUI's addArc sweep flag invites.
private func appendSVGArc(
    _ path: inout Path, from p0: CGPoint, to p1: CGPoint,
    r: CGFloat, largeArc: Bool, sweep: Bool, samples: Int = 48
) {
    let x1 = p0.x, y1 = p0.y, x2 = p1.x, y2 = p1.y
    let x1p = (x1 - x2) / 2, y1p = (y1 - y2) / 2   // x-axis rotation is 0
    let rsq = r * r
    var num = rsq * rsq - rsq * y1p * y1p - rsq * x1p * x1p
    let den = rsq * y1p * y1p + rsq * x1p * x1p
    if num < 0 { num = 0 }
    var coef = den == 0 ? 0 : (num / den).squareRoot()
    if largeArc == sweep { coef = -coef }
    let cxp = coef * y1p, cyp = coef * -x1p
    let cx = cxp + (x1 + x2) / 2, cy = cyp + (y1 + y2) / 2
    func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
        var a = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
        if ux * vy - uy * vx < 0 { a = -a }
        return a
    }
    let ux = (x1p - cxp) / r, uy = (y1p - cyp) / r
    let theta1 = ang(1, 0, ux, uy)
    var dtheta = ang(ux, uy, (-x1p - cxp) / r, (-y1p - cyp) / r)
    if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
    if sweep, dtheta < 0 { dtheta += 2 * .pi }
    for i in 0...samples {
        let a = theta1 + dtheta * CGFloat(i) / CGFloat(samples)
        let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
}

/// The wordmark: "chalant" in the brand's own hand, the exact stroked
/// letterforms from the brand SVG (monoline, round caps, the open-arc
/// c). Drawn in a 255..1067 x 18..194 view box and mapped into `rect`
/// aspect-fit; fill it with a color and it reads as the wordmark.
struct ChalantWordmark: Shape {
    func path(in rect: CGRect) -> Path {
        var cl = Path()
        func M(_ x: CGFloat, _ y: CGFloat) { cl.move(to: CGPoint(x: x, y: y)) }
        func L(_ x: CGFloat, _ y: CGFloat) { cl.addLine(to: CGPoint(x: x, y: y)) }
        func bowl(_ cx: CGFloat) {
            cl.addEllipse(in: CGRect(x: cx - 50, y: 70, width: 100, height: 100))
        }
        appendSVGArc(&cl, from: CGPoint(x: 298.4, y: 84.6),
                     to: CGPoint(x: 298.4, y: 155.4), r: 50, largeArc: true, sweep: false) // c
        M(369, 40); L(369, 170)                                                            // h stem
        M(369, 104); appendSVGArc(&cl, from: CGPoint(x: 369, y: 104),
                     to: CGPoint(x: 437, y: 104), r: 34, largeArc: false, sweep: true); L(437, 170) // h arch
        bowl(545); M(595, 70); L(595, 170)                                                 // a
        M(653, 40); L(653, 170)                                                            // l
        bowl(761); M(811, 70); L(811, 170)                                                 // a
        M(869, 170); L(869, 104); appendSVGArc(&cl, from: CGPoint(x: 869, y: 104),
                     to: CGPoint(x: 937, y: 104), r: 34, largeArc: false, sweep: true); L(937, 170) // n
        M(1019, 44); L(1019, 140); appendSVGArc(&cl, from: CGPoint(x: 1019, y: 140),
                     to: CGPoint(x: 1049, y: 170), r: 30, largeArc: false, sweep: false)   // t stem+hook
        M(995, 70); L(1047, 70)                                                            // t crossbar
        let stroked = cl.strokedPath(
            StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round)
        )
        let box = CGRect(x: 255, y: 18, width: 812, height: 176)
        let s = min(rect.width / box.width, rect.height / box.height)
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -box.midX, y: -box.midY)
        return stroked.applying(t)
    }
}

/// An SF Symbol by name, or the chalant mark for "chalant.mark", sized to
/// sit beside the symbol font it replaces.
struct GlyphImage: View {
    let symbol: String
    var scale: Theme.Fonts.IconScale = .s
    var weight: Font.Weight = .semibold

    var body: some View {
        if symbol == "chalant.mark" {
            // A bare shape carries no text baseline, so rows aligned
            // by .firstTextBaseline hoist it above its neighbors. An
            // unseen symbol donates its frame and baseline, and the
            // mark rides the same grid as the glyphs beside it.
            Image(systemName: "circle.fill")
                .font(Theme.Fonts.icon(scale, weight: weight))
                .hidden()
                .overlay(
                    ChalantMarkView()
                        .frame(width: scale.rawValue + 2, height: scale.rawValue + 2)
                )
        } else {
            Image(systemName: symbol)
                .font(Theme.Fonts.icon(scale, weight: weight))
        }
    }
}

struct HoverGlyphButton: View {
    let symbol: String
    /// What this button does, said once and read twice: as the hover
    /// tooltip and as the VoiceOver name. A bare glyph has no other way
    /// to say either (WCAG 4.1.2, icon-only controls need an accessible
    /// name).
    let label: String
    var scale: Theme.Fonts.IconScale = .s
    var tint: Color = Theme.textSecondary
    var weight: Font.Weight = .semibold
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            GlyphImage(symbol: symbol, scale: scale, weight: weight)
                .foregroundStyle(hovered ? lifted : tint)
                .frame(minWidth: 22, minHeight: 22)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .help(label)
        .accessibilityLabel(label)
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
///
/// Reused past its own name for anything an X can end (stop a focus
/// session, reset a stopwatch): the label is what tells those apart,
/// defaulting to the literal "Close" for the common case.
struct CloseButton: View {
    var scale: Theme.Fonts.IconScale = .xs
    var label = "Close"
    let action: () -> Void

    var body: some View {
        HoverGlyphButton(
            symbol: "xmark",
            label: label,
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
            // Every list in the island shares this component (sessions,
            // clipboard, shelf, notes), and the indicator was fighting
            // the island's own chrome on all of them, not just one (H2,
            // founder 2026-08-02: "remove the scrollbar here its
            // messing with the UI"). Fixed here rather than at a single
            // call site so the fix actually reaches every list rather
            // than the one that got reported. Scrolling itself is
            // untouched, only the indicator is gone.
            //
            // `.never`, not `.hidden`. They are not synonyms: hidden
            // yields to the system, so anyone with "Show scroll bars:
            // Always" in System Settings still gets one, which is why
            // this read as unfixed after it was fixed (founder,
            // 2026-08-02, second report with the bar still there).
            .scrollIndicators(.never)
        }
    }
}

/// Small icon-only row action (copy, delete, share...).
struct IconActionButton: View {
    let symbol: String
    /// What this action does; becomes both the hover tooltip and the
    /// VoiceOver name, since the glyph alone says neither.
    let label: String
    var tint: Color = Theme.textSecondary
    var dim = false
    let action: () -> Void

    var body: some View {
        HoverGlyphButton(
            symbol: symbol,
            label: label,
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

    @Environment(\.chalantAccent) private var accent
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
        // Compact mode drops the visible name and leaves only the
        // glyph (the ambience row's tight track); VoiceOver needs the
        // same word the tooltip already carries.
        .accessibilityLabel(name)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// Three dots doing a gentle wave while Chalant works.
struct ThinkingDots: View {
    @Environment(\.chalantAccent) private var accent
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
