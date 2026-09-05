import SwiftUI

/// The whole design system: black, white, and four greys. The only accent
/// is white. Nothing here is ever red or blue.
enum Theme {
    static let bg = Color.black
    static let fg = Color.white
    /// Secondary text, timestamps.
    static let muted = Color(hex: 0x7A7A7A)
    /// Placeholders.
    static let faint = Color(hex: 0x444444)
    /// Search bar fill, pressed states.
    static let field = Color(hex: 0x1A1A1A)
    /// Row separators.
    static let rule = Color(hex: 0x222222)

    /// Horizontal page padding.
    static let pagePadding: CGFloat = 20
    /// Row vertical padding.
    static let rowPadding: CGFloat = 16
    /// Search bar height and corner radius.
    static let searchHeight: CGFloat = 44
    static let searchRadius: CGFloat = 12
    /// Compose button diameter.
    static let composeSize: CGFloat = 56
    /// Minimum tap target.
    static let tapTarget: CGFloat = 44

    enum Font {
        /// Screen title: 34pt semibold, tracking -0.03em.
        static let screenTitle = SwiftUI.Font.system(size: 34, weight: .semibold)
        static let screenTitleTracking: CGFloat = -0.03 * 34
        /// Note title in a row.
        static let rowTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// Row preview and time.
        static let rowBody = SwiftUI.Font.system(size: 15, weight: .regular)
        /// Labels and meta.
        static let label = SwiftUI.Font.system(size: 13, weight: .regular)
        /// Toolbar text buttons.
        static let toolbar = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// Editor body size and line height, as the spec states them.
        static let editorSize: CGFloat = 17
        static let editorLineHeight: CGFloat = 1.6
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
