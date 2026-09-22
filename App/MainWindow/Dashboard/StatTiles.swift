import SwiftUI
import ScoloCore

/// Cleanup totals and iCloud usage share one row.
struct StatTiles: View {

    private let safeToRemoveBytes: Int64?
    private let needsReviewBytes: Int64?
    private let lastScanAt: Date?
    private let iCloudStorage: ICloudStorage?
    /// Tap targets for the two counting tiles. A first-run placeholder stays inert.
    /// A saved scan time gives both tiles a fresh-scan action.
    private let onSafeTap: (() -> Void)?
    private let onReviewTap: (() -> Void)?
    /// Starts a fresh scan when only a saved timestamp remains.
    private let onScan: (() -> Void)?

    /// `nil` results means no scan has run this session: the two counting tiles fall
    /// back to placeholders. A saved scan time enables the Scan Again action.
    init(
        results: ScanResults?,
        lastScanAt: Date? = nil,
        iCloudStorage: ICloudStorage? = nil,
        onSafeTap: (() -> Void)? = nil,
        onReviewTap: (() -> Void)? = nil,
        onScan: (() -> Void)? = nil
    ) {
        self.safeToRemoveBytes = results?.safeToRemoveBytes
        self.needsReviewBytes = results?.needsReviewBytes
        self.lastScanAt = results?.finishedAt ?? lastScanAt
        self.iCloudStorage = iCloudStorage
        self.onSafeTap = onSafeTap
        self.onReviewTap = onReviewTap
        self.onScan = onScan
    }

    /// Figures directly. `ScanResults` has no public initializer, so a preview of the
    /// populated state has no other way in.
    init(
        safeToRemoveBytes: Int64?,
        needsReviewBytes: Int64?,
        lastScanAt: Date?
    ) {
        self.safeToRemoveBytes = safeToRemoveBytes
        self.needsReviewBytes = needsReviewBytes
        self.lastScanAt = lastScanAt
        self.iCloudStorage = nil
        self.onSafeTap = nil
        self.onReviewTap = nil
        self.onScan = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    linkedTile(
                        label: "Safe to Remove",
                        value: safeToRemoveBytes.map { ByteFormatting.string($0) },
                        emptyValue: savedScanNeedsRefresh ? "Scan Again" : nil,
                        description: "Files that can be created again when needed.",
                        action: onSafeTap,
                        emptyAction: savedScanNeedsRefresh ? onScan : nil
                    )
                    linkedTile(
                        label: "Needs Review",
                        value: needsReviewBytes.map { ByteFormatting.string($0) },
                        emptyValue: savedScanNeedsRefresh ? "Scan Again" : nil,
                        description: "Check these files before removal.",
                        action: onReviewTap,
                        emptyAction: savedScanNeedsRefresh ? onScan : nil
                    )
                    if let iCloudStorage {
                        ICloudCard(storage: iCloudStorage)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A timestamp is safe to keep. File removal candidates are not safe to keep
    /// across a relaunch because files can change or move.
    private var savedScanNeedsRefresh: Bool {
        safeToRemoveBytes == nil && needsReviewBytes == nil && lastScanAt != nil
    }

    @ViewBuilder
    private func linkedTile(
        label: String,
        value: String?,
        emptyValue: String?,
        description: String,
        action: (() -> Void)?,
        emptyAction: (() -> Void)?
    ) -> some View {
        if let activeAction = value != nil ? action : emptyAction {
            Button(action: activeAction) {
                StatTile(
                    label: label,
                    value: value,
                    emptyValue: emptyValue,
                    description: description,
                    showsChevron: true
                )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(value == nil ? "Run a new scan" : "Show these items")
        } else {
            StatTile(
                label: label,
                value: value,
                emptyValue: emptyValue,
                description: description
            )
        }
    }

}

// MARK: - One tile

private struct StatTile: View {
    let label: String
    /// `nil` before the first scan. Use an em dash in the disabled tone. "0 B"
    /// would incorrectly claim that a scan found no files.
    let value: String?
    /// Used in place of the em dash where the empty state has a word for itself.
    var emptyValue: String?
    let description: String
    /// Set on a tile that opens a list, so the affordance is visible before hover.
    var showsChevron: Bool = false

    private var isPlaceholder: Bool { value == nil }

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(label)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.secondary)
                    if showsChevron {
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Token.Text.quaternary)
                    }
                }

                Text(value ?? emptyValue ?? "—")
                    .animatedTotal(value)
                    .font(.mcSecondaryHero)
                    // A bare placeholder is disabled. A named empty value is an
                    // instruction, and it stays readable as the tile's action.
                    .foregroundStyle(
                        isPlaceholder && emptyValue == nil
                            ? Token.Text.quaternary
                            : Token.Text.primary
                    )
                    .lineLimit(1)
                    // A narrow window must not truncate the figure to "5.6…".
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(value ?? emptyValue ?? "Not measured yet")
                    .padding(.top, 8)

                Text(description)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineSpacing(2.5)   // the design's 1.4 line-height at 11.5pt
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            .padding(.top, 18)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            // Flexible in both axes: the grid has already sized the cell to the widest
            // column and the tallest tile, and this fills it so the box matches.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Stat tiles — scanned and pre-scan") {
    VStack(spacing: 24) {
        StatTiles(
            safeToRemoveBytes: 6_023_000_000,      // 5.61 GB
            needsReviewBytes: 66_712_000_000,      // 62.13 GB
            lastScanAt: Calendar.current.date(byAdding: .day, value: -2, to: .now)
        )
        StatTiles(results: nil)
        StatTiles(
            results: nil,
            lastScanAt: Calendar.current.date(byAdding: .minute, value: -20, to: .now),
            onScan: {}
        )
    }
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
