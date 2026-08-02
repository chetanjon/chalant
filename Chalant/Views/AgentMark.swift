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
    /// What the session is doing, which this mark now says on its own.
    ///
    /// Three readings, and nothing else beside it: turning while the
    /// agent is mid-turn, coloured and still while it waits at its
    /// prompt, drained of colour once it is gone. A pair of rings used
    /// to sit next to this saying the same thing again, and a second
    /// mark that restates the first is furniture (founder, 2026-08-02).
    ///
    /// nil where there is no session to describe, such as the glance's
    /// standing Claude mark.
    var state: SessionStore.State?

    /// Anthropic's own terracotta rather than the ambient text tint.
    /// A Claude session is the one row on the island that belongs to
    /// somebody else's brand, and it should read as theirs.
    static let claudeColour = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// Mid-turn, and therefore moving.
    private var turning: Bool { state == .working }

    /// Still a process somebody could reach. `needsInput` and `idle`
    /// are both alive and both wear the colour; only the animation
    /// tells them from a session that is working.
    private var alive: Bool {
        switch state {
        case .working, .needsInput, .idle: return true
        case .stale, .done, .failed: return false
        case nil: return true
        }
    }

    private var stateLabel: String {
        switch state {
        case .working: return "\(agent.label), working"
        case .needsInput: return "\(agent.label), waiting for you"
        case .idle: return "\(agent.label), waiting at its prompt"
        case .stale, .done, .failed: return "\(agent.label), ended"
        case nil: return agent.label
        }
    }

    var body: some View {
        Group {
            switch agent {
            case .claude:
                Group {
                    if turning, Theme.Feel.current.ambient {
                        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let turn = t.truncatingRemainder(dividingBy: 8) / 8
                            ClaudeBurstShape()
                                .rotationEffect(.degrees(turn * 360))
                                .scaleEffect(0.9 + 0.1 * (0.5 + 0.5 * sin(t / 0.7)))
                        }
                    } else {
                        ClaudeBurstShape()
                    }
                }
                // Only Claude's mark takes a colour of its own; Cursor's
                // keeps whatever tint the row hands down, so a row that
                // dims still dims. A session that has gone gives its
                // colour up: the row is history at that point, and
                // history should not be the brightest thing on screen.
                .foregroundStyle(alive ? Self.claudeColour : Theme.textTertiary)
            case .cursor:
                // Cursor's own logo is a prism this has no faithful way
                // to draw, so this is plainly a pointer rather than a
                // bad copy of their mark.
                Image(systemName: "cursorarrow")
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(stateLabel)
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
