import SwiftUI
import MacCleanerCore

// MARK: - Grouped box

/// The design's grouped box: a rounded, hairline-bordered container.
///
/// Deliberately not `GroupBox`. The stock control draws its own title area and
/// padding, which fights every layout here; the design's box is a plain surface.
struct GroupedBox<Content: View>: View {
    var radius: CGFloat = Token.Radius.box
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
            )
    }
}

/// A recessed well — expanded table bodies, callouts, the exclusion list.
struct Well<Content: View>: View {
    var radius: CGFloat = Token.Radius.well
    @ViewBuilder var content: Content

    var body: some View {
        content.background(Token.Fill.well, in: RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Small parts

/// The 9pt rounded square identifying a category, matching its capacity-bar segment.
struct CategoryDot: View {
    let color: ColorToken
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.dot)
            .fill(Token.color(color))
            .frame(width: size, height: size)
    }
}

struct Badge: View {
    enum Style { case neutral, safe }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.mcBadge)
            // The label is read, so it takes the readable green; the capsule behind it
            // is a fill and keeps the system one.
            .foregroundStyle(style == .safe ? Token.textColor(.green) : Token.Text.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                style == .safe
                    ? Token.color(.green).opacity(0.16)
                    : Token.Fill.control,
                in: Capsule()
            )
    }
}

/// Horizontal bar showing one category's share of the largest category.
struct ProportionBar: View {
    let fraction: Double
    let color: ColorToken
    var width: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Token.Fill.control)
                Capsule()
                    .fill(Token.color(color))
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: width, height: Token.Size.proportionBar)
    }
}

// MARK: - Button styles

/// A sidebar row: the label, and nothing else.
///
/// `.buttonStyle(.plain)` fades its label while the mouse is held down. No Mac source
/// list does that — press a row in Finder and the only thing that moves is the
/// selection. The moving pill is the whole feedback here, so this style reads
/// `configuration.isPressed` nowhere.
///
/// The row's other half of the fix lives at the call site: the selection is made on
/// mouse *down*, because a `Button` alone acts on mouse up and the delay reads as lag.
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Secondary button — the design's gradient-filled control with a specular top edge.
struct SecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel)
            .foregroundStyle(Token.Text.primary)
            .padding(.horizontal, 12)
            .frame(height: Token.Size.control)
            .background(
                isHovering ? Token.Fill.controlHover : Token.Fill.control,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.Fill.controlBorder, lineWidth: Token.hairline)
            )
            // Pressing darkens in both appearances. In light that is the platform's
            // own pressed state; in dark it is the design's.
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = $0 }
    }
}

/// Destructive button — red at low alpha with a tinted label, per the design's
/// Empty Trash and Reset controls.
struct DestructiveButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel.weight(.medium))
            .foregroundStyle(Token.Text.destructive)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                Token.color(.red).opacity(isHovering ? 0.26 : 0.16),
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.color(.red).opacity(0.40), lineWidth: Token.hairline)
            )
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Hover tip

/// The capacity bar's immediate tooltip, as a reusable chip. The native `.help()`
/// waits out a dwell delay and only fires on the key window; a bar the user is
/// already pointing at should answer at once.
struct HoverTip: View {
    var color: ColorToken?
    let primary: String
    var secondary: String?

    var body: some View {
        HStack(spacing: 7) {
            if let color { CategoryDot(color: color, size: 8) }
            Text(primary)
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
            if let secondary {
                Text(secondary)
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Token.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
        .shadow(color: Token.chipShadow, radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Sortable column header

/// A column label that sorts the list beneath it, Finder-style: click to adopt the
/// column, click again to flip direction. The arrow appears only on the active
/// column. Typography and casing come from the surrounding header row, so this
/// composes with each table's existing style.
struct SortableColumnHeader: View {
    let title: String
    let isActive: Bool
    let ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Reverse the sort order" : "Sort by \(title.lowercased())")
    }
}

// MARK: - Rows

/// Applies the design's hover fill to a list row.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 0
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? Token.Fill.rowHover : .clear,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 0) -> some View {
        modifier(HoverHighlight(radius: radius))
    }

    /// Uppercased, tracked, quaternary — eyebrows and column headers.
    func mcEyebrowStyle(tracking: CGFloat = 0.055 * 11) -> some View {
        self.font(.mcEyebrow)
            .tracking(tracking)
            .textCase(.uppercase)
            .foregroundStyle(Token.Text.quaternary)
    }
}
