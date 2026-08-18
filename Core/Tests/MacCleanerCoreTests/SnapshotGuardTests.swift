import Foundation
import Testing
@testable import MacCleanerCore

/// Fixtures are real `diskutil -plist` output recorded from the development machine,
/// so parsing is tested against the actual format rather than an idealised one.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }
}

@Suite("diskutil plist parsing")
struct DiskUtilParsingTests {

    @Test("root volume info decodes container capacity, not volume capacity")
    func rootVolumeInfo() throws {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        let volume = DiskInfoService.volumeInfo(from: info)

        #expect(volume.name == "Macintosh HD")
        #expect(volume.filesystem == "apfs")
        #expect(volume.isEncrypted)
        // The Dashboard hero compares against container capacity — 228.27 GB.
        #expect(volume.capacityBytes == 245_107_195_904)
        #expect(volume.freeBytes > 0)
        #expect(volume.usedBytes == volume.capacityBytes - volume.freeBytes)
    }

    @Test("the eyebrow string matches the design")
    func eyebrow() throws {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        #expect(DiskInfoService.volumeInfo(from: info).eyebrow == "Macintosh HD · APFS · Encrypted")
    }

    @Test("the Data volume reports its own usage, distinct from the container")
    func dataVolumeUsage() throws {
        let root = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        let data = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-data.plist"))

        // The System volume is small; the Data volume holds nearly everything. The
        // difference is what "macOS System" is derived from.
        #expect(data.capacityInUse! > root.capacityInUse!)
    }
}

@Suite("Boot snapshot guard")
struct SnapshotGuardTests {

    private func bootIdentity() throws -> BootSnapshotIdentity {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        return try #require(DiskInfoService.bootSnapshot(from: info))
    }

    @Test("the boot snapshot is identified from the root volume")
    func identifiesBootSnapshot() throws {
        let boot = try bootIdentity()
        #expect(boot.uuid == "D5D09086-4626-4187-B4B0-286AA2C52889")
        #expect(boot.name.hasPrefix("com.apple.os.update-"))
        // disk3s1s1 (the snapshot volume) reduces to disk3s1 (the sealed System
        // volume). Recorded to refuse deletes — never to target one.
        #expect(boot.systemVolumeDisk == "disk3s1")
    }

    @Test("a Data-volume listing with no snapshots yields nothing to delete")
    func emptyDataVolume() throws {
        let parsed = SnapshotService.parse(
            try Fixture.data("snapshots-data-empty.plist"),
            volumeDisk: "disk3s5",
            bootUUID: try bootIdentity().uuid
        )
        #expect(parsed.isEmpty)
    }

    @Test("the boot snapshot can never be turned into a deletable snapshot")
    func refusesBootSnapshot() throws {
        let boot = try bootIdentity()
        // Exactly what `diskutil apfs listSnapshots /` returns — the trap the old
        // code walked into.
        let listed = SnapshotService.parse(
            try Fixture.data("snapshots-root-boot.plist"),
            volumeDisk: boot.systemVolumeDisk,
            bootUUID: boot.uuid
        )
        let entry = try #require(listed.first)
        #expect(entry.isBootSnapshot)

        #expect(throws: SnapshotError.refusedBootSnapshot(boot.uuid)) {
            _ = try SnapshotService.makeDeletable(entry, boot: boot)
        }
    }

    @Test("anything on the sealed System volume is refused, even with another UUID")
    func refusesSystemVolume() throws {
        let boot = try bootIdentity()
        let impostor = SnapshotInfo(
            uuid: "00000000-0000-0000-0000-000000000000",
            name: "com.apple.os.update-something-else",
            purgeable: true,
            limitingContainerShrink: false,
            isBootSnapshot: false,
            volumeDisk: boot.systemVolumeDisk      // disk3s1
        )
        #expect(throws: SnapshotError.refusedSystemVolume(boot.systemVolumeDisk)) {
            _ = try SnapshotService.makeDeletable(impostor, boot: boot)
        }
    }

    @Test("a genuine Time Machine snapshot on the Data volume is deletable")
    func allowsDataVolumeSnapshot() throws {
        let boot = try bootIdentity()
        let timeMachine = SnapshotInfo(
            uuid: "11111111-2222-3333-4444-555555555555",
            name: "com.apple.TimeMachine.2026-08-18-000000.local",
            purgeable: true,
            limitingContainerShrink: false,
            isBootSnapshot: false,
            volumeDisk: "disk3s5"
        )
        let deletable = try SnapshotService.makeDeletable(timeMachine, boot: boot)
        #expect(deletable.uuid == timeMachine.uuid)
        // The volume identifier survives verbatim. Any rewriting here is the bug.
        #expect(deletable.volumeDisk == "disk3s5")
    }

    @Test("the volume identifier is never rewritten toward the System volume")
    func neverRewritesVolumeIdentifier() throws {
        let boot = try bootIdentity()
        let snapshot = SnapshotInfo(
            uuid: "22222222-3333-4444-5555-666666666666",
            name: "com.apple.TimeMachine.local",
            purgeable: true,
            limitingContainerShrink: false,
            isBootSnapshot: false,
            volumeDisk: "disk3s5"
        )
        let deletable = try SnapshotService.makeDeletable(snapshot, boot: boot)
        #expect(deletable.volumeDisk != boot.systemVolumeDisk)
        #expect(deletable.volumeDisk != "disk3s1")
    }
}
