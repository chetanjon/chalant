import SwiftUI

/// Whose session a row belongs to.
///
/// Every mark is drawn here rather than at the call sites, so replacing
/// one with a real bundled asset is a change to this file alone. The
/// Claude burst below is a hand-drawn approximation of Anthropic's mark,
/// not the artwork itself — recognisable as the family, and honest about
/// being a stand-in until the real thing is dropped in.
struct AgentMark: View {
    let agent: SessionStore.Agent
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch agent {
            case .claude:
                ClaudeBurstShape()
            case .cursor:
                // Cursor's own logo is a prism this has no faithful way
                // to draw, so this is plainly a pointer rather than a
                // bad copy of their mark.
                Image(systemName: "cursorarrow")
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.label)
        .help(agent.label)
    }
}

/// A radiating burst: tapered rays around a small hub.
struct ClaudeBurstShape: Shape {
    var rays: Int = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let hub = outer * 0.16
        // Rays are wider where they meet the hub than at the rim, which
        // is what stops the shape reading as a plain asterisk.
        let spread = (.pi / CGFloat(rays)) * 0.62

        func point(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        }

        for index in 0..<rays {
            let angle = (2 * .pi / CGFloat(rays)) * CGFloat(index) - .pi / 2
            path.move(to: point(angle - spread, hub))
            path.addLine(to: point(angle - spread * 0.34, outer))
            path.addLine(to: point(angle + spread * 0.34, outer))
            path.addLine(to: point(angle + spread, hub))
            path.closeSubpath()
        }
        // Fills the gap the rays leave between them at the centre.
        path.addEllipse(in: CGRect(
            x: centre.x - hub * 1.3, y: centre.y - hub * 1.3,
            width: hub * 2.6, height: hub * 2.6
        ))
        return path
    }
}
