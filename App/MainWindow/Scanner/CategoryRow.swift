import SwiftUI
import MacCleanerCore

/// One category's collapsed row in the Scanner outline.
///
/// Left to right: disclosure triangle, category dot, title block, value block. The
/// whole row is one hit target — the design wants clicking anywhere to expand, the
/// way an outline view row behaves, not just the triangle. Category proportions live
/// in the Scanner's single composition bar rather than being renormalised per row.
///
/// Half the Scanner screen is rows that cannot be acted on, and the design is explicit
/// about how they read: the *whole row* drops to 50% opacity rather than the text being
/// recoloured, and the triangle, the bar and the selection readout all go away. A
/// dimmed row with a triangle still on it would promise something it cannot do.
struct CategoryRow: View {
    let result: ScanCategoryResult
    let isExpanded: Bool
    let selectedBytes: Int64
    let onToggle: () -> Void

    private enum Metrics {
        static let gap: CGFloat = 11
        static let sidePadding: CGFloat = 15
        static let verticalPadding: CGFloat = 12
        /// Kept even when there is no triangle to draw, so titles line up down the
        /// column whether or not a category can be opened.
        static let triangleSlot: CGFloat = 11
        static let badgeGap: CGFloat = 7
        /// Fixed, so the totals form a right-aligned column; the title block takes all
        /// the growth when the window widens.
        static let valueWidth: CGFloat = 96
    }

    private var category: CategoryID { result.categoryID }

    /// `.empty` and `.unavailable` categories are inert: nothing to open, nothing to
    /// select. The entries check is belt and braces — a category that measured
    /// something but produced no rows would otherwise offer an expansion into nothing.
    private var isActionable: Bool {
        result.availability.isActionable && !result.entries.isEmpty
    }

    var body: some View {
        if isActionable {
            Button(action: onToggle) { rowContent }
                .buttonStyle(.plain)
                .hoverHighlight()
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        } else {
            rowContent
                .opacity(0.5)
                .accessibilityElement(children: .combine)
        }
    }

    private var rowContent: some View {
        HStack(spacing: Metrics.gap) {
            disclosureTriangle
            CategoryDot(color: category.color)
            titleBlock

            valueBlock
        }
        .padding(.horizontal, Metrics.sidePadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Disclosure

    @ViewBuilder
    private var disclosureTriangle: some View {
        // The slot is reserved either way; only the glyph is conditional.
        Group {
            if isActionable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Token.Text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Carried here rather than left to the caller's transaction so the
                    // triangle turns at the Dashboard's speed whoever flips the flag.
                    // SwiftUI's default curve runs ~0.35s, which drags for a disclosure.
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
            }
        }
        .frame(width: Metrics.triangleSlot, alignment: .leading)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.badgeGap) {
                Text(category.displayName)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)

                badges

                Spacer(minLength: 0)
            }

            subtitle
        }
        // The flexible column: everything else in the row is a fixed width.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var badges: some View {
        if case .unavailable = result.availability {
            // Only this badge. A category can be both `isSafe` and unavailable —
            // `SystemCachesScanner` reports unavailable when Full Disk Access blocks
            // every root — and promising "safe to remove" for something we could not
            // even read is exactly the unearned claim this app exists to stop making.
            Badge(text: "unavailable").fixedSize()
        } else {
            // The result, not the static flag: the Xcode category is marked safe
            // but can hold an archive that is not, and a "safe" badge over a list
            // containing it would be the unearned claim the app exists to avoid.
            if category.isSafe && result.needsReviewBytes == 0 {
                Badge(text: "safe to delete", style: .safe).fixedSize()
            }
            if category.alwaysMovesToTrash {
                Badge(text: "moves to Trash").fixedSize()
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if case .unavailable(let reason) = result.availability {
            // The reason replaces the subtitle, and it is the point of the row: it says
            // how to get the category measured. The predecessor's bare "Docker is not
            // running" told the user nothing they could act on. The tooltip keeps the
            // full sentence reachable when a narrow window truncates it.
            subtitleText(reason, font: .mcSubtitle)
                .help(reason)
        } else {
            subtitleText(
                category.subtitle,
                font: category.subtitleIsPath ? .mcMonoPath : .mcSubtitle
            )
        }
    }

    private func subtitleText(_ string: String, font: Font) -> some View {
        Text(string)
            .font(font)
            .foregroundStyle(Token.Text.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: - Value block

    private var valueBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            totalText
            if isActionable { selectionReadout }
        }
        .frame(width: Metrics.valueWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var totalText: some View {
        if case .unavailable = result.availability {
            // An em dash, not "0 B": nothing was measured, and a zero would claim the
            // category was looked at and found clean.
            Text("—")
                .font(.mcRowValue.weight(.medium))
                .foregroundStyle(Token.Text.disabled)
        } else {
            Text(ByteFormatting.string(result.totalBytes))
                .font(.mcRowValue.weight(.medium))
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var selectionReadout: some View {
        if selectedBytes > 0 {
            Text("\(ByteFormatting.string(selectedBytes)) selected")
                .font(.mcCaption)
                .foregroundStyle(Token.color(.accent))
                .lineLimit(1)
                // The design's 96pt column fits the sizes it sampled; a longer figure
                // shrinks a fraction rather than truncating to "492.8 MB sele…".
                .minimumScaleFactor(0.85)
        } else {
            Text("none selected")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.disabled)
                .lineLimit(1)
        }
    }

    /// One spoken sentence per row. VoiceOver reading "Docker, 0 bytes" would repeat
    /// the same lie the em dash exists to avoid.
    private var accessibilityDescription: String {
        var parts = [category.displayName]

        if case .unavailable(let reason) = result.availability {
            parts.append("unavailable")
            parts.append(reason)
            return parts.joined(separator: ", ")
        }

        parts.append(ByteFormatting.string(result.totalBytes))

        if isActionable {
            parts.append(
                selectedBytes > 0
                    ? "\(ByteFormatting.string(selectedBytes)) selected"
                    : "none selected"
            )
        } else {
            parts.append("nothing to clean")
        }

        // The same words the badge shows, so VoiceOver and the screen agree.
        if category.isSafe && result.needsReviewBytes == 0 { parts.append("safe to delete") }
        if category.alwaysMovesToTrash { parts.append("moves to Trash") }

        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("Category rows") {
    let largest: Int64 = 42_036_992_410      // 39.15 GB

    func entry(_ name: String, _ bytes: Int64) -> FileEntry {
        FileEntry(
            url: URL(filePath: "/Users/me/Downloads/\(name)"),
            kind: .archive,
            allocatedBytes: bytes
        )
    }

    let rows: [(ScanCategoryResult, Int64)] = [
        // Expandable, with a selection.
        (ScanCategoryResult(
            categoryID: .documentsAndFiles,
            totalBytes: largest,
            entries: [entry("Xcode_16.2.xip", 9_040_579_461)]
        ), 6_850_472_837),                   // 6.38 GB selected

        // Expandable, nothing selected, with the neutral badge.
        (ScanCategoryResult(
            categoryID: .applications,
            totalBytes: 24_674_587_115,      // 22.98 GB
            entries: [entry("Sketch.app", 1_200_000_000)]
        ), 0),

        // The green badge and the monospace path subtitle.
        (ScanCategoryResult(
            categoryID: .systemCaches,
            totalBytes: 1_750_199_173,       // 1.63 GB
            entries: [entry("Homebrew", 1_740_000_000)]
        ), 0),

        // Measured and genuinely zero — dimmed, no triangle, no bar.
        (ScanCategoryResult.empty(.xcode), 0),

        // Dimmed, and the reason takes over the subtitle.
        (ScanCategoryResult.unavailable(
            .docker,
            reason: "Docker Desktop is not running. Start it to measure images and volumes."
        ), 0)
    ]

    return GroupedBox {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.0.id) { index, row in
                if index > 0 { Divider().foregroundStyle(Token.Fill.boxBorder) }
                CategoryRow(
                    result: row.0,
                    isExpanded: index == 0,
                    selectedBytes: row.1,
                    onToggle: {}
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
    }
    .padding(24)
    // The narrow end of the design's resizable range — the point where the title
    // column is under most pressure.
    .frame(width: Token.Size.minimumContentWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
