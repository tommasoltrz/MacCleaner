import Foundation
import Testing
@testable import ScoloCore

@Suite("The measurement history and its retention rules")
struct StorageSnapshotStoreTests {

    private final class Sandbox {
        let directory: URL

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ScoloHistory-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var fileNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }
    }

    private func store(_ box: Sandbox, now: Date = GrowthFixture.noon) -> StorageSnapshotStore {
        StorageSnapshotStore(directory: box.directory, now: { now })
    }

    /// Minutes before noon, newest first when the offsets ascend.
    private func snapshot(
        minutesAgo: Double,
        trigger: SnapshotTrigger = .manual,
        used: Int64 = 100_000_000_000
    ) -> StorageSnapshot {
        GrowthFixture.snapshot(
            at: GrowthFixture.noon.addingTimeInterval(-minutesAgo * 60),
            trigger: trigger,
            used: used
        )
    }

    // MARK: - Writing and reading

    @Test("a measurement survives the round trip, dictionary keys included")
    func roundTrip() throws {
        let box = try Sandbox()
        let written = GrowthFixture.snapshot(
            trigger: .removal,
            used: 212_000_000_000,
            named: [.downloads: 20_000_000_000, .appDataCaches: 29_000_000_000],
            nodes: [
                GrowthFixture.node("Downloads", 20_000_000_000, identity: "1:2", segment: .downloads)
            ]
        )

        try store(box).save(written)
        let read = try #require(store(box).load().first)

        #expect(read == written)
        #expect(read.rawSegments[.downloads] == 20_000_000_000)
        #expect(read.nodes.first?.identity == "1:2")
    }

    @Test("a segment table is written as an object a person can read")
    func segmentTableIsAnObject() throws {
        let box = try Sandbox()
        let written = GrowthFixture.snapshot(used: 100_000_000_000, named: [.downloads: 20_000_000_000])
        try store(box).save(written)

        let name = try #require(box.fileNames.first)
        let text = try String(contentsOf: box.directory.appendingPathComponent(name), encoding: .utf8)

        // An object key, not the second element of a two-element array.
        #expect(text.contains("\"downloads\":20000000000"))
    }

    @Test("the file name carries the date and the trigger, and no colons")
    func fileNaming() throws {
        let box = try Sandbox()
        try store(box).save(snapshot(minutesAgo: 0, trigger: .cli))

        let name = try #require(box.fileNames.first)
        #expect(name.hasSuffix("-cli.json"))
        #expect(!name.contains(":"))
    }

    @Test("measurements come back newest first")
    func newestFirst() throws {
        let box = try Sandbox()
        let history = store(box)
        try history.save(snapshot(minutesAgo: 120))
        try history.save(snapshot(minutesAgo: 0))
        try history.save(snapshot(minutesAgo: 60))

        let dates = history.load().map(\.measuredAt)
        #expect(dates == dates.sorted(by: >))
        #expect(dates.count == 3, "three different hours, nothing thinned")
    }

    @Test("a file this store cannot read is skipped and counted, not deleted")
    func unreadableFile() throws {
        let box = try Sandbox()
        let history = store(box)
        try history.save(snapshot(minutesAgo: 0))
        let intruder = box.directory.appendingPathComponent("20260101T000000Z-launch.json")
        try Data("not a snapshot".utf8).write(to: intruder)

        let read = history.loadWithDiagnostics()

        #expect(read.snapshots.count == 1)
        #expect(read.unreadableCount == 1)
        #expect(FileManager.default.fileExists(atPath: intruder.path))
    }

    @Test("clearing the history leaves nothing behind")
    func clear() throws {
        let box = try Sandbox()
        let history = store(box)
        try history.save(snapshot(minutesAgo: 120))
        try history.save(snapshot(minutesAgo: 0))

        try history.clear()

        #expect(history.load().isEmpty)
        #expect(box.fileNames.isEmpty)
    }

    @Test("a history that was never written reads as empty, not as an error")
    func missingDirectory() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScoloHistory-absent-\(UUID().uuidString)")
        let history = StorageSnapshotStore(directory: missing, now: { GrowthFixture.noon })

        #expect(history.load().isEmpty)
        #expect(throws: Never.self) { try history.clear() }
    }

    // MARK: - Retention

    @Test("one measurement per hour is kept once the dense tail has passed")
    func hourThinning() {
        let sameHour = [1.0, 10, 20, 30, 40, 50].map { snapshot(minutesAgo: $0) }

        let kept = StorageSnapshotStore.survivors(of: sameHour, now: GrowthFixture.noon)

        #expect(kept.count == 2, "the two most recent, and no third in that hour")
        #expect(kept.map(\.measuredAt) == sameHour.prefix(2).map(\.measuredAt))
    }

    @Test("the two most recent measurements survive, so a comparison always exists")
    func denseTail() {
        // Both were taken in the same hour. Without this rule the Dashboard reports
        // "First measurement" straight after the user's second measurement.
        let pair = [snapshot(minutesAgo: 1), snapshot(minutesAgo: 15)]

        let kept = StorageSnapshotStore.survivors(of: pair, now: GrowthFixture.noon)

        #expect(kept.count == 2)
    }

    @Test("a clean-up measurement is never thinned away")
    func removalSurvivesThinning() {
        let sameHour = [
            snapshot(minutesAgo: 1),
            snapshot(minutesAgo: 10),
            snapshot(minutesAgo: 20),
            snapshot(minutesAgo: 30, trigger: .removal),
            snapshot(minutesAgo: 40)
        ]

        let kept = StorageSnapshotStore.survivors(of: sameHour, now: GrowthFixture.noon)

        #expect(kept.count == 3)
        #expect(kept.contains { $0.trigger == .removal })
    }

    @Test("nothing older than 30 days is kept")
    func ageCut() {
        let history = [
            snapshot(minutesAgo: 0),
            snapshot(minutesAgo: 60),
            snapshot(minutesAgo: 29 * 24 * 60),
            snapshot(minutesAgo: 31 * 24 * 60),
            snapshot(minutesAgo: 31 * 24 * 60 + 60, trigger: .removal)
        ]

        let kept = StorageSnapshotStore.survivors(of: history, now: GrowthFixture.noon)

        #expect(kept.count == 3)
        #expect(!kept.contains { GrowthFixture.noon.timeIntervalSince($0.measuredAt) > 30 * 24 * 3600 })
    }

    @Test("the file count is capped, and the oldest go first")
    func countCap() {
        // One per hour, so the hour thinning keeps every one of them.
        let history = (0..<(StorageSnapshotStore.maximumCount + 10)).map {
            snapshot(minutesAgo: Double($0) * 60)
        }

        let kept = StorageSnapshotStore.survivors(of: history, now: GrowthFixture.noon)

        #expect(kept.count == StorageSnapshotStore.maximumCount)
        #expect(kept.first?.measuredAt == history.first?.measuredAt)
        #expect(!kept.contains { $0.measuredAt == history.last?.measuredAt })
    }

    @Test("saving applies the retention rules to the files on disk")
    func savePrunes() throws {
        let box = try Sandbox()
        let history = store(box)
        for minutes in [50.0, 40, 30, 20, 10, 0] {
            try history.save(snapshot(minutesAgo: minutes))
        }

        #expect(box.fileNames.count == 2)
        #expect(history.load().map(\.measuredAt) == [
            GrowthFixture.noon,
            GrowthFixture.noon.addingTimeInterval(-600)
        ])
    }

    @Test("a clean-up baseline stays readable after later measurements")
    func savedRemovalSurvives() throws {
        let box = try Sandbox()
        let history = store(box)
        try history.save(snapshot(minutesAgo: 45, trigger: .removal))
        try history.save(snapshot(minutesAgo: 30))
        try history.save(snapshot(minutesAgo: 15))
        try history.save(snapshot(minutesAgo: 0))

        let stored = history.load()
        #expect(stored.count == 3)
        #expect(stored.contains { $0.trigger == .removal })

        let latest = try #require(stored.first)
        #expect(StorageGrowth.baseline(.lastCleanup, in: stored, latest: latest)?.trigger == .removal)
    }
}
