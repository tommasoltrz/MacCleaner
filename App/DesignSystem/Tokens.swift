import SwiftUI
import MacCleanerCore

/// Design tokens.
///
/// The handoff is explicit that platform semantics beat its literals: "prefer the
/// platform's semantic colors (`NSColor.controlAccentColor`, `.systemGreen`,
/// `.separatorColor`, `.quaternaryLabelColor`) over these literals where an
/// equivalent exists, so the app follows the user's accent choice and Increase
/// Contrast setting."
///
/// So almost everything here resolves to a system colour. Only three category
/// colours have no AppKit equivalent and are kept as literals.
enum Token {

    // MARK: - Category colours

    static func color(_ token: ColorToken) -> Color {
        switch token {
        // Follows the user's accent selection in System Settings.
        case .accent:    Color(nsColor: .controlAccentColor)
        case .green:     Color(nsColor: .systemGreen)
        case .orange:    Color(nsColor: .systemOrange)
        case .red:       Color(nsColor: .systemRed)
        case .yellow:    Color(nsColor: .systemYellow)
        case .purple:    Color(nsColor: .systemPurple)
        case .teal:      Color(nsColor: .systemTeal)
        case .pink:      Color(nsColor: .systemPink)
        case .gray:      Color(nsColor: .systemGray)
        // No AppKit equivalent for these three — kept as design literals.
        case .warmGray:  Color(red: 0.557, green: 0.522, blue: 0.467)   // #8E8577
        case .darkGray:  Color(red: 0.290, green: 0.290, blue: 0.306)   // #4A4A4E
        case .freeSpace: Color.white.opacity(0.14)
        }
    }

    // MARK: - Text

    /// The text ramp.
    ///
    /// The top two steps use AppKit semantics, which match the design closely and
    /// respond to Increase Contrast. The bottom two do not: AppKit's
    /// `tertiaryLabelColor` and `quaternaryLabelColor` sit near 0.25 and 0.10 alpha,
    /// well below the design's 0.42 and 0.34, and on a dark translucent surface they
    /// were genuinely hard to read — eyebrows, tile descriptions and the status bar
    /// all disappeared. Those two are explicit values, set slightly brighter than the
    /// design's own, since the prototype was measured against an opaque mock rather
    /// than live window glass.
    enum Text {
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.52)
        static let quaternary = Color.white.opacity(0.44)
        static let disabled = Color.white.opacity(0.34)
        /// The one hero number per view.
        static let emphasis = Color.white.opacity(0.96)
    }

    static let separator = Color(nsColor: .separatorColor)

    // MARK: - Fills
    //
    // Low-alpha whites with no AppKit name. Kept as constants so no view carries a
    // magic number.

    enum Fill {
        static let box = Color.white.opacity(0.045)
        static let boxBorder = Color.white.opacity(0.07)
        static let well = Color.black.opacity(0.22)
        static let control = Color.white.opacity(0.09)
        static let controlHover = Color.white.opacity(0.14)
        static let rowHover = Color.white.opacity(0.03)
        static let sidebarSelection = Color.white.opacity(0.13)
    }

    // MARK: - Geometry

    enum Radius {
        static let dot: CGFloat = 2.5
        static let checkbox: CGFloat = 4
        static let control: CGFloat = 6
        static let row: CGFloat = 7
        static let well: CGFloat = 8
        static let box: CGFloat = 10
        static let card: CGFloat = 11
        static let window: CGFloat = 12
    }

    enum Size {
        static let toolbar: CGFloat = 52
        static let statusBar: CGFloat = 46
        static let sidebarWidth: CGFloat = 218
        static let sidebarRow: CGFloat = 28
        static let control: CGFloat = 24
        static let fileRow: CGFloat = 38
        static let largeFileRow: CGFloat = 36
        static let trashRow: CGFloat = 40
        static let capacityBar: CGFloat = 13
        static let proportionBar: CGFloat = 5

        /// The design's window size. Resizable; the sidebar stays fixed.
        static let windowWidth: CGFloat = 1268
        static let windowHeight: CGFloat = 734
        /// Below roughly this, the tables crowd.
        static let minimumContentWidth: CGFloat = 760
    }

    /// Hairlines are 0.5px in the design — one physical pixel on a Retina display.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
}
