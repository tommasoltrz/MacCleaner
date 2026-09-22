import SwiftUI
import AppKit
import ScoloCore

/// Compact iCloud usage beside the cleanup totals.
struct ICloudCard: View {
    let storage: ICloudStorage

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
        Button(action: Self.openICloudSettings) {
            GroupedBox(radius: Token.Radius.card) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Text(ByteFormatting.binaryString(storage.usedBytes))
                        .animatedTotal(storage.usedBytes)
                        .font(.mcSecondaryHero)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 8)
                    Text("of \(ByteFormatting.binaryString(storage.totalBytes)) used")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .padding(.top, 7)
                    ICloudBar(segments: storage.segments)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(RoundedRectangle(cornerRadius: Token.Radius.card))
        }
        .buttonStyle(CardPressButtonStyle())
        .accessibilityLabel("iCloud")
        .accessibilityValue(summary + (storage.planWasInferred ? ". Plan size is estimated." : ""))
        .accessibilityHint("Open iCloud settings")
    }

    // The click affordance's hint lives on the header, not the whole card: on the
    // bar it would race the segments' own instant chips.
    private var header: some View {
        HStack(spacing: 6) {
            Text("iCloud")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.secondary)

            if storage.planWasInferred {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Token.Text.quaternary)
                    .help("Your plan size is estimated. Set the correct plan in Preferences.")
            }

            if storage.isNearlyFull {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Token.textColor(.orange))
                    .help("iCloud storage is nearly full.")
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Token.Text.quaternary)
        }
        .help("\(summary). Open iCloud settings.")
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
                        .frame(width: min(250, max(120, totalWidth - 22)), alignment: .leading)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
            )
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
    .frame(width: 300)
}

#Preview("iCloud — nearly full") {
    ICloudCard(storage: ICloudStorage(
        totalBytes: 200 * 1024 * 1024 * 1024,
        freeBytes: 4 * 1024 * 1024 * 1024,
        documentsBytes: 40 * 1024 * 1024 * 1024,
        planWasInferred: false
    ))
    .padding()
    .frame(width: 300)
}
