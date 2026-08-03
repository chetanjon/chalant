import AppKit
import SwiftUI

/// Quiet premium: near-black glass, hairline edges, soft white text,
/// and one restrained accent that follows the current album artwork.
enum Theme {
    // MARK: Surfaces

    static let backdropTop = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let backdropBottom = Color(red: 0.024, green: 0.024, blue: 0.031)

    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [backdropTop, backdropBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Cards and strips sitting on the backdrop.
    static let surface = Color.white.opacity(0.05)
    /// Text fields, slightly brighter than cards.
    static let field = Color.white.opacity(0.07)
    /// The island's glass edge.
    static let hairline = Color.white.opacity(0.10)
    /// Strokes on interior cards.
    static let hairlineFaint = Color.white.opacity(0.06)

    /// Top-lit edge for the island: brighter where light would catch it.
    static var specularEdge: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Bottom-lit lip so the collapsed droplet reads against the pure
    /// black strip of fullscreen apps; strongest where the belly hangs.
    /// Deliberately faint, findable, never announcing itself.
    static var lipLight: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0), Color.white.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Text hierarchy

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    // Raised 2026-07-21: the quiet tiers were disappearing on dimmed
    // screens; legible-at-medium-brightness is the floor now.
    static let textTertiary = Color.white.opacity(0.50)
    /// Meaningful guidance the user should be able to read: empty
    /// states, placeholders, footnotes. Brighter than tertiary.
    static let textHint = Color.white.opacity(0.56)
    /// Purely decorative marks, never carries information.
    // Raised 2026-07-31, the tier the 07-21 pass missed: at 0.38 this
    // computed to roughly 3.6:1 on the backdrop, under the 4.5:1 floor,
    // so every mark wearing it was below the bar the other quiet tiers
    // were already lifted to meet. 0.45 clears it while staying a step
    // under tertiary, so the hierarchy still reads.
    static let textGhost = Color.white.opacity(0.45)

    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
    /// A status reading as healthy rather than merely quiet: the Stop
    /// hook installed, a check passing. Grey never says "this is fine,"
    /// it says "nothing to report" (founder, 2026-08-02: "use the green
    /// fill... to show proper usage").
    static let positive = Color(red: 0.45, green: 0.85, blue: 0.55)

    /// Accent when nothing is playing: soft warm-white, near zero chroma.
    static let accentFallback = Color(hue: 0.6, saturation: 0.05, brightness: 0.82)

    // Fixed accent choices, pre-clamped to the same quiet range the
    // artwork extractor produces.
    static let accentBlue = Color(hue: 0.58, saturation: 0.42, brightness: 0.80)
    static let accentMint = Color(hue: 0.42, saturation: 0.38, brightness: 0.78)
    static let accentRose = Color(hue: 0.97, saturation: 0.42, brightness: 0.80)

    /// nil means "album", follow the artwork-derived accent.
    static func fixedAccent(for mode: String) -> Color? {
        switch mode {
        case "silver": return accentFallback
        case "blue": return accentBlue
        case "mint": return accentMint
        case "rose": return accentRose
        default: return nil
        }
    }

    // MARK: Scales

    /// The one place type sizes live. Views never call
    /// `.system(size:)` directly, they pick a semantic role here.
    enum Fonts {
        static let micro = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 12, weight: .medium)
        static let label = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 14)
        static let bodyMedium = Font.system(size: 14, weight: .medium)
        static let bodyEmphasis = Font.system(size: 14, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
        /// A window's own page title. The island has no room for this
        /// tier; the dashboard is the first surface with the space to
        /// say where you are before it says anything else.
        static let heading = Font.system(size: 24, weight: .semibold)
        /// Reading text: answers and the input line. Same size as
        /// title, regular weight, long text at semibold shouts.
        static let reading = Font.system(size: 15)
        static let numeral = Font.system(size: 22, weight: .semibold, design: .monospaced)
        static let display = Font.system(size: 32, weight: .semibold, design: .monospaced)

        // Monospaced variants, reserved for time and numbers.
        static let microMono = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let captionMono = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let labelMono = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let bodyMono = Font.system(size: 14, design: .monospaced)
        static let bodyEmphasisMono = Font.system(size: 14, weight: .semibold, design: .monospaced)
        static let counterMono = Font.system(size: 17, weight: .semibold, design: .monospaced)

        /// SF Symbol sizing, one scale for every glyph in the app.
        enum IconScale: CGFloat {
            case xs = 11
            case s = 12
            case m = 14
            case l = 16
            case xl = 22
        }

        static func icon(_ scale: IconScale, weight: Font.Weight = .semibold) -> Font {
            .system(size: scale.rawValue, weight: weight)
        }

        /// The same weight convention, for the rare glyph whose size has
        /// to track a caller-supplied dimension rather than sit on the
        /// fixed scale above (the agent mark, matched to its row's own
        /// height). Routing it through here still means one place sets
        /// the weight, rather than a bare `.system(size:)` reinventing it.
        static func icon(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight)
        }
    }

    /// Spacing rhythm. Named exceptions live here too, so a raw
    /// number in a view is always a bug.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 22
        /// Tight icon-to-label and dot gaps.
        static let snug: CGFloat = 5
        /// Collapsed wings sit flush against the physical notch.
        // 7, not 11: the pill's 8pt width tuck (worn by the glass, not
        // the report) took 4 from each wing; the inset gives it back
        // so timer digits and the wave never slide under the camera
        // (user, 2026-07-22, "the timer is cut off"). The tuck itself
        // is no longer unconditional — a flush, quiet island on real
        // hardware carries neither it nor this inset (W-C, 2026-08-02)
        // — but wherever the tuck still applies, this is still its
        // remainder.
        static let wingInset: CGFloat = 7
        /// Room below the notch's own reserved strip, wherever content
        /// has to clear it: the listening caption, its close button,
        /// and the expanded island's first row each wrote their own
        /// number for the identical job (8, 6 and 4), and the
        /// founder's complaint that content sits too close to the top
        /// edge landed on the tightest of the three (EC-14, 2026-08-02).
        static let notchClearance: CGFloat = l
    }

    enum Radius {
        static let card: CGFloat = 12
        static let row: CGFloat = 10
        static let field: CGFloat = 12
        static let artwork: CGFloat = 10
        /// Small inline thumbnails (clipboard shots).
        static let thumb: CGFloat = 6
    }

    /// Droplet silhouette parameters per island state.
    enum Island {
        static let eaveCollapsed: CGFloat = 12
        static let eaveExpanded: CGFloat = 22
        static let radiusCollapsed: CGFloat = 16
        // 44/10 read as a long empty chin under the last row; the
        // droplet keeps a hint of belly without the sag.
        static let radiusExpanded: CGFloat = 34
        /// Flat, both of them. The bottom edge used to bow below
        /// straight, a point and a half at rest and five when open, as
        /// a droplet flourish. The founder read it as a fault twice,
        /// once as "remove the slight arc at the bottom, make it clean"
        /// and once as "a small bend to the line, the line is not
        /// normal", which is the answer: a long horizontal edge is
        /// exactly where the eye measures straightness, and a five
        /// point sag across an expanded island is not subtle there
        /// (2026-08-02).
        ///
        /// Kept as named constants rather than deleted so the curve is
        /// one number away if it is ever wanted back, and so the eave
        /// keeps its own separate say.
        static let bellyCollapsed: CGFloat = 0
        static let bellyExpanded: CGFloat = 0
        /// The song title beside the wave on a quiet pill: one number
        /// for how much width is reserved and how much is drawn.
        /// `leftWingNeed` used to reserve 156 while `songBeside` drew
        /// at most 140, leaving 16pt of the wing reserved and empty on
        /// every display playing music (EC-13, 2026-08-02).
        static let songGlanceWidth: CGFloat = 140
    }

    /// Fixed lower-panel heights, one deliberate scale instead of
    /// numbers scattered through ExpandedView.
    enum Panel {
        /// Shortcuts, clipboard, and shelf lists.
        static let list: CGFloat = 230
        /// Focus pane, sized to fit presets, the daily goal row, and
        /// the week of stats.
        static let focus: CGFloat = 280
        /// Battery: charge, state, time remaining, and health when
        /// known. Shorter than focus, it has no equivalent to the
        /// week-of-bars block.
        static let battery: CGFloat = 190
        /// Chat pane heights. Compact trims the dead space the page's
        /// vertical centering leaves under the input; full keeps the
        /// room the sidebar layout earns.
        static let chat: CGFloat = 330
        static let chatFull: CGFloat = 390
    }

    /// Motion personality, user-selectable in settings. Serene is the
    /// default: glides and slow breath, never a visible bounce. Still
    /// is pure glass, no ambient motion at all.
    enum Feel: String {
        case still, serene, balanced, lively

        static var current: Feel {
            // The system accessibility setting wins over the user's
            // in-app choice: Reduce Motion means still glass, period.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                return .still
            }
            return Feel(rawValue: UserDefaults.standard.string(forKey: "motionFeel") ?? "")
                ?? .serene
        }

        /// Ambient effects (aurora, glow, sweep, glyph shimmer) run at all.
        var ambient: Bool { self != .still }
    }

    enum Motion {
        /// The open and close of the island itself. Slower and more
        /// damped than the inner content on every tier: the shell
        /// should bloom, never pop (user call, 2026-07-21).
        static var island: Animation {
            switch Feel.current {
            case .still: return .spring(response: 0.50, dampingFraction: 1.0)
            case .serene: return .spring(response: 0.56, dampingFraction: 0.95)
            case .balanced: return .spring(response: 0.52, dampingFraction: 0.92)
            case .lively: return .spring(response: 0.46, dampingFraction: 0.80)
            }
        }

        static var hover: Animation {
            switch Feel.current {
            case .still: return .spring(response: 0.30, dampingFraction: 1.0)
            case .serene: return .spring(response: 0.30, dampingFraction: 0.90)
            case .balanced: return .spring(response: 0.26, dampingFraction: 0.80)
            case .lively: return .spring(response: 0.26, dampingFraction: 0.70)
            }
        }

        static var content: Animation {
            switch Feel.current {
            case .still: return .smooth(duration: 0.28)
            case .serene: return .smooth(duration: 0.34)
            case .balanced: return .smooth(duration: 0.30)
            case .lively: return .snappy(duration: 0.24)
            }
        }

        static let accent = Animation.easeInOut(duration: 1.0)

        /// Ambient loops (aurora drift, glow breath) stretch by this factor.
        static var ambientSlow: Double {
            switch Feel.current {
            case .still: return 2.0
            case .serene: return 1.6
            case .balanced: return 1.0
            case .lively: return 0.8
            }
        }
    }

    /// Holding the notch this long starts listening; shorter is a tap.
    static let pressToTalkDelay: TimeInterval = 0.32

    // MARK: Liquid glass (the material/clarity dial)

    /// How see-through the shell's real Liquid Glass reads (the
    /// user's own clarity dial), and how much ink still sits over it
    /// once bloomed open. Both floor above true zero on purpose: at
    /// full "clear," a bright desktop behind the island can push the
    /// island's own text under a readable contrast, and the glance is
    /// the one surface here that can never lose that fight (founder:
    /// "a material that makes text harder to read has failed no
    /// matter how good the still frame looks"). The one place both
    /// numbers live, so nothing computes its own competing floor.
    static func glassTint(for clarity: String) -> Double {
        switch clarity {
        case "veiled": return 0.35
        case "clear": return 0.10
        default: return 0.18
        }
    }

    static func glassSmoke(for clarity: String) -> Double {
        switch clarity {
        case "veiled": return 0.12
        case "clear": return 0.04
        default: return 0.06
        }
    }
}

// MARK: - Adaptive accent environment

private struct ChalantAccentKey: EnvironmentKey {
    static let defaultValue: Color = Theme.accentFallback
}

extension EnvironmentValues {
    /// The album-artwork-derived accent, kept quiet by AccentExtractor's
    /// saturation/brightness clamps. Injected once at the root.
    var chalantAccent: Color {
        get { self[ChalantAccentKey.self] }
        set { self[ChalantAccentKey.self] = newValue }
    }
}
