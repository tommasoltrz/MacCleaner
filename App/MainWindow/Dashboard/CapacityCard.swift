import SwiftUI
import MacCleanerCore

/// The Dashboard's capacity card: how full the volume is, and what is filling it.
///
/// Every byte of capacity is accounted for here, `Unmeasured` included. That segment
/// is a normal legend row in the ordinary tone — it is the honest residual of an
/// unprivileged scan, not a warning, and styling it as one would invite users to try
/// to "fix" space that is simply unreadable.
///
/// `isMeasuring` is the measuring state. The volume totals come from `diskutil` and
/// are always current, so the eyebrow and hero stay real; only what the walk
/// actually produces goes to bones. Category names are stable across measurements,
/// so when a previous breakdown is in hand the names and dots stay put and only the
/// track and each figure pulse; a nil `breakdown` — the first run, nothing cached —
/// drops the whole legend to bones.
struct CapacityCard: View {

    private let eyebrow: String
    private let capacityBytes: Int64
    private let usedBytes: Int64
    private let freeBytes: Int64
    private let breakdown: StorageBreakdown?
    private let isMeasuring: Bool

    init(volume: VolumeInfo, breakdown: StorageBreakdown?, isMeasuring: Bool = false) {
        self.init(
            eyebrow: volume.eyebrow,
            capacityBytes: volume.capacityBytes,
            usedBytes: volume.usedBytes,
            freeBytes: volume.freeBytes,
            breakdown: breakdown,
            isMeasuring: isMeasuring
        )
    }

    /// Figures directly. `VolumeInfo` has no public initializer, so a preview outside
    /// `MacCleanerCore` has no other way in.
    init(
        eyebrow: String,
        capacityBytes: Int64,
        usedBytes: Int64,
        freeBytes: Int64,
        breakdown: StorageBreakdown?,
        isMeasuring: Bool = false
    ) {
        self.eyebrow = eyebrow
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.breakdown = breakdown
        self.isMeasuring = isMeasuring
    }

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .mcEyebrowStyle()

                // No gap: SwiftUI's line boxes already carry the leading that the
                // design's `line-height: 1.0` boxes leave out, which is the 7px the
                // handoff puts between these two lines.
                hero

                if let breakdown, !isMeasuring {
                    CapacityBar(breakdown: breakdown)
                        .padding(.top, 16)

                    legend(breakdown)
                        .padding(.top, 16)
                } else if let breakdown {
                    // Re-measuring with the previous breakdown in hand: the names
                    // are not in question, only the figures. Names and dots hold
                    // still; the track and each figure pulse.
                    SkeletonTrack()
                        .skeletonPulse()
                        .padding(.top, 16)

                    legend(breakdown, valuesAreBones: true)
                        .padding(.top, 16)
                        .accessibilityLabel("Measuring what is using the space")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonTrack()
                        LegendBones()
                            .padding(.top, 16)
                    }
                    .padding(.top, 16)
                    .skeletonPulse()
                    .accessibilityLabel("Measuring what is using the space")
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 22)
            // The card is as wide as the content column, whatever the window size.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hero row

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(ByteFormatting.string(usedBytes))
                    .font(.mcHero)
                    .mcTracked(-0.68)   // -0.02em
                    .foregroundStyle(Token.Text.emphasis)
                    // A cramped window truncates the clause beside it, never the figure.
                    .layoutPriority(1)

                Text("of \(ByteFormatting.string(capacityBytes)) used")
                    .font(.capacityHeroUnit)
                    .foregroundStyle(Token.Text.tertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Available")
                    .mcEyebrowStyle()
                Text(ByteFormatting.string(freeBytes))
                    .font(.mcSecondaryHero)
                    .mcTracked(-0.26)   // -0.01em
                    .foregroundStyle(Token.textColor(.green))
                    .lineLimit(1)
            }
            // Sit the free figure on the used figure's baseline — not the eyebrow
            // above it, which is what a plain first-baseline alignment would take.
            .alignmentGuide(.firstTextBaseline) { $0[.lastTextBaseline] }
        }
    }

    // MARK: - Legend

    /// Two columns filled **down** then across, so the entries stay in descending
    /// order as you read each column top to bottom. A `LazyVGrid` fills the other way.
    private func legend(_ breakdown: StorageBreakdown, valuesAreBones: Bool = false) -> some View {
        let entries = breakdown.legendEntries
        let leftCount = (entries.count + 1) / 2

        return HStack(alignment: .top, spacing: 34) {
            legendColumn(Array(entries.prefix(leftCount)), valuesAreBones: valuesAreBones)
            legendColumn(Array(entries.dropFirst(leftCount)), valuesAreBones: valuesAreBones)
        }
    }

    private func legendColumn(_ entries: [StorageSegment], valuesAreBones: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                LegendRow(entry: entry, valueIsBone: valuesAreBones)
            }
        }
        // Both columns take half of whatever the card is given.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LegendRow: View {
    let entry: StorageSegment
    /// A measurement is running: the name stands, the figure is not yet a fact.
    var valueIsBone = false

    @State private var isInfoHovered = false

    var body: some View {
        HStack(spacing: 8) {
            CategoryDot(color: entry.color, size: 8)

            Text(entry.displayName)
                .font(.mcBody)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            // The names that explain nothing by themselves get an info glyph.
            // The rest are left alone — eleven info icons would be noise.
            //
            // A hover-driven popover, not `.help()`: the native tooltip's dwell delay
            // reads as the icon doing nothing. The popover is its own window, so it
            // appears instantly and can never be clipped by the card.
            if let explanation = Self.explanation(for: entry.id) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isInfoHovered ? Token.Text.secondary : Token.Text.quaternary)
                    .contentShape(Rectangle())
                    .onHover { isInfoHovered = $0 }
                    .popover(isPresented: $isInfoHovered, arrowEdge: .top) {
                        Text(explanation)
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(width: 280)
                    }
            }

            Spacer(minLength: 12)

            if valueIsBone {
                SkeletonBone(width: 52, height: 10)
                    .skeletonPulse()
            } else {
                Text(ByteFormatting.string(entry.bytes))
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize()   // the name truncates first; the figure never does
            }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    private static func explanation(for id: StorageSegmentID) -> String? {
        switch id {
        case .systemData:
            return "Machine-wide files outside your home folder: /Library (support "
                + "files for all apps and users), Homebrew in /opt, and service data "
                + "in /private. Some of this is reclaimable, for example Homebrew "
                + "caches and old logs."
        case .unmeasured:
            return "Space this app is not allowed to read: the Spotlight index, "
                + "filesystem metadata, and files only macOS can touch. Reported "
                + "as unknown, not guessed at. It is not reclaimable."
        case .otherFilesInHome:
            return "Everything in your home folder that no named category claims: "
                + "folders you created at its top level, hidden tool data such as "
                + "~/.ssh or ~/.npm, and other loose files. Large & Old Files is "
                + "the place to explore what is in here."
        default:
            return nil
        }
    }
}

// MARK: - Stacked capacity bar

private struct CapacityBar: View {
    let breakdown: StorageBreakdown

    private let gap: CGFloat = 1.5

    private struct Slice: Identifiable {
        let segment: StorageSegment
        let width: CGFloat
        var id: StorageSegmentID { segment.id }
    }

    /// The segment under the pointer, if any.
    @State private var hovered: StorageSegmentID?
    /// Measured so the tooltip can be centred over its segment and clamped.
    @State private var tooltipWidth: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme

    /// Away from the surface, whichever way that is.
    private var hoverLift: Double { colorScheme == .dark ? 0.12 : -0.10 }

    var body: some View {
        GeometryReader { proxy in
            let slices = layout(in: proxy.size.width)
            HStack(spacing: gap) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    // One continuous track, so only its two outer ends are round.
                    // Rounding every segment made each read as a separate pill rather
                    // than a share of a single whole.
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: index == 0 ? Token.Radius.row : 0,
                            bottomLeading: index == 0 ? Token.Radius.row : 0,
                            bottomTrailing: index == slices.count - 1 ? Token.Radius.row : 0,
                            topTrailing: index == slices.count - 1 ? Token.Radius.row : 0
                        ),
                        style: .continuous
                    )
                    .fill(Token.color(slice.segment.color))
                    // Lifts the hovered segment out of the track so the pointer has
                    // visible feedback, not just a floating label. The lift has to
                    // reverse in light: brightening a segment on a white card walks it
                    // toward the background, so the feedback reads as fading out.
                    .brightness(hovered == slice.id ? hoverLift : 0)
                    .frame(width: slice.width)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = slice.id }
                        else if hovered == slice.id { hovered = nil }
                    }
                    .accessibilityLabel(slice.segment.displayName)
                    .accessibilityValue(ByteFormatting.string(slice.segment.bytes))
                }
            }
            .overlay(alignment: .topLeading) { tooltip(for: slices, in: proxy.size.width) }
        }
        .frame(height: Token.Size.capacityBar)
        .background(
            // The design's track alpha and its box hairline are the same value; the
            // track only shows through the gaps between segments.
            Token.Fill.boxBorder,
            in: RoundedRectangle(cornerRadius: Token.Radius.row, style: .continuous)
        )
    }

    /// A drawn tooltip rather than `.help()`.
    ///
    /// `.help()` is a system tooltip: it only appears on the key window and after a
    /// dwell delay, which made it unreliable — and impossible to confirm in a
    /// screenshot. This one is part of the view, so it is immediate and verifiable.
    @ViewBuilder
    private func tooltip(for slices: [Slice], in totalWidth: CGFloat) -> some View {
        if let hovered, let index = slices.firstIndex(where: { $0.id == hovered }) {
            let slice = slices[index]
            let leading = slices.prefix(index).reduce(CGFloat(0)) { $0 + $1.width + gap }

            HStack(spacing: 7) {
                CategoryDot(color: slice.segment.color, size: 8)
                Text(slice.segment.displayName)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                Text(ByteFormatting.string(slice.segment.bytes))
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
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
            // Plain offsets, not alignment guides: guides resolved the label to a
            // position outside the 13pt bar's bounds and it never appeared. The
            // width is measured so the label can be centred over its segment and
            // clamped inside the card rather than hanging off either end.
            .background(
                GeometryReader { label in
                    Color.clear.preference(key: TooltipWidth.self, value: label.size.width)
                }
            )
            .offset(
                x: min(max(leading + slice.width / 2 - tooltipWidth / 2, 0),
                       max(totalWidth - tooltipWidth, 0)),
                y: -36
            )
            .allowsHitTesting(false)
            .onPreferenceChange(TooltipWidth.self) { tooltipWidth = $0 }
        }
    }

    private func layout(in totalWidth: CGFloat) -> [Slice] {
        guard totalWidth > 0, breakdown.capacityBytes > 0 else { return [] }

        func space(for count: Int) -> CGFloat {
            max(0, totalWidth - gap * CGFloat(max(count - 1, 0)))
        }

        // Percentages are of capacity, which is right whenever the segments sum to
        // capacity — the invariant the breakdown is built to hold. If a measurement
        // fault ever breaks it, the bar still may not draw outside itself, so the
        // denominator is whichever is larger. Proportions between segments stay
        // exactly as measured; nothing is invented to make them fit.
        let denominator = max(breakdown.capacityBytes, breakdown.segments.reduce(0) { $0 + $1.bytes })

        func widths(of segments: [StorageSegment]) -> [CGFloat] {
            let available = space(for: segments.count)
            return segments.map {
                available * CGFloat(Double($0.bytes) / Double(max(denominator, 1)))
            }
        }

        // A segment narrower than a point reads as a rendering artifact wedged between
        // two gaps. Core already folds true slivers into `Other`; this guards the case
        // where a legitimate segment is squeezed out by a narrow window.
        let visible = zip(breakdown.segments, widths(of: breakdown.segments))
            .filter { $0.1 >= 1 }
            .map { $0.0 }
        guard !visible.isEmpty else { return [] }

        var final = widths(of: visible)
        // The design gives the last segment — Free — the remainder rather than its own
        // exact share, so the bar always meets its right edge instead of leaving a
        // rounding sliver of bare track.
        let slack = space(for: visible.count) - final.reduce(0, +)
        final[final.count - 1] = max(0, final[final.count - 1] + slack)

        return zip(visible, final).map { Slice(segment: $0, width: $1) }
    }
}

/// The hero row's trailing clause. 16pt belongs to this card alone, so it is not in
/// the shared ramp — but it carries a figure, so it carries tabular digits.
private extension Font {
    static let capacityHeroUnit = Font.system(size: 16).monospacedDigit()
}

#Preview("Capacity card") {
    let gb: (Double) -> Int64 = { Int64($0 * Double(ByteFormatting.bytesPerGB)) }
    let mb: (Double) -> Int64 = { Int64($0 * Double(ByteFormatting.bytesPerMB)) }

    CapacityCard(
        eyebrow: "Macintosh HD · APFS · Encrypted",
        capacityBytes: gb(228.27),
        usedBytes: gb(162.00),
        freeBytes: gb(66.27),
        breakdown: .make(
            capacityBytes: gb(228.27),
            rawSegments: [
                .macOSSystem: gb(34.66),
                .documentsDesktop: gb(29.51),
                .systemData: gb(26.62),
                .appDataCaches: gb(24.79),
                .applications: gb(19.09),
                .unmeasured: gb(11.48),
                .downloads: gb(9.64),
                .packageBuildCaches: gb(3.47),
                .otherFilesInHome: gb(2.70),
                // Slivers. Core merges these into `Other`, which gets no legend row —
                // and here it is small enough that the bar skips it too.
                .developer: mb(35.2),
                .movies: mb(9.9),
                .music: 384 * ByteFormatting.bytesPerKB,
                .photos: 8 * ByteFormatting.bytesPerKB,
                .free: gb(66.27)
            ],
            unreadableCount: 1_284
        )
    )
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

/// Width of the hover tooltip, so it can be centred over its segment.
private struct TooltipWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
