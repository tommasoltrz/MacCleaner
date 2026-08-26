import SwiftUI
import AppKit
import MacCleanerCore

/// The Dashboard's iCloud row.
///
/// Deliberately a single bar rather than a second full capacity card. Only one of its
/// segments is a real measurement — iCloud Drive — and giving three segments the same
/// visual weight as the disk breakdown's nine would imply we know the account as well
/// as we know the volume. We do not: Photos, device backups and Mail have no public
/// API, so they arrive together as `Unmeasured`.
///
/// The row opens System Settings, because that is the only place the rest of the
/// breakdown exists and the only place the account can actually be managed.
struct ICloudCard: View {
    let storage: ICloudStorage

    @State private var isHovered = false

    // Binary throughout, and labelled "GB" the way iCloud labels it: the plan
    // tiers are stored as GiB because that is what `brctl` and iCloud's own pages
    // agree on, and the decimal formatter turned the user's "200 GB" plan into
    // "214.75 GB". See `ByteFormatting.binaryString`.
    private var summary: String {
        let used = ByteFormatting.binaryString(storage.usedBytes)
        let total = ByteFormatting.binaryString(storage.totalBytes)
        let free = ByteFormatting.binaryString(storage.freeBytes)
        return "\(used) of \(total) used · \(free) available"
    }

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 10) {
                header
                ICloudBar(segments: storage.segments)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { Self.openICloudSettings() }
    }

    // The click affordance's hint lives on the header, not the whole card: on the
    // bar it would race the segments' own instant chips.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 17))
                .foregroundStyle(Token.color(.accent))

            Text("iCloud")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)

            Text(summary)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)

            if storage.planWasInferred {
                // The plan size is the one figure here with no source at all — macOS
                // exposes no API for it, so it is inferred from the free space. Saying
                // so is cheaper than being quietly wrong on an unusual plan.
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Token.Text.quaternary)
                    .help("Your plan size is estimated — macOS does not report it. "
                          + "Set it in Preferences if this is wrong.")
            }

            if storage.isNearlyFull {
                Badge(text: "Nearly full")
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Token.Text.secondary : Token.Text.quaternary)
        }
        .help("Open iCloud settings, where Photos and backups can be managed")
    }

    /// Deep-links to the iCloud pane. Falls back to System Settings itself if the
    /// pane identifier ever changes, which beats doing nothing.
    static func openICloudSettings() {
        let deepLink = URL(
            string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud"
        )
        if let deepLink, NSWorkspace.shared.open(deepLink) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// The proportional bar.
///
/// Hover names each segment with the same drawn chip the capacity bar uses.
/// `.help()` was there before, but it only appears on the key window after a dwell,
/// which in practice left the segments mute next to the whole card's click target.
private struct ICloudBar: View {
    let segments: [ICloudSegment]

    /// The segment under the pointer, if any.
    @State private var hovered: ICloudSegmentID?
    /// Measured so the chip can be centred over its segment and clamped to the bar.
    @State private var tooltipSize: CGSize = .zero

    @Environment(\.colorScheme) private var colorScheme

    /// Away from the surface, whichever way that is — see `CapacityBar`.
    private var hoverLift: Double { colorScheme == .dark ? 0.12 : -0.10 }

    private var total: Int64 { max(1, segments.reduce(0) { $0 + $1.bytes }) }

    var body: some View {
        GeometryReader { geometry in
            let widths = layout(in: geometry.size.width)
            HStack(spacing: 1) {
                ForEach(Array(zip(segments, widths)), id: \.0.id) { segment, segmentWidth in
                    Token.color(segment.color)
                        .brightness(hovered == segment.id ? hoverLift : 0)
                        .frame(width: segmentWidth)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = segment.id }
                            else if hovered == segment.id { hovered = nil }
                        }
                        .accessibilityLabel(segment.displayName)
                        .accessibilityValue(ByteFormatting.binaryString(segment.bytes))
                }
            }
            .clipShape(Capsule())
            .overlay(alignment: .topLeading) { tooltip(widths: widths, in: geometry.size.width) }
        }
        .frame(height: 8)
    }

    /// The drawn chip, floating above the bar. The explanation rides along where a
    /// segment has one — it is the only place the `Unmeasured` lump gets to say why
    /// it cannot be broken down.
    @ViewBuilder
    private func tooltip(widths: [CGFloat], in totalWidth: CGFloat) -> some View {
        if let hovered, let index = segments.firstIndex(where: { $0.id == hovered }) {
            let segment = segments[index]
            let leading = widths.prefix(index).reduce(CGFloat(0)) { $0 + $1 + 1 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    CategoryDot(color: segment.color, size: 8)
                    Text(segment.displayName)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text(ByteFormatting.binaryString(segment.bytes))
                        .font(.mcRowValue)
                        .foregroundStyle(Token.Text.secondary)
                }
                .fixedSize()

                if let explanation = segment.id.explanation {
                    Text(explanation)
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 250, alignment: .leading)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Token.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
            )
            .shadow(color: Token.chipShadow, radius: 8, y: 2)
            .background(
                GeometryReader { chip in
                    Color.clear.preference(key: ICloudTooltipSize.self, value: chip.size)
                }
            )
            .offset(
                x: min(max(leading + widths[index] / 2 - tooltipSize.width / 2, 0),
                       max(totalWidth - tooltipSize.width, 0)),
                y: -(tooltipSize.height + 6)
            )
            .allowsHitTesting(false)
            .onPreferenceChange(ICloudTooltipSize.self) { tooltipSize = $0 }
        }
    }

    /// Segments below a pixel or so are floored to a visible sliver rather than
    /// vanishing — a segment that renders as nothing reads as "you have none of
    /// this", which is a different claim from "you have a little".
    private func layout(in available: CGFloat) -> [CGFloat] {
        segments.map { segment in
            let exact = available * CGFloat(segment.bytes) / CGFloat(total)
            return segment.bytes > 0 ? max(exact, 2) : 0
        }
    }
}

/// Size of the hover chip, so it can be centred over its segment and sit above it.
private struct ICloudTooltipSize: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

#Preview("iCloud — measured") {
    ICloudCard(storage: ICloudStorage(
        totalBytes: 200 * 1024 * 1024 * 1024,
        freeBytes: 151 * 1024 * 1024 * 1024,
        documentsBytes: 6 * 1024 * 1024 * 1024,
        documentsOnDiskBytes: 100 * 1024 * 1024
    ))
    .padding()
    .frame(width: 720)
}

#Preview("iCloud — nearly full") {
    ICloudCard(storage: ICloudStorage(
        totalBytes: 200 * 1024 * 1024 * 1024,
        freeBytes: 4 * 1024 * 1024 * 1024,
        documentsBytes: 40 * 1024 * 1024 * 1024,
        planWasInferred: false
    ))
    .padding()
    .frame(width: 720)
}
