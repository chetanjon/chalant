import SwiftUI

/// Brand mark proportions, off the artwork's 1024 box. Every surface
/// that draws the mark (the shape below, the menu bar glyph, the app
/// icon via scripts/make-icon.py) reads from these, so the identity
/// cannot drift between them.
///
/// The mark is the island with an echo around it. Every size drawn in
/// the app is small, so all of them use the artwork's BOLD cut: one
/// thicker ring instead of two faint ones. The full two-ring echo is for
/// 128 pixels and up, which in practice means the app icon alone. Small
/// sizes are a separate tuning, never a scaled copy.
enum ChalantMark {
    /// Bold cut, from chalant-echo-B-bold.svg, all in the 1024 box.
    static let box: CGFloat = 1024
    static let pill = CGRect(x: 347.2, y: 446.1, width: 329.6, height: 131.8)
    static let ring = CGRect(x: 264.8, y: 380.2, width: 494.4, height: 263.7)
    static let ringStroke: CGFloat = 24.7
    static let ringOpacity: CGFloat = 0.5

    /// What the mark occupies, stroke included, so a frame can be filled
    /// edge to edge rather than around a lot of empty box.
    static let bounds = ring.insetBy(dx: -ringStroke / 2, dy: -ringStroke / 2)
    static let aspect: CGFloat = bounds.width / bounds.height

    /// Maps the 1024-box rects into `rect`, aspect-fit and centered.
    static func fitted(_ item: CGRect, in rect: CGRect) -> CGRect {
        var w = rect.width, h = w / aspect
        if h > rect.height {
            h = rect.height
            w = h * aspect
        }
        let scale = w / bounds.width
        let originX = rect.midX - w / 2, originY = rect.midY - h / 2
        return CGRect(
            x: originX + (item.minX - bounds.minX) * scale,
            y: originY + (item.minY - bounds.minY) * scale,
            width: item.width * scale,
            height: item.height * scale
        )
    }

    static func scaled(_ value: CGFloat, in rect: CGRect) -> CGFloat {
        var w = rect.width
        if w / aspect > rect.height { w = rect.height * aspect }
        return value * (w / bounds.width)
    }
}

/// The island itself: a filled pill, fully rounded.
struct ChalantPillShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pill = ChalantMark.fitted(ChalantMark.pill, in: rect)
        return Path(roundedRect: pill, cornerRadius: pill.height / 2)
    }
}

/// The echo around it. Stroked rather than filled, and stroked on the
/// centre line the way the artwork's SVG does, so the ring lands in the
/// same place here as in the icon.
struct ChalantEchoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ring = ChalantMark.fitted(ChalantMark.ring, in: rect)
        return Path(roundedRect: ring, cornerRadius: ring.height / 2)
    }
}

/// The house mark: the island with an echo around it.
///
/// A View and not a Shape, because the echo is half opaque and the pill
/// is solid, and a single fill cannot say two things about opacity. The
/// old mark got away with one path because its eyes were holes.
struct ChalantMarkView: View {
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                // Both take the ambient foreground style, the way the
                // old single shape did, so every caller keeps tinting
                // the mark by setting its own foreground and nothing
                // has to learn a new parameter.
                ChalantEchoShape()
                    .stroke(
                        .foreground.opacity(ChalantMark.ringOpacity),
                        lineWidth: ChalantMark.scaled(ChalantMark.ringStroke, in: rect)
                    )
                ChalantPillShape().fill(.foreground)
            }
        }
    }
}
