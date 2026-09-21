import SwiftUI
import ScoloCore

/// The Dashboard's "what grew" card: what changed since a dated measurement, and
/// where.
///
/// Every figure here is one measured number minus another measured number, taken
/// under the same rules. Nothing is estimated. When the rules changed between the
/// two measurements the card says so and shows no figures at all, because a
/// difference across a rule change describes the rules, not the disk.
///
/// The card is dated history, not live data. A measurement in progress therefore
/// leaves it exactly as it is — there is no measuring state and no skeleton. The
/// report on screen was true when it was made, and it stays true while the next
/// walk runs.
struct GrowthCard: View {

    /// Everything the card draws.
    ///
    /// Deliberately not ``GrowthComparison`` itself. A report carries the two stored
    /// measurements, and a measurement cannot be built outside `ScoloCore` —
    /// `VolumeInfo` has no public initializer — so a preview would have nothing to
    /// show. The card needs the figures, not the snapshots they came from.
    enum Presentation: Equatable {
        case report(Report)
        /// The two measurements were made under different rules.
        case notComparable(reason: String)
        case insufficientHistory
    }

    struct Report: Equatable {
        /// The real date of the measurement compared against, whichever baseline was
        /// asked for. "7 days" is a request; this is what was found.
        let baselineDate: Date
        let usedDeltaBytes: Int64
        let classDeltas: [GrowthClass: Int64]
        let attributions: [GrowthAttribution]
    }

    let presentation: Presentation
    let baseline: GrowthBaseline
    var onSelectBaseline: (GrowthBaseline) -> Void = { _ in }
    var onReveal: (GrowthAttribution) -> Void = { _ in }

    /// How many places the card names.
    ///
    /// Core reports up to eight. Five is what fits under the capacity card without
    /// turning a summary into a table, and the sixth largest change on this Mac was
    /// always small enough to be noise.
    private static let maximumRows = 5

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(eyebrow)
                .mcEyebrowStyle()
                .lineLimit(1)

            Spacer(minLength: 8)

            baselineMenu
        }
    }

    private var eyebrow: String {
        guard case .report(let report) = presentation else { return "What grew" }
        return "Since \(Self.stamp(report.baselineDate))"
    }

    private var baselineMenu: some View {
        Menu {
            ForEach(GrowthBaseline.allCases, id: \.self) { choice in
                Button(choice.displayName) { onSelectBaseline(choice) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(baseline.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(SecondaryButtonStyle())
        // The label already carries a chevron, drawn at the size the design's
        // controls use rather than the one AppKit picks.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the measurement to compare against")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .report(let report):
            reportBody(report)
        case .notComparable(let reason):
            message(reason, hint: "Measure again to start a new history.")
        case .insufficientHistory:
            message("First measurement.", hint: "Growth appears after the next one.")
        }
    }

    private func message(_ primary: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primary)
                .font(.mcRowTitleRegular)
                .foregroundStyle(Token.Text.primary)
            Text(hint)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reportBody(_ report: Report) -> some View {
        let rows = Array(report.attributions.prefix(Self.maximumRows))

        hero(report.usedDeltaBytes)
        classRow(report.classDeltas)

        if rows.isEmpty {
            // The disk changed and no single folder is large enough to name. Saying
            // so is the honest answer; the class row above already carries the
            // change itself.
            Text("No folder changed by enough to name.")
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
                .padding(.top, 14)
        } else {
            divider
                .padding(.top, 14)

            VStack(spacing: 0) {
                ForEach(rows) { attribution in
                    AttributionRow(attribution: attribution, onReveal: onReveal)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Hero

    /// The one figure the disk itself agrees with: used space, then and now.
    ///
    /// Kept in the ordinary emphasis colour, not red for growth and green for a
    /// fall. A disk that filled up is not a fault, and painting it as one would
    /// push the user toward deleting whatever the card happened to name.
    private func hero(_ delta: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("Used space")
                .font(.growthHeroLabel)
                .foregroundStyle(Token.Text.tertiary)

            Text(ByteFormatting.signedString(delta))
                .font(.mcSecondaryHero)
                .mcTracked(-0.26)   // -0.01em
                .foregroundStyle(Token.Text.emphasis)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Classes

    private struct ClassEntry: Identifiable {
        let growthClass: GrowthClass
        let delta: Int64
        var id: String { growthClass.rawValue }
    }

    /// The five classes that changed, largest first. A class that did not move is
    /// left out rather than printed as `0 B`, which reads as a measurement of
    /// nothing instead of nothing to report.
    private func classEntries(_ deltas: [GrowthClass: Int64]) -> [ClassEntry] {
        GrowthClass.allCases
            .map { ClassEntry(growthClass: $0, delta: deltas[$0] ?? 0) }
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) > abs($1.delta) }
    }

    @ViewBuilder
    private func classRow(_ deltas: [GrowthClass: Int64]) -> some View {
        let entries = classEntries(deltas)
        if !entries.isEmpty {
            let half = (entries.count + 1) / 2
            // One line while the window is wide enough for it. A narrow window gets
            // two lines rather than a row that truncates its own figures.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ForEach(entries) { classChip($0) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 16) {
                        ForEach(entries.prefix(half)) { classChip($0) }
                    }
                    HStack(spacing: 16) {
                        ForEach(entries.dropFirst(half)) { classChip($0) }
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func classChip(_ entry: ClassEntry) -> some View {
        HStack(spacing: 7) {
            CategoryDot(color: entry.growthClass.color, size: 8)
            Text(entry.growthClass.displayName)
                .font(.mcBody)
                .foregroundStyle(Token.Text.primary)
            Text(ByteFormatting.signedString(entry.delta))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }

    /// "Tue 26 Aug, 09:12", in the user's locale.
    ///
    /// Named to the minute. The report subtracts two dated measurements, and the
    /// user must be able to tell which two.
    private static func stamp(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        )
    }
}

// MARK: - Reading a comparison

extension GrowthCard.Presentation {

    /// Reads a stored comparison into the figures the card draws.
    init(_ comparison: GrowthComparison) {
        switch comparison {
        case .report(let report):
            self = .report(GrowthCard.Report(
                baselineDate: report.baseline.measuredAt,
                usedDeltaBytes: report.usedDeltaBytes,
                classDeltas: report.classDeltas,
                attributions: Self.oneRowPerEvent(report.attributions)
            ))
        case .notComparable(let reason):
            self = .notComparable(reason: reason)
        case .insufficientHistory:
            self = .insufficientHistory
        }
    }

    /// One move is one event.
    ///
    /// Core reports a move twice, and correctly: the folder left one path and
    /// arrived at another, so both paths changed. On the card that reads as a loss
    /// and an unrelated gain of the same size. The arriving row already names where
    /// the folder came from, so it tells the whole story on its own and the
    /// departing row is dropped.
    ///
    /// Only when its partner is on the list. If the arrival fell outside the places
    /// Core reported, the departure is the only record of the event and it stays.
    static func oneRowPerEvent(_ attributions: [GrowthAttribution]) -> [GrowthAttribution] {
        let arrivals = Set(attributions.compactMap { attribution -> String? in
            guard case .movedIn = attribution.kind else { return nil }
            return attribution.path
        })
        return attributions.filter { attribution in
            guard case .movedOut(let destination) = attribution.kind else { return true }
            return !arrivals.contains(destination)
        }
    }
}

// MARK: - One place that changed

private struct AttributionRow: View {
    let attribution: GrowthAttribution
    let onReveal: (GrowthAttribution) -> Void

    var body: some View {
        if isRevealable {
            Button { onReveal(attribution) } label: { line }
                .buttonStyle(.plain)
                .hoverHighlight(radius: Token.Radius.row)
                .help("Open this folder in the Storage Explorer")
        } else {
            line
        }
    }

    /// A folder that is not there any more cannot be opened. Those rows state the
    /// change and stop, rather than offering a click that lands on an empty parent.
    private var isRevealable: Bool {
        switch attribution.kind {
        case .disappeared, .movedOut: false
        default:                      true
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            CategoryDot(color: attribution.segment.color, size: 8)

            Text(attribution.segment.displayName)
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
                .fixedSize()

            // The middle of a path is the part that repeats; its head names the
            // category and its tail names the folder that changed.
            Text(FileEntry.abbreviate(attribution.path))
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let badge = Self.badge(for: attribution.kind) {
                Badge(text: badge.text)
                    .help(badge.detail)
                    .fixedSize()
            }

            Spacer(minLength: 12)

            Text(ByteFormatting.signedString(attribution.deltaBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()   // the path truncates first; the figure never does
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A change that is not simply more or less. `grew` and `shrank` carry no badge:
    /// the signed figure beside them already says which one it is.
    private static func badge(
        for kind: GrowthAttribution.Kind
    ) -> (text: String, detail: String)? {
        switch kind {
        case .grew, .shrank:
            nil
        case .appeared:
            ("New", "This folder was not there at the earlier measurement.")
        case .disappeared:
            ("Gone", "This folder was there at the earlier measurement.")
        case .movedIn(let from):
            ("Moved from \(placeName(from))",
             "This folder was at \(FileEntry.abbreviate(from)).")
        case .movedOut(let to):
            ("Moved to \(placeName(to))",
             "This folder is now at \(FileEntry.abbreviate(to)).")
        }
    }

    /// Where a move came from or went to, named by the folder that held it.
    ///
    /// The full path goes in the tooltip. A badge carrying
    /// `~/Documents/Projects/Renewals/build` would be wider than the row it labels.
    private static func placeName(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == NSHomeDirectory() { return "Home" }
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty ? FileEntry.abbreviate(parent) : name
    }
}

/// The hero row's leading label. 16pt belongs to this card and the capacity card's
/// hero clause alone, so it stays out of the shared ramp.
private extension Font {
    static let growthHeroLabel = Font.system(size: 16)
}

// MARK: - Previews

#Preview("What grew — report") {
    let gb: (Double) -> Int64 = { Int64($0 * Double(ByteFormatting.bytesPerGB)) }
    let home = NSHomeDirectory()

    GrowthCard(
        presentation: .report(GrowthCard.Report(
            baselineDate: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60),
            usedDeltaBytes: gb(13.4),
            classDeltas: [
                .user: gb(11.2),
                .appDataAndCaches: gb(2.1),
                .macOS: gb(0.4),
                .applications: 0,
                .unmeasured: gb(-0.3)
            ],
            attributions: [
                GrowthAttribution(
                    path: home + "/Documents/Renewals/build",
                    segment: .documentsDesktop,
                    deltaBytes: gb(11.0),
                    kind: .grew
                ),
                GrowthAttribution(
                    path: home + "/Library/Caches/Homebrew",
                    segment: .packageBuildCaches,
                    deltaBytes: gb(1.6),
                    kind: .appeared
                ),
                GrowthAttribution(
                    path: home + "/Movies/Archive",
                    segment: .movies,
                    deltaBytes: gb(0.9),
                    kind: .movedIn(from: home + "/Desktop/Archive")
                )
            ]
        )),
        baseline: .sevenDays
    )
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Token.pageBackground)
    .preferredColorScheme(.dark)
}

#Preview("What grew — first measurement") {
    VStack(spacing: 16) {
        GrowthCard(presentation: .insufficientHistory, baseline: .sevenDays)
        GrowthCard(
            presentation: .notComparable(reason: "The measurement rules changed."),
            baseline: .previousMeasurement
        )
    }
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Token.pageBackground)
    .preferredColorScheme(.dark)
}
