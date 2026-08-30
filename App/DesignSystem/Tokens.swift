import SwiftUI
import ScoloCore

/// Design tokens.
///
/// The handoff is explicit that platform semantics beat its literals: "prefer the
/// platform's semantic colors (`NSColor.controlAccentColor`, `.systemGreen`,
/// `.separatorColor`, `.quaternaryLabelColor`) over these literals where an
/// equivalent exists, so the app follows the user's accent choice and Increase
/// Contrast setting."
///
/// So almost everything here resolves to a system colour, and those adapt to the
/// user's appearance for free. What is left is a short list of literals with no
/// AppKit equivalent. Each of those now carries a pair: the design's authored dark
/// value, and a light value derived from it. The design was drawn dark and light is
/// read off it; the system decides which one the user sees.
enum Token {

    // MARK: - Appearance

    /// A colour that answers differently in each appearance.
    ///
    /// `Color(nsColor:)` preserves an `NSColor`'s dynamism, so one token can hold both
    /// values and no view has to know which mode it is drawing in.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The shape almost every literal below takes: the same mark in the opposite ink.
    /// White at some alpha over dark, black at some alpha over light.
    ///
    /// The two alphas are paired, not shared. Equal alphas do not read as equal
    /// weight, so each side is set against the surface it actually lands on.
    static func ink(light: CGFloat, dark: CGFloat) -> Color {
        dynamic(
            light: .black.withAlphaComponent(light),
            dark: .white.withAlphaComponent(dark)
        )
    }

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
        case .brown:     Color(nsColor: .systemBrown)
        case .gray:      Color(nsColor: .systemGray)

        // No AppKit equivalent for these three — kept as design literals, so they are
        // also the only category colours that need a light value drawn by hand.
        //
        // All three share a track with `systemGray`, which is #8E8E93 in light and
        // #98989D in dark, so the light values are chosen for separation from it as
        // much as for fidelity to the dark ones.

        // System Data. Warm taupe, and in light it has to go darker than `systemGray`
        // rather than lighter: the two sit next to each other at the head of the bar.
        case .warmGray:  dynamic(
            light: NSColor(srgbRed: 0.435, green: 0.392, blue: 0.333, alpha: 1),  // #6F6455
            dark:  NSColor(srgbRed: 0.557, green: 0.522, blue: 0.467, alpha: 1)   // #8E8577
        )

        // Unmeasured. The honest residual, so it stays quiet — which in dark means
        // near the background and in light means a mid grey, not a dark one. It has
        // to stay legible between `Other` (`systemGray`) on one side and `Free` on
        // the other, and #9E9E9E was too close to `systemGray` light to tell apart,
        // so it sits a little above the midpoint of that pair.
        case .darkGray:  dynamic(
            light: NSColor(srgbRed: 0.659, green: 0.659, blue: 0.678, alpha: 1),  // #A8A8AD
            dark:  NSColor(srgbRed: 0.290, green: 0.290, blue: 0.306, alpha: 1)   // #4A4A4E
        )

        // Free. A tint of the surface either way, since empty space should read as
        // the track rather than as another category.
        case .freeSpace: ink(light: 0.10, dark: 0.14)
        }
    }

    /// The same palette, for a colour that has to be *read* rather than filled.
    ///
    /// The system colours are tuned to be filled. `systemGreen` on light paper is
    /// about 1.6:1 and `systemOrange` about 1.9:1 — figures you can see but not read,
    /// which is fine for a 9pt dot and not fine for the free-space total or a badge.
    /// Dark does not have the problem, since the same colours sit against a dark
    /// surface, so this hands back the system colour there and a darkened shade of the
    /// same hue in light.
    ///
    /// Shapes keep `color(_:)`. Dots, bars, capsule fills and the capacity bar are
    /// what the system palette is for, and swapping them would break the match between
    /// a legend dot and its segment.
    static func textColor(_ token: ColorToken) -> Color {
        switch token {
        case .green:  dynamic(
            light: NSColor(srgbRed: 0.078, green: 0.404, blue: 0.165, alpha: 1),  // #14672A
            dark: .systemGreen
        )
        case .orange: dynamic(
            light: NSColor(srgbRed: 0.604, green: 0.325, blue: 0.000, alpha: 1),  // #9A5300
            dark: .systemOrange
        )
        case .red:    dynamic(light: redInk, dark: .systemRed)
        // Accent stays the accent. A label in the user's chosen colour is what the
        // sidebar and the selection readout are saying, and macOS draws those the same
        // way at the same contrast.
        default:      color(token)
        }
    }

    /// One dark red for light mode, shared by `textColor(.red)` and the destructive
    /// control's label so the app has a single red to read.
    fileprivate static let redInk = NSColor(srgbRed: 0.702, green: 0.149, blue: 0.118, alpha: 1)  // #B3261E

    // MARK: - Text.

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
    ///
    /// Light inherits the argument, not the numbers. AppKit's light ramp is black at
    /// 0.50, 0.26 and 0.10 for the bottom three steps, so the two that were the
    /// problem in dark are again set well clear of the platform's. The pairs are not
    /// mirrored — equal alphas do not read as equal weight — so each side is set
    /// against its own surface.
    enum Text {
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Token.ink(light: 0.60, dark: 0.62)
        static let tertiary = Token.ink(light: 0.55, dark: 0.52)
        static let quaternary = Token.ink(light: 0.48, dark: 0.44)
        static let disabled = Token.ink(light: 0.34, dark: 0.34)
        /// The one hero number per view. A step past `labelColor`, which is 0.85 in
        /// both modes.
        static let emphasis = Token.ink(light: 0.92, dark: 0.96)

        /// The destructive control's label, on its own red-tinted fill.
        ///
        /// `systemRed` itself cannot do this job in either mode: it is too dark to
        /// carry a label on the dark tint and too light to carry one on the light
        /// tint. So the label gets a shade of red per appearance instead — the dark
        /// one is the design's #FF7A70, the light one the same red every other red
        /// label uses.
        static let destructive = Token.dynamic(
            light: Token.redInk,
            dark: NSColor(srgbRed: 1.000, green: 0.478, blue: 0.439, alpha: 1)   // #FF7A70
        )

        /// A label sitting on a highlighted menu row. `selectedMenuItemTextColor`
        /// is the one AppKit token that tracks the highlight fill: it is white
        /// while a row is filled and reverts if the system ever draws that fill
        /// lighter, which is more than a white literal would do.
        static let onHighlight = Color(nsColor: .selectedMenuItemTextColor)
    }

    static let separator = Color(nsColor: .separatorColor)

    /// The content area behind the cards. The detail pane's own background is white
    /// in light mode, which left white cards invisible on it. Light paints the
    /// System Settings grey so the cards stand off the page. Dark used to stay
    /// clear, but the bare window material lightens to #302D31 whenever the window
    /// is key, washing the page out next to the App Store and Finder — both paint
    /// an opaque canvas that holds still. This is the App Store's, as measured.
    static let pageBackground = Token.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),  // #F2F2F4
        dark: NSColor(srgbRed: 0.141, green: 0.129, blue: 0.145, alpha: 1)    // #242125
    )

    // MARK: - Fills
    //
    // Low-alpha tints with no AppKit name. Kept as constants so no view carries a
    // magic number.
    //
    // Dark lifts a surface with white; light seats it with black. The exception is
    // `well`, which is black in both — a recess reads as darker than what surrounds
    // it whichever way round the window is.

    enum Fill {
        /// Dark lifts the card off the window with white at low alpha. Light goes the
        /// other way, like System Settings: a white card on the grey window. Slightly
        /// translucent so a wallpaper-tinted window shows through the card faintly.
        static let box = Token.dynamic(
            light: .white.withAlphaComponent(0.85),
            dark: .white.withAlphaComponent(0.045)
        )
        /// Also the row rule in every table and the capacity bar's track. Deliberately
        /// weaker than `separatorColor`, which is roughly 0.10 in light: repeated every
        /// 38pt down a table, the system separator draws a grid rather than a hint.
        static let boxBorder = Token.ink(light: 0.06, dark: 0.07)
        /// The specular top edge on a secondary button. In light there is no specular
        /// edge to draw, so it becomes the outline that makes the control look raised,
        /// and it needs more weight than the box hairline to do that.
        static let controlBorder = Token.ink(light: 0.13, dark: 0.10)
        static let well = Token.dynamic(
            light: .black.withAlphaComponent(0.04),
            dark: .black.withAlphaComponent(0.22)
        )
        static let control = Token.ink(light: 0.07, dark: 0.09)
        /// Hover darkens the control in light and lightens it in dark. Same gesture,
        /// opposite direction, which is what `ink` already does.
        static let controlHover = Token.ink(light: 0.12, dark: 0.14)
        static let rowHover = Token.ink(light: 0.04, dark: 0.03)
        // Light matches the App Store's pill: about 4% black over the sidebar
        // material, a hint rather than a block. Dark matches Finder's selected pill
        // (#2F2C2F) as a solid: as an ink over the translucent sidebar it
        // composited to #3C3B3E and drifted with whatever sat behind the window.
        static let sidebarSelection = Token.dynamic(
            light: NSColor.black.withAlphaComponent(0.045),
            dark: NSColor(srgbRed: 47 / 255, green: 44 / 255, blue: 47 / 255, alpha: 1)  // #2F2C2F
        )
        /// The selected row's label and icon. Not a system token: the App Store
        /// pill this is modelled on paints its selection with a wide-gamut blue —
        /// measured P3 #1891FF on screen, beyond what sRGB `systemBlue` (P3
        /// #3F8EF7) can reach — so only a P3 literal matches it. Light keeps
        /// `systemBlue`: the vivid variant is tuned for the dark material.
        static let sidebarSelectedTint = Token.dynamic(
            light: .systemBlue,
            dark: NSColor(displayP3Red: 0.094, green: 0.569, blue: 1.0, alpha: 1)
        )

        /// The fill under the pointer in the menu bar popover — the same blue a
        /// real `NSMenu` row takes. `selectedContentBackgroundColor` is that
        /// exact colour and it follows the user's accent choice, so a Mac set to
        /// Graphite gets grey here rather than a blue the rest of the system
        /// stopped using. The sidebar's P3 literal is not reused: that one was
        /// measured to match the App Store's *tint on a pill*, not a menu's fill.
        static let menuHighlight = Color(nsColor: .selectedContentBackgroundColor)
    }

    /// The drop shadow under a floating chip — the capacity bar's tooltip and the
    /// proportion bar's. Dark needs a deep shadow to lift the chip off the surface
    /// below it. Light needs a fraction of that, or the chip reads as hovering an
    /// inch above the page.
    static let chipShadow = Token.dynamic(
        light: .black.withAlphaComponent(0.18),
        dark: .black.withAlphaComponent(0.40)
    )

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
        /// The design's window size. Resizable; the sidebar stays fixed.
        static let windowWidth: CGFloat = 1268
        static let windowHeight: CGFloat = 734
        /// Below roughly this, the tables crowd.
        static let minimumContentWidth: CGFloat = 760
    }

    /// Hairlines are 0.5px in the design — one physical pixel on a Retina display.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
}
