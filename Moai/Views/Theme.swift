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
    /// Deliberately faint — findable, never announcing itself.
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
    static let textTertiary = Color.white.opacity(0.40)
    /// Meaningful guidance the user should be able to read: empty
    /// states, placeholders, footnotes. Brighter than tertiary.
    static let textHint = Color.white.opacity(0.48)
    /// Purely decorative marks — never carries information.
    static let textGhost = Color.white.opacity(0.28)

    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)

    /// Accent when nothing is playing: soft warm-white, near zero chroma.
    static let accentFallback = Color(hue: 0.6, saturation: 0.05, brightness: 0.82)

    // Fixed accent choices, pre-clamped to the same quiet range the
    // artwork extractor produces.
    static let accentBlue = Color(hue: 0.58, saturation: 0.42, brightness: 0.80)
    static let accentMint = Color(hue: 0.42, saturation: 0.38, brightness: 0.78)
    static let accentRose = Color(hue: 0.97, saturation: 0.42, brightness: 0.80)

    /// nil means "album" — follow the artwork-derived accent.
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
    /// `.system(size:)` directly — they pick a semantic role here.
    enum Fonts {
        static let micro = Font.system(size: 9, weight: .semibold)
        static let caption = Font.system(size: 10, weight: .medium)
        static let label = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let bodyEmphasis = Font.system(size: 12, weight: .semibold)
        static let title = Font.system(size: 13, weight: .semibold)
        /// Reading text: answers and the input line. Same size as
        /// title, regular weight — long text at semibold shouts.
        static let reading = Font.system(size: 13)
        static let numeral = Font.system(size: 20, weight: .semibold, design: .monospaced)
        static let display = Font.system(size: 30, weight: .semibold, design: .monospaced)

        // Monospaced variants, reserved for time and numbers.
        static let microMono = Font.system(size: 9, weight: .medium, design: .monospaced)
        static let captionMono = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let labelMono = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let bodyMono = Font.system(size: 12, design: .monospaced)
        static let bodyEmphasisMono = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let counterMono = Font.system(size: 15, weight: .semibold, design: .monospaced)

        /// SF Symbol sizing, one scale for every glyph in the app.
        enum IconScale: CGFloat {
            case xs = 9
            case s = 10
            case m = 12
            case l = 14
            case xl = 20
        }

        static func icon(_ scale: IconScale, weight: Font.Weight = .semibold) -> Font {
            .system(size: scale.rawValue, weight: weight)
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
        /// Collapsed wings sit flush against the physical notch.
        static let wingInset: CGFloat = 11
    }

    enum Radius {
        static let card: CGFloat = 12
        static let row: CGFloat = 10
        static let field: CGFloat = 12
        static let artwork: CGFloat = 8
    }

    /// Droplet silhouette parameters per island state.
    enum Island {
        static let eaveCollapsed: CGFloat = 12
        static let eaveExpanded: CGFloat = 22
        static let radiusCollapsed: CGFloat = 16
        static let radiusExpanded: CGFloat = 44
        static let bellyCollapsed: CGFloat = 1.5
        static let bellyExpanded: CGFloat = 10
    }

    /// Motion personality, user-selectable in settings. Serene is the
    /// default: glides and slow breath, never a visible bounce. Still
    /// is pure glass — no ambient motion at all.
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
        static var island: Animation {
            switch Feel.current {
            case .still: return .spring(response: 0.42, dampingFraction: 1.0)
            case .serene: return .spring(response: 0.45, dampingFraction: 0.92)
            case .balanced: return .spring(response: 0.40, dampingFraction: 0.86)
            case .lively: return .spring(response: 0.38, dampingFraction: 0.72)
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
            case .serene: return .smooth(duration: 0.32)
            case .balanced: return .snappy(duration: 0.25)
            case .lively: return .snappy(duration: 0.22)
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
}

// MARK: - Adaptive accent environment

private struct MoaiAccentKey: EnvironmentKey {
    static let defaultValue: Color = Theme.accentFallback
}

extension EnvironmentValues {
    /// The album-artwork-derived accent, kept quiet by AccentExtractor's
    /// saturation/brightness clamps. Injected once at the root.
    var moaiAccent: Color {
        get { self[MoaiAccentKey.self] }
        set { self[MoaiAccentKey.self] = newValue }
    }
}
