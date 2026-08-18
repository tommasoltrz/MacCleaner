import SwiftUI

/// The design's type ramp.
///
/// Every numeric style is `.monospacedDigit()` at the point of definition rather
/// than at each call site. The handoff requires tabular figures throughout — "sizes
/// align in columns; without this they jitter as values update" — and a size readout
/// that shifts width while a scan runs is exactly the kind of detail that makes an
/// app read as a web page.
extension Font {

    /// 34pt — one per view, the capacity card's used figure.
    static let mcHero = Font.system(size: 34, weight: .semibold).monospacedDigit()
    /// 26pt — free space, Trash total.
    static let mcSecondaryHero = Font.system(size: 26, weight: .semibold).monospacedDigit()
    /// 22pt — stat tile values.
    static let mcStatValue = Font.system(size: 22, weight: .semibold).monospacedDigit()

    static let mcToolbarTitle = Font.system(size: 14, weight: .medium)

    /// The design specifies SF's 590 weight here, which is `.medium` — not semibold.
    static let mcRowTitle = Font.system(size: 13, weight: .medium)
    static let mcRowTitleRegular = Font.system(size: 13)
    static let mcRowValue = Font.system(size: 12.5).monospacedDigit()
    static let mcBody = Font.system(size: 12.5)
    static let mcControlLabel = Font.system(size: 12)
    static let mcSubtitle = Font.system(size: 11.5)
    static let mcCaption = Font.system(size: 11.5).monospacedDigit()

    static let mcMonoPath = Font.system(size: 11.5, design: .monospaced)
    static let mcMonoSmall = Font.system(size: 10.5, design: .monospaced)

    static let mcSectionHeader = Font.system(size: 12, weight: .medium)
    static let mcEyebrow = Font.system(size: 11, weight: .medium)
    static let mcColumnHeader = Font.system(size: 10.5, weight: .medium)
    static let mcBadge = Font.system(size: 10, weight: .medium)
    static let mcSidebarCount = Font.system(size: 11, weight: .medium).monospacedDigit()
}

extension View {
    /// Uppercase label with the design's letter-spacing, used for eyebrows, section
    /// headers and table column headers.
    func mcTracked(_ spacing: CGFloat) -> some View {
        self.tracking(spacing)
    }
}
