import SwiftUI
import ScoloCore

/// Shows a category name, item count, and size above its files.
struct CategoryRow: View {
    let result: ScanCategoryResult
    let isExpanded: Bool
    let selectedBytes: Int64
    let onToggle: () -> Void

    private var category: CategoryID { result.categoryID }

    private var isActionable: Bool {
        result.availability.isActionable && !result.entries.isEmpty
    }

    var body: some View {
        if isActionable {
            Button(action: onToggle) { rowContent }
                .buttonStyle(.plain)
                .hoverHighlight()
                .accessibilityLabel(accessibilityDescription)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        } else {
            rowContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 11) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Token.Text.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isActionable ? 1 : 0)
                .frame(width: 11)
                .animation(.easeOut(duration: 0.18), value: isExpanded)
            CategoryDot(color: category.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.displayName)
                    .font(.mcToolbarTitle)
                    .foregroundStyle(isActionable ? Token.Text.primary : Token.Text.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(category.subtitle)
            VStack(alignment: .trailing, spacing: 4) {
                Text(totalDisplay)
                    .font(.mcRowTitle.monospacedDigit())
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                if isActionable, selectedBytes > 0 {
                    Text("\(ByteFormatting.string(selectedBytes)) selected")
                        .font(.mcCaption)
                        .foregroundStyle(Token.color(.accent))
                        .lineLimit(1)
                }
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detail: String {
        if case .unavailable(let reason) = result.availability { return reason }
        let count = result.entries.count
        return "\(count) \(count == 1 ? "item" : "items")"
    }

    private var totalDisplay: String {
        if case .unavailable = result.availability { return "—" }
        return ByteFormatting.string(result.applicationInstalledBytes ?? result.totalBytes)
    }

    private var accessibilityDescription: String {
        let selection = selectedBytes > 0
            ? ", \(ByteFormatting.string(selectedBytes)) selected" : ""
        return "\(category.displayName), \(detail), \(totalDisplay)\(selection)"
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
