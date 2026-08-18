import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Storage breakdown math")
struct BreakdownMathTests {

    private static let gb = Int64(1024 * 1024 * 1024)

    @Test("every byte of capacity is accounted for")
    func segmentsSumToCapacity() {
        let capacity = 100 * Self.gb
        let breakdown = StorageBreakdown.make(
            capacityBytes: capacity,
            rawSegments: [
                .macOSSystem: 30 * Self.gb,
                .documentsDesktop: 20 * Self.gb,
                .applications: 10 * Self.gb,
                .unmeasured: 5 * Self.gb,
                .free: 35 * Self.gb
            ],
            unreadableCount: 0
        )
        #expect(breakdown.segments.reduce(0) { $0 + $1.bytes } == capacity)
    }

    @Test("slivers merge into Other rather than rendering as hairlines")
    func sliversMerge() {
        let capacity = 100 * Self.gb
        // Each of these is well under 0.5% of 100 GB.
        let breakdown = StorageBreakdown.make(
            capacityBytes: capacity,
            rawSegments: [
                .documentsDesktop: 60 * Self.gb,
                .developer: 35 * 1024 * 1024,   // 35 MB
                .movies: 10 * 1024 * 1024,      // 10 MB
                .music: 384 * 1024,             // 384 KB
                .photos: 8 * 1024,              // 8 KB
                .free: 39 * Self.gb
            ],
            unreadableCount: 0
        )

        let ids = breakdown.segments.map(\.id)
        #expect(!ids.contains(.developer))
        #expect(!ids.contains(.music))
        #expect(ids.contains(.other))

        // Nothing is lost in the merge.
        #expect(breakdown.segments.reduce(0) { $0 + $1.bytes }
                == 60 * Self.gb + 39 * Self.gb + 35 * 1024 * 1024 + 10 * 1024 * 1024 + 384 * 1024 + 8 * 1024)
    }

    @Test("merged slivers get no legend row, per the design")
    func mergedSliversAreNotInTheLegend() {
        let breakdown = StorageBreakdown.make(
            capacityBytes: 100 * Self.gb,
            rawSegments: [.documentsDesktop: 60 * Self.gb, .music: 1024, .free: 40 * Self.gb],
            unreadableCount: 0
        )
        #expect(breakdown.segments.contains { $0.id == .other })
        #expect(!breakdown.legendEntries.contains { $0.id == .other })
    }

    @Test("Unmeasured survives the merge however small — it is never hidden")
    func unmeasuredNeverMerges() {
        let breakdown = StorageBreakdown.make(
            capacityBytes: 1000 * Self.gb,
            rawSegments: [
                .documentsDesktop: 500 * Self.gb,
                .unmeasured: 1024 * 1024,        // 1 MB of 1000 GB — far below threshold
                .free: 500 * Self.gb - 1024 * 1024
            ],
            unreadableCount: 0
        )
        #expect(breakdown.segments.contains { $0.id == .unmeasured })
        #expect(breakdown.legendEntries.contains { $0.id == .unmeasured })
    }

    @Test("Free is never merged and always renders last")
    func freeIsLast() {
        let breakdown = StorageBreakdown.make(
            capacityBytes: 1000 * Self.gb,
            rawSegments: [.documentsDesktop: 999 * Self.gb, .free: 1 * Self.gb],
            unreadableCount: 0
        )
        #expect(breakdown.segments.last?.id == .free)
    }

    @Test("Unmeasured keeps its name — it must not be relabelled")
    func unmeasuredIsNamedHonestly() {
        // Two historical wrong labels: "APFS Snapshots & System Overhead", then
        // "Other User Accounts". Both were guesses presented as measurements.
        #expect(StorageSegmentID.unmeasured.displayName == "Unmeasured")
        #expect(!StorageSegmentID.unmeasured.isMergeable)
    }

    @Test("segments are ordered by size so the bar reads largest-first")
    func ordering() {
        let breakdown = StorageBreakdown.make(
            capacityBytes: 100 * Self.gb,
            rawSegments: [
                .applications: 10 * Self.gb,
                .documentsDesktop: 30 * Self.gb,
                .macOSSystem: 20 * Self.gb,
                .free: 40 * Self.gb
            ],
            unreadableCount: 0
        )
        let sized = breakdown.segments.filter { $0.id != .free }
        #expect(sized.map(\.id) == [.documentsDesktop, .macOSSystem, .applications])
    }
}
