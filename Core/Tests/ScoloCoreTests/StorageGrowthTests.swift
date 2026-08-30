import Foundation
import Testing
@testable import ScoloCore

@Suite("Storage growth: what changed between two measurements")
struct StorageGrowthTests {

    private let gb = GrowthFixture.gigabyte

    // MARK: - Refusing to compare

    @Test("a rule change is reported, never subtracted")
    func contractVersionMismatch() {
        let old = GrowthFixture.snapshot(
            used: 100 * gb,
            contract: GrowthFixture.contract(version: MeasurementContract.currentVersion - 1)
        )
        let new = GrowthFixture.snapshot(at: GrowthFixture.noon.addingTimeInterval(3600), used: 130 * gb)

        #expect(StorageGrowth.compare(baseline: old, latest: new)
            == .notComparable(reason: "The measurement rules changed."))
    }

    @Test("a different node depth is a different measurement")
    func contractDepthMismatch() {
        let old = GrowthFixture.snapshot(used: 100 * gb, contract: GrowthFixture.contract(nodeDepth: 3))
        let new = GrowthFixture.snapshot(used: 100 * gb, contract: GrowthFixture.contract(nodeDepth: 4))

        #expect(StorageGrowth.compare(baseline: old, latest: new)
            == .notComparable(reason: "The measurement rules changed."))
    }

    @Test("another disk is not this disk")
    func volumeMismatch() {
        let old = GrowthFixture.snapshot(used: 100 * gb)
        let new = GrowthFixture.snapshot(
            used: 100 * gb,
            contract: GrowthFixture.contract(volumeName: "External")
        )

        #expect(StorageGrowth.compare(baseline: old, latest: new)
            == .notComparable(reason: "The volume changed."))
    }

    @Test("one measurement is not a comparison")
    func singleSnapshot() {
        let only = GrowthFixture.snapshot(used: 100 * gb)

        #expect(StorageGrowth.comparison(.previousMeasurement, in: [only]) == .insufficientHistory)
        #expect(StorageGrowth.comparison(.previousMeasurement, in: []) == .insufficientHistory)
    }

    // MARK: - Segment and class arithmetic

    @Test("a segment crossing the merge threshold does not invent a change")
    func rawSegmentsSurviveTheMerge() throws {
        // Half a percent of 500 GB is 2.5 GB: below it a segment is folded into
        // `Other` and disappears from the displayed breakdown.
        let old = GrowthFixture.snapshot(used: 100 * gb, named: [.movies: 2 * gb])
        let new = GrowthFixture.snapshot(
            at: GrowthFixture.noon.addingTimeInterval(3600),
            used: 101 * gb,
            named: [.movies: 3 * gb]
        )

        #expect(!old.breakdown.segments.contains { $0.id == .movies }, "merged into Other")
        #expect(old.breakdown.segments.contains { $0.id == .other })
        #expect(new.breakdown.segments.contains { $0.id == .movies }, "now large enough to show")

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        #expect(report.segmentDeltas[.movies] == gb)
        #expect(report.segmentDeltas[.other] == nil, "Other is a rendering, not a place")
    }

    @Test("free space is not reported as a second, opposite change")
    func freeSpaceIsNotASegmentDelta() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, named: [.downloads: 10 * gb])
        let new = GrowthFixture.snapshot(used: 120 * gb, named: [.downloads: 30 * gb])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        #expect(report.segmentDeltas[.free] == nil)
        #expect(report.usedDeltaBytes == 20 * gb)
    }

    @Test("the five classes always sum to the change in used space")
    func classesSumToUsedDelta() throws {
        let old = GrowthFixture.snapshot(
            used: 100 * gb,
            named: [.downloads: 10 * gb, .appDataCaches: 20 * gb, .systemData: 30 * gb]
        )
        let new = GrowthFixture.snapshot(
            used: 118 * gb,
            named: [.downloads: 21 * gb, .appDataCaches: 25 * gb, .systemData: 32 * gb]
        )

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        #expect(report.classDeltas[.user] == 11 * gb)
        #expect(report.classDeltas[.appDataAndCaches] == 5 * gb)
        #expect(report.classDeltas[.macOS] == 2 * gb)
        #expect(report.classDeltas.values.reduce(0, +) == report.usedDeltaBytes)
    }

    @Test("Unmeasured absorbs whatever the segments do not account for")
    func unmeasuredAbsorbsTheResidual() throws {
        // The latest measurement attributes more than the disk reports as used, so
        // its `Unmeasured` segment clamps to zero and the segments no longer add up
        // to the change. The remainder must not vanish.
        let old = GrowthFixture.snapshot(used: 100 * gb, named: [.downloads: 50 * gb])
        let new = GrowthFixture.snapshot(used: 100 * gb, named: [.downloads: 150 * gb])

        #expect(new.rawSegments[.unmeasured] == 0)

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        #expect(report.usedDeltaBytes == 0)
        #expect(report.classDeltas[.user] == 100 * gb)
        #expect(report.classDeltas[.unmeasured] == -100 * gb)
        #expect(report.classDeltas.values.reduce(0, +) == 0)
    }

    // MARK: - Attribution

    @Test("one child that explains the change is named instead of its parent")
    func collapseToTheDominantChild() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents", 1_000_000_000),
            GrowthFixture.node("Documents/Renewals", 900_000_000),
            GrowthFixture.node("Documents/Renewals/build", 800_000_000)
        ])
        let new = GrowthFixture.snapshot(used: 111 * gb, nodes: [
            GrowthFixture.node("Documents", 12_200_000_000),
            GrowthFixture.node("Documents/Renewals", 12_100_000_000),
            GrowthFixture.node("Documents/Renewals/build", 11_800_000_000)
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        let attribution = try #require(report.attributions.first)

        #expect(report.attributions.count == 1, "the parent is not reported as well")
        #expect(attribution.path == "/Users/tester/Documents/Renewals/build")
        #expect(attribution.deltaBytes == 11_000_000_000)
        #expect(attribution.kind == .grew)
        #expect(attribution.segment == .documentsDesktop)
    }

    @Test("a parent that grew in two places keeps its own name")
    func noSingleChildExplainsIt() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents", 1_000_000_000),
            GrowthFixture.node("Documents/alpha", 500_000_000),
            GrowthFixture.node("Documents/beta", 500_000_000)
        ])
        let new = GrowthFixture.snapshot(used: 111 * gb, nodes: [
            GrowthFixture.node("Documents", 12_200_000_000),
            GrowthFixture.node("Documents/alpha", 5_500_000_000),
            GrowthFixture.node("Documents/beta", 6_500_000_000)
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        let attribution = try #require(report.attributions.first)

        #expect(report.attributions.count == 1)
        #expect(attribution.path == "/Users/tester/Documents")
        #expect(attribution.deltaBytes == 11_200_000_000)
    }

    @Test("a folder that was not there before is new, and one that is gone is gone")
    func appearedAndDisappeared() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Movies/old-project", 4_000_000_000, segment: .movies)
        ])
        let new = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Downloads/Xcode.xip", 9_000_000_000, segment: .downloads)
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        let byPath = Dictionary(uniqueKeysWithValues: report.attributions.map { ($0.path, $0) })

        #expect(byPath["/Users/tester/Downloads/Xcode.xip"]?.kind == .appeared)
        #expect(byPath["/Users/tester/Downloads/Xcode.xip"]?.deltaBytes == 9_000_000_000)
        #expect(byPath["/Users/tester/Movies/old-project"]?.kind == .disappeared)
        #expect(byPath["/Users/tester/Movies/old-project"]?.deltaBytes == -4_000_000_000)
    }

    @Test("a moved folder reads as a move, not as growth and a matching loss")
    func moveByIdentity() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Desktop", 11_000_000_000),
            GrowthFixture.node("Desktop/build", 11_000_000_000, identity: "16777232:9241")
        ])
        let new = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents", 11_000_000_000),
            GrowthFixture.node("Documents/build", 11_000_000_000, identity: "16777232:9241")
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        let byPath = Dictionary(uniqueKeysWithValues: report.attributions.map { ($0.path, $0) })

        #expect(byPath["/Users/tester/Documents/build"]?.kind
            == .movedIn(from: "/Users/tester/Desktop/build"))
        #expect(byPath["/Users/tester/Desktop/build"]?.kind
            == .movedOut(to: "/Users/tester/Documents/build"))
        #expect(!report.attributions.contains { $0.kind == .appeared })
        #expect(!report.attributions.contains { $0.kind == .disappeared })
    }

    @Test("a reused inode carrying a different size is not a move")
    func identityAloneIsNotEnough() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Desktop/gone", 11_000_000_000, identity: "16777232:9241")
        ])
        let new = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents/other", 2_000_000_000, identity: "16777232:9241")
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)

        #expect(report.attributions.contains { $0.kind == .appeared })
        #expect(report.attributions.contains { $0.kind == .disappeared })
    }

    @Test("a change too small to name a folder for names none")
    func belowTheAttributionThreshold() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents", 1_000_000_000)
        ])
        let new = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("Documents", 1_050_000_000)
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        #expect(report.attributions.isEmpty)
    }

    @Test("the report names at most the places it was asked for, largest first")
    func attributionsAreRankedAndCapped() throws {
        let sizes: [Int64] = [9, 8, 7, 6, 5, 4, 3, 2, 1]
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [])
        let new = GrowthFixture.snapshot(used: 145 * gb, nodes: sizes.map {
            GrowthFixture.node("Documents/f\($0)", $0 * GrowthFixture.gigabyte)
        })

        let report = try #require(
            StorageGrowth.compare(baseline: old, latest: new, maximumAttributions: 3).report
        )

        #expect(report.attributions.map(\.deltaBytes) == [9 * gb, 8 * gb, 7 * gb])
    }

    @Test("a machine-wide root is a place the report can name")
    func systemRootsAreAttributed() throws {
        let old = GrowthFixture.snapshot(used: 100 * gb, nodes: [
            GrowthFixture.node("/Applications", 20 * GrowthFixture.gigabyte, segment: .applications)
        ])
        let new = GrowthFixture.snapshot(used: 103 * gb, nodes: [
            GrowthFixture.node("/Applications", 23 * GrowthFixture.gigabyte, segment: .applications)
        ])

        let report = try #require(StorageGrowth.compare(baseline: old, latest: new).report)
        let attribution = try #require(report.attributions.first)

        #expect(attribution.path == "/Applications")
        #expect(attribution.segment == .applications)
        #expect(attribution.deltaBytes == 3 * gb)
    }

    // MARK: - Choosing a baseline

    @Test("the previous measurement is the newest one before the latest")
    func previousBaseline() throws {
        let ring = ring()
        let latest = try #require(ring.first)

        let chosen = StorageGrowth.baseline(.previousMeasurement, in: ring, latest: latest)
        #expect(chosen?.measuredAt == GrowthFixture.noon.addingTimeInterval(-2 * 24 * 3600))
    }

    @Test("seven days finds a measurement at least that old")
    func sevenDayBaseline() throws {
        let ring = ring()
        let latest = try #require(ring.first)

        let chosen = StorageGrowth.baseline(.sevenDays, in: ring, latest: latest)
        #expect(chosen?.measuredAt == GrowthFixture.noon.addingTimeInterval(-9 * 24 * 3600))
    }

    @Test("with no measurement that old, seven days falls back to the oldest there is")
    func sevenDayBaselineFallsBack() throws {
        let ring = Array(ring().prefix(2))
        let latest = try #require(ring.first)

        let chosen = StorageGrowth.baseline(.sevenDays, in: ring, latest: latest)
        #expect(chosen?.measuredAt == GrowthFixture.noon.addingTimeInterval(-2 * 24 * 3600))
    }

    @Test("the last clean-up baseline is the newest removal measurement")
    func cleanupBaseline() throws {
        let ring = ring()
        let latest = try #require(ring.first)

        let chosen = StorageGrowth.baseline(.lastCleanup, in: ring, latest: latest)
        #expect(chosen?.trigger == .removal)
        #expect(chosen?.measuredAt == GrowthFixture.noon.addingTimeInterval(-5 * 24 * 3600))
    }

    @Test("no clean-up yet means no clean-up baseline")
    func cleanupBaselineAbsent() throws {
        let ring = ring().filter { $0.trigger != .removal }
        let latest = try #require(ring.first)

        #expect(StorageGrowth.baseline(.lastCleanup, in: ring, latest: latest) == nil)
        #expect(StorageGrowth.comparison(.lastCleanup, in: ring) == .insufficientHistory)
    }

    /// Newest first, as the store returns them.
    private func ring() -> [StorageSnapshot] {
        let days: [(Double, SnapshotTrigger)] = [
            (0, .manual), (-2, .launch), (-5, .removal), (-9, .scheduled), (-20, .launch)
        ]
        return days.map { offset, trigger in
            GrowthFixture.snapshot(
                at: GrowthFixture.noon.addingTimeInterval(offset * 24 * 3600),
                trigger: trigger,
                used: 100 * gb
            )
        }
    }
}

@Suite("Signed byte formatting")
struct SignedByteFormattingTests {

    @Test("a change carries its sign, and zero carries none")
    func signs() {
        #expect(ByteFormatting.signedString(11_200_000_000) == "+11.20 GB")
        #expect(ByteFormatting.signedString(-340_000_000) == "\u{2212}340.0 MB")
        #expect(ByteFormatting.signedString(0) == "0 B")
    }

    @Test("the minus is a minus sign, not a hyphen")
    func minusGlyph() {
        #expect(ByteFormatting.signedString(-1_000) == "\u{2212}1 KB")
        #expect(!ByteFormatting.signedString(-1_000).hasPrefix("-"))
    }

    @Test("the largest negative value does not trap")
    func extremes() {
        #expect(ByteFormatting.signedString(Int64.min).hasPrefix("\u{2212}"))
        #expect(ByteFormatting.signedString(Int64.max).hasPrefix("+"))
    }
}

extension GrowthComparison {
    /// Test convenience: the report, or `nil` for the other two outcomes.
    var report: StorageGrowthReport? {
        if case .report(let report) = self { return report }
        return nil
    }
}
