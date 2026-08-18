import SwiftUI
import MacCleanerCore

/// The Dashboard's row of three stat tiles.
///
/// The "Safe to remove" / "Needs review" split is the design's core claim — the app
/// separates what it will clean unattended from what needs a human — so the two totals
/// sit side by side at equal weight and are never summed into one headline number.
struct StatTiles: View {

    private let safeToRemoveBytes: Int64?
    private let needsReviewBytes: Int64?
    private let lastScanAt: Date?
    private let reclaimedBytes: Int64?

    /// `nil` results means no scan has run: every figure falls back to a placeholder.
    ///
    /// `reclaimedBytes` comes from the clean-up history rather than from the scan, so
    /// it is passed in; without it the "Last scan" tile shows the timestamp alone.
    init(results: ScanResults?, reclaimedBytes: Int64? = nil) {
        self.safeToRemoveBytes = results?.safeToRemoveBytes
        self.needsReviewBytes = results?.needsReviewBytes
        self.lastScanAt = results?.finishedAt
        self.reclaimedBytes = reclaimedBytes
    }

    /// Figures directly. `ScanResults` has no public initializer, so a preview of the
    /// populated state has no other way in.
    init(
        safeToRemoveBytes: Int64?,
        needsReviewBytes: Int64?,
        lastScanAt: Date?,
        reclaimedBytes: Int64? = nil
    ) {
        self.safeToRemoveBytes = safeToRemoveBytes
        self.needsReviewBytes = needsReviewBytes
        self.lastScanAt = lastScanAt
        self.reclaimedBytes = reclaimedBytes
    }

    var body: some View {
        // A Grid rather than an HStack: it sizes every cell in a row to the tallest
        // one, which is what keeps the tiles level when the descriptions wrap to
        // different line counts. Widths come from the flexible frame on each tile, so
        // the three stay equal as the window resizes.
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                StatTile(
                    label: "Safe to remove",
                    value: safeToRemoveBytes.map { ByteFormatting.string($0) },
                    description: "Caches, logs and package tarballs that regenerate on demand."
                )
                StatTile(
                    label: "Needs review",
                    value: needsReviewBytes.map { ByteFormatting.string($0) },
                    description: "Large files and unused apps. You decide, nothing is automatic."
                )
                StatTile(
                    label: "Last scan",
                    value: lastScanAt.map { relativeDescription($0) },
                    emptyValue: "Never",
                    description: lastScanAt.map { timestampDescription($0) }
                        ?? "Nothing measured yet. Run a scan to see what can be reclaimed."
                )
            }
        }
        // The row is as tall as its tallest tile and no taller — the tiles are
        // vertically flexible so they fill the grid cell, and without this the whole
        // row would stretch into whatever height a tall window offers it.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Relative first: how stale the numbers are matters more than the exact moment
    /// they were taken, which is on the line below.
    @MainActor
    private func relativeDescription(_ date: Date) -> String {
        // Inside a minute the formatter produces "in 0 seconds", which reads as a bug.
        guard Date.now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    /// `16 Aug at 9:41 AM · 4.2 GB reclaimed`
    private func timestampDescription(_ date: Date) -> String {
        let stamp = date.formatted(.dateTime.day().month(.abbreviated))
            + " at " + date.formatted(date: .omitted, time: .shortened)
        guard let reclaimedBytes else { return stamp }
        return stamp + " · " + ByteFormatting.string(reclaimedBytes) + " reclaimed"
    }
}

/// One formatter, not one per render: it is expensive to build and this string is
/// recomputed on every scan-state change.
@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named   // "yesterday" over "1 day ago"
    return formatter
}()

// MARK: - One tile

private struct StatTile: View {
    let label: String
    /// `nil` before the first scan. Rendered as an em dash in the disabled tone —
    /// "0 B" would claim the disk was measured and found clean.
    let value: String?
    /// Used in place of the em dash where the empty state has a word for itself.
    var emptyValue: String?
    let description: String

    private var isPlaceholder: Bool { value == nil }

    var body: some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)

                Text(value ?? emptyValue ?? "—")
                    .font(.mcStatValue)
                    // Token has no `disabled` step; quaternary is the bottom of the
                    // ramp and the nearest thing to the design's text-disabled.
                    .foregroundStyle(isPlaceholder ? Token.Text.quaternary : Token.Text.primary)
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
            .padding(.top, 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
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
            lastScanAt: Calendar.current.date(byAdding: .day, value: -2, to: .now),
            reclaimedBytes: 4_509_715_660          // 4.20 GB
        )
        StatTiles(results: nil)
    }
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
