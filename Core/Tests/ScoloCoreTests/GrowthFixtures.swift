import Foundation
@testable import ScoloCore

/// Hand-built measurements for the growth tests.
///
/// Every figure the diff engine reads is a parameter here, and nothing reaches the
/// real disk or the real clock: a report must be reproducible, or a failing test
/// says nothing about the code.
enum GrowthFixture {

    static let home = "/Users/tester"
    static let capacity: Int64 = 500_000_000_000
    static let gigabyte: Int64 = 1_000_000_000

    /// A fixed instant, so a stored measurement has the same filename every run.
    static let noon = Date(timeIntervalSince1970: 1_756_296_000)

    static func contract(
        version: Int = MeasurementContract.currentVersion,
        homePath: String = GrowthFixture.home,
        volumeName: String = "Macintosh HD",
        capacityBytes: Int64 = GrowthFixture.capacity,
        nodeDepth: Int = 4,
        minimumNodeBytes: Int64 = 100_000_000
    ) -> MeasurementContract {
        MeasurementContract(
            version: version,
            homePath: homePath,
            volumeName: volumeName,
            capacityBytes: capacityBytes,
            nodeDepth: nodeDepth,
            minimumNodeBytes: minimumNodeBytes
        )
    }

    /// One measurement. `named` holds the segments that were attributed; the
    /// remainder of used space becomes `Unmeasured` and the rest of the disk `Free`,
    /// exactly as `StorageBreakdownService` builds its raw table.
    static func snapshot(
        at measuredAt: Date = GrowthFixture.noon,
        trigger: SnapshotTrigger = .manual,
        used: Int64,
        named: [StorageSegmentID: Int64] = [:],
        nodes: [SnapshotNode] = [],
        contract: MeasurementContract = GrowthFixture.contract(),
        id: UUID = UUID()
    ) -> StorageSnapshot {
        var raw = named
        let attributed = named.values.reduce(Int64(0), +)
        raw[.unmeasured] = max(0, used - attributed)
        raw[.free] = contract.capacityBytes - used

        return StorageSnapshot(
            id: id,
            measuredAt: measuredAt,
            trigger: trigger,
            contract: contract,
            volume: VolumeInfo(
                name: contract.volumeName,
                capacityBytes: contract.capacityBytes,
                freeBytes: contract.capacityBytes - used,
                filesystem: "apfs",
                isEncrypted: true
            ),
            rawSegments: raw,
            breakdown: StorageBreakdown.make(
                capacityBytes: contract.capacityBytes,
                rawSegments: raw,
                unreadableCount: 0
            ),
            nodes: nodes
        )
    }

    /// A recorded folder. `path` is home-relative unless it starts with a slash.
    static func node(
        _ path: String,
        _ bytes: Int64,
        identity: String? = nil,
        segment: StorageSegmentID = .documentsDesktop,
        fileCount: Int = 1
    ) -> SnapshotNode {
        let isAbsolute = path.hasPrefix("/")
        let full = isAbsolute ? path : "\(home)/\(path)"
        return SnapshotNode(
            path: full,
            identity: identity,
            allocatedBytes: bytes,
            fileCount: fileCount,
            depth: isAbsolute ? 0 : path.split(separator: "/").count,
            segment: segment
        )
    }
}
