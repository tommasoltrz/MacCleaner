import Foundation
import Testing
@testable import ScoloCore

@Suite("Capturing a measurement as a snapshot")
struct SnapshotCaptureTests {

    private let home = URL(fileURLWithPath: "/Users/tester")

    /// A measurement whose breakdown adds up, so capture is not refused for the
    /// wrong reason.
    private func measurement(
        homeTree: [String: Int64],
        roots: [String: Int64] = [:],
        used: Int64 = 100_000_000_000,
        capacity: Int64 = GrowthFixture.capacity
    ) -> StorageMeasurement {
        let raw: [StorageSegmentID: Int64] = [.unmeasured: used, .free: capacity - used]
        var tree: [URL: SizeMeasurement] = [:]
        for (path, bytes) in homeTree {
            let url = path.isEmpty ? home : home.appendingPathComponent(path)
            tree[url.standardizedFileURL] = SizeMeasurement(allocatedBytes: bytes, fileCount: 3)
        }
        var rootMeasurements: [URL: SizeMeasurement] = [:]
        for (path, bytes) in roots {
            rootMeasurements[URL(fileURLWithPath: path).standardizedFileURL] =
                SizeMeasurement(allocatedBytes: bytes, fileCount: 5)
        }
        return StorageMeasurement(
            home: home,
            volume: VolumeInfo(
                name: "Macintosh HD",
                capacityBytes: capacity,
                freeBytes: capacity - used,
                filesystem: "apfs",
                isEncrypted: true
            ),
            breakdown: StorageBreakdown.make(
                capacityBytes: capacity, rawSegments: raw, unreadableCount: 0
            ),
            rawSegments: raw,
            homeTree: tree,
            rootMeasurements: rootMeasurements,
            nodeDepth: 4
        )
    }

    private func capture(
        _ measurement: StorageMeasurement,
        minimumNodeBytes: Int64 = 100_000_000,
        maximumNodes: Int = 5_000
    ) -> StorageSnapshot? {
        SnapshotCapture.snapshot(
            from: measurement,
            trigger: .manual,
            now: GrowthFixture.noon,
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000FEED")!,
            minimumNodeBytes: minimumNodeBytes,
            maximumNodes: maximumNodes,
            identity: { "id:\($0.lastPathComponent)" }
        )
    }

    @Test("a folder below the threshold is not recorded")
    func threshold() throws {
        let snapshot = try #require(capture(measurement(homeTree: [
            "Downloads": 4_000_000_000,
            "Music": 99_999_999
        ])))

        #expect(snapshot.nodes.map(\.path) == ["/Users/tester/Downloads"])
        #expect(snapshot.contract.minimumNodeBytes == 100_000_000)
    }

    @Test("home itself is not a node, because no one segment owns it")
    func homeIsNotANode() throws {
        let snapshot = try #require(capture(measurement(homeTree: [
            "": 90_000_000_000,
            "Downloads": 4_000_000_000
        ])))

        #expect(!snapshot.nodes.contains { $0.path == "/Users/tester" })
        #expect(snapshot.nodes.count == 1)
    }

    @Test("the home Library is not a node either: it holds four segments at once")
    func homeLibraryIsNotANode() throws {
        let snapshot = try #require(capture(measurement(homeTree: [
            "Library": 40_000_000_000,
            "Library/Application Support": 20_000_000_000,
            "Library/Caches": 10_000_000_000,
            "Library/Caches/Homebrew": 6_000_000_000,
            "Library/Developer": 3_000_000_000
        ])))
        let bySegment = Dictionary(
            uniqueKeysWithValues: snapshot.nodes.map { ($0.path, $0.segment) }
        )

        #expect(bySegment["/Users/tester/Library"] == nil)
        #expect(bySegment["/Users/tester/Library/Application Support"] == .appDataCaches)
        #expect(bySegment["/Users/tester/Library/Caches"] == .appDataCaches)
        #expect(bySegment["/Users/tester/Library/Caches/Homebrew"] == .packageBuildCaches)
        #expect(bySegment["/Users/tester/Library/Developer"] == .developer)
    }

    @Test("each folder is filed under the segment that counts its bytes")
    func segmentMapping() throws {
        let snapshot = try #require(capture(measurement(
            homeTree: [
                "Documents": 1_000_000_000,
                "Desktop": 1_000_000_000,
                "Downloads": 1_000_000_000,
                "Pictures": 1_000_000_000,
                "Music": 1_000_000_000,
                "Movies": 1_000_000_000,
                "Applications": 1_000_000_000,
                ".npm": 1_000_000_000,
                "Renewals": 1_000_000_000
            ],
            roots: [
                "/Applications": 20_000_000_000,
                "/Library": 9_000_000_000,
                "/System/Volumes/Data/System": 13_000_000_000,
                "/tmp": 8_000_000_000
            ]
        )))
        let bySegment = Dictionary(
            uniqueKeysWithValues: snapshot.nodes.map { ($0.path, $0.segment) }
        )

        #expect(bySegment["/Users/tester/Documents"] == .documentsDesktop)
        #expect(bySegment["/Users/tester/Desktop"] == .documentsDesktop)
        #expect(bySegment["/Users/tester/Downloads"] == .downloads)
        #expect(bySegment["/Users/tester/Pictures"] == .photos)
        #expect(bySegment["/Users/tester/Music"] == .music)
        #expect(bySegment["/Users/tester/Movies"] == .movies)
        #expect(bySegment["/Users/tester/Applications"] == .applications)
        #expect(bySegment["/Users/tester/.npm"] == .packageBuildCaches)
        #expect(bySegment["/Users/tester/Renewals"] == .otherFilesInHome)
        #expect(bySegment["/Applications"] == .applications)
        #expect(bySegment["/Library"] == .systemData)
        #expect(bySegment["/System/Volumes/Data/System"] == .macOSSystem)
        #expect(bySegment["/tmp"] == nil, "a root this service does not measure is not filed")
    }

    @Test("depth counts levels below home; a machine-wide root is depth 0")
    func depth() throws {
        let snapshot = try #require(capture(measurement(
            homeTree: [
                "Documents": 4_000_000_000,
                "Documents/Renewals": 3_000_000_000,
                "Documents/Renewals/build": 2_000_000_000
            ],
            roots: ["/Applications": 20_000_000_000]
        )))
        let byDepth = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.path, $0.depth) })

        #expect(byDepth["/Applications"] == 0)
        #expect(byDepth["/Users/tester/Documents"] == 1)
        #expect(byDepth["/Users/tester/Documents/Renewals"] == 2)
        #expect(byDepth["/Users/tester/Documents/Renewals/build"] == 3)
    }

    @Test("when the cap bites, the largest folders are the ones kept")
    func maximumNodes() throws {
        var tree: [String: Int64] = [:]
        for index in 1...10 { tree["Documents/f\(index)"] = Int64(index) * 1_000_000_000 }

        let snapshot = try #require(capture(measurement(homeTree: tree), maximumNodes: 3))

        #expect(snapshot.nodes.map(\.allocatedBytes)
            == [10_000_000_000, 9_000_000_000, 8_000_000_000])
    }

    @Test("the identity of every node comes from the injected reader")
    func identityIsInjected() throws {
        let snapshot = try #require(capture(measurement(homeTree: [
            "Downloads": 4_000_000_000
        ])))

        #expect(snapshot.nodes.first?.identity == "id:Downloads")
    }

    @Test("a measurement that does not add up is not stored at all")
    func refusesAnInconsistentMeasurement() {
        var broken = measurement(homeTree: ["Downloads": 4_000_000_000])
        broken = StorageMeasurement(
            home: broken.home,
            volume: broken.volume,
            // One byte of capacity is unaccounted for. The CLI calls this drift, and
            // drift must be zero.
            breakdown: StorageBreakdown(
                capacityBytes: GrowthFixture.capacity,
                segments: [StorageSegment(id: .free, bytes: GrowthFixture.capacity - 1)],
                unreadableCount: 0
            ),
            rawSegments: broken.rawSegments,
            homeTree: broken.homeTree,
            rootMeasurements: broken.rootMeasurements,
            nodeDepth: broken.nodeDepth
        )

        #expect(!broken.breakdown.isConsistent)
        #expect(capture(broken) == nil)
    }

    @Test("the contract records the rules the measurement was made under")
    func contract() throws {
        let snapshot = try #require(capture(measurement(homeTree: [
            "Downloads": 4_000_000_000
        ])))

        #expect(snapshot.contract.version == MeasurementContract.currentVersion)
        #expect(snapshot.contract.homePath == "/Users/tester")
        #expect(snapshot.contract.volumeName == "Macintosh HD")
        #expect(snapshot.contract.capacityBytes == GrowthFixture.capacity)
        #expect(snapshot.contract.nodeDepth == 4)
        #expect(snapshot.measuredAt == GrowthFixture.noon)
        #expect(snapshot.trigger == .manual)
    }

    @Test("a folder outside home is not mistaken for one inside it")
    func homeRelativeComponents() {
        let home = URL(fileURLWithPath: "/Users/me")

        #expect(SnapshotCapture.homeRelativeComponents(
            of: URL(fileURLWithPath: "/Users/me/Documents/Renewals"), under: home
        ) == ["Documents", "Renewals"])
        #expect(SnapshotCapture.homeRelativeComponents(of: home, under: home) == [])
        // "/Users/me2" starts with the characters of "/Users/me" and is someone else.
        #expect(SnapshotCapture.homeRelativeComponents(
            of: URL(fileURLWithPath: "/Users/me2/Documents"), under: home
        ) == nil)
        #expect(SnapshotCapture.homeRelativeComponents(
            of: URL(fileURLWithPath: "/Applications"), under: home
        ) == nil)
    }

    // MARK: - End to end, on a real tree

    @Test("a folder that grew on disk is the folder the report names")
    func endToEndOnATemporaryTree() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScoloGrowth-\(UUID().uuidString)")
        let build = root.appendingPathComponent("Documents/Renewals/build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = build.appendingPathComponent("output.bin")
        try Data(repeating: 1, count: 100_000).write(to: output)
        let before = try await realMeasurement(home: root, trigger: .launch)

        try Data(repeating: 1, count: 4_000_000).write(to: output)
        let after = try await realMeasurement(home: root, trigger: .scan)

        let comparison = StorageGrowth.compare(
            baseline: before,
            latest: after,
            minimumAttributionBytes: 500_000
        )
        let report = try #require(comparison.report)
        let attribution = try #require(report.attributions.first)

        #expect(report.attributions.count == 1)
        #expect(attribution.path == build.standardizedFileURL.path)
        #expect(attribution.kind == .grew)
        #expect(attribution.segment == .documentsDesktop)
        #expect(attribution.deltaBytes > 3_500_000)
    }

    /// Walks a real tree, then wraps it in the smallest consistent measurement that
    /// carries it. Only the walk is real; the volume figures are fixtures.
    private func realMeasurement(
        home: URL,
        trigger: SnapshotTrigger
    ) async throws -> StorageSnapshot {
        let tree = try await AllocatedSizeMeasurer().measureSubtrees(of: home, depth: 4)
        let used = tree[home.standardizedFileURL]?.allocatedBytes ?? 0
        let capacity = GrowthFixture.capacity
        let documents = tree[home.appendingPathComponent("Documents").standardizedFileURL]?
            .allocatedBytes ?? 0
        let raw: [StorageSegmentID: Int64] = [
            .documentsDesktop: documents,
            .unmeasured: used - documents,
            .free: capacity - used
        ]
        let measurement = StorageMeasurement(
            home: home,
            volume: VolumeInfo(
                name: "Macintosh HD",
                capacityBytes: capacity,
                freeBytes: capacity - used,
                filesystem: "apfs",
                isEncrypted: true
            ),
            breakdown: StorageBreakdown.make(
                capacityBytes: capacity, rawSegments: raw, unreadableCount: 0
            ),
            rawSegments: raw,
            homeTree: tree,
            rootMeasurements: [:],
            nodeDepth: 4
        )
        return try #require(SnapshotCapture.snapshot(
            from: measurement,
            trigger: trigger,
            now: GrowthFixture.noon,
            minimumNodeBytes: 1_000
        ))
    }
}
