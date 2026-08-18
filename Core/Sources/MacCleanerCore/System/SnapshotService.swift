import Foundation

/// The sealed snapshot macOS is running from.
public struct BootSnapshotIdentity: Sendable, Equatable {
    public let uuid: String
    public let name: String
    /// The sealed System volume, e.g. `disk3s1`. Recorded only so deletions
    /// targeting it can be refused.
    public let systemVolumeDisk: String
}

/// A snapshot as shown in the UI. Presence in this list does not imply it can be
/// deleted — see `DeletableSnapshot`.
public struct SnapshotInfo: Sendable, Equatable, Identifiable {
    public var uuid: String
    public var name: String
    public var purgeable: Bool
    public var limitingContainerShrink: Bool
    /// True for the sealed volume macOS booted from. Rendered as the Dashboard's
    /// permanent "this is macOS itself, not reclaimable space" row.
    public var isBootSnapshot: Bool
    /// The volume it was enumerated from, verbatim. Never rewritten.
    public var volumeDisk: String

    public var id: String { uuid }

    /// Public so views can build preview fixtures. Note this constructs a
    /// *description* of a snapshot, never permission to delete one — that remains
    /// `DeletableSnapshot`, which only `SnapshotService` can mint.
    public init(
        uuid: String,
        name: String,
        purgeable: Bool,
        limitingContainerShrink: Bool,
        isBootSnapshot: Bool,
        volumeDisk: String
    ) {
        self.uuid = uuid
        self.name = name
        self.purgeable = purgeable
        self.limitingContainerShrink = limitingContainerShrink
        self.isBootSnapshot = isBootSnapshot
        self.volumeDisk = volumeDisk
    }
}

/// Proof that a snapshot is safe to delete.
///
/// **This type is the guard.** Its initializer is private to this file, and
/// `SnapshotService` is the only thing that can mint one — never for the boot
/// snapshot, never for anything enumerated from the System volume. Because the
/// deletion API accepts only this type, "delete the running OS" is not an expressible
/// program, rather than a mistake prevented by a runtime check someone can forget.
///
/// The predecessor did the opposite. It took the boot snapshot's volume `disk3s1s1`
/// and rewrote it to `disk3s1`, commented "to get the real parent volume which
/// accepts deleteSnapshot commands" — manufacturing a working delete target for the
/// operating system. Only SIP stopped it.
public struct DeletableSnapshot: Sendable, Equatable {
    public let uuid: String
    public let name: String
    /// Always a Data volume identifier, exactly as `diskutil` reported it.
    public let volumeDisk: String

    fileprivate init(uuid: String, name: String, volumeDisk: String) {
        self.uuid = uuid
        self.name = name
        self.volumeDisk = volumeDisk
    }
}

public enum SnapshotError: Error, Equatable {
    /// Attempted to delete the running system. Should be unreachable.
    case refusedBootSnapshot(String)
    case refusedSystemVolume(String)
}

/// Snapshot listing and deletion.
///
/// Only the **Data** volume is ever enumerated for deletion candidates. Time Machine
/// local snapshots live there; the System volume's only snapshot is the sealed boot
/// snapshot, so offering it is never correct.
public struct SnapshotService: Sendable {

    private let runner: ProcessRunner
    private let diskInfo: DiskInfoService

    public init(runner: ProcessRunner = ProcessRunner(), diskInfo: DiskInfoService? = nil) {
        self.runner = runner
        self.diskInfo = diskInfo ?? DiskInfoService(runner: runner)
    }

    // MARK: - Listing

    /// Everything to display: removable Data-volume snapshots plus the boot snapshot
    /// flagged as informational.
    public func listAll() async throws -> [SnapshotInfo] {
        let boot = try? await diskInfo.bootSnapshot()
        let data = try await runner.run(
            SystemExecutable.diskutil,
            ["apfs", "listSnapshots", "-plist", DiskInfoService.dataVolumeMountPoint]
        )
        let volumeDisk = try await dataVolumeIdentifier()
        var results = Self.parse(data, volumeDisk: volumeDisk, bootUUID: boot?.uuid)

        if let boot {
            results.append(SnapshotInfo(
                uuid: boot.uuid,
                name: boot.name,
                purgeable: false,
                limitingContainerShrink: true,
                isBootSnapshot: true,
                volumeDisk: boot.systemVolumeDisk
            ))
        }
        return results
    }

    /// The snapshots the app may offer to delete. The boot snapshot can never appear.
    public func deletableSnapshots() async throws -> [DeletableSnapshot] {
        let boot = try? await diskInfo.bootSnapshot()
        return try await listAll()
            .filter { !$0.isBootSnapshot && $0.uuid != boot?.uuid }
            .compactMap { candidate in
                try? Self.makeDeletable(candidate, boot: boot)
            }
    }

    // MARK: - Deletion

    /// Deletes a snapshot. Only ever reachable with a `DeletableSnapshot`.
    ///
    /// The guard is re-applied here even though the type already proves safety —
    /// belt and braces, matching how the Electron fix was hardened.
    public func delete(_ snapshot: DeletableSnapshot) async throws {
        let boot = try? await diskInfo.bootSnapshot()
        if let boot {
            guard snapshot.uuid != boot.uuid else {
                throw SnapshotError.refusedBootSnapshot(snapshot.uuid)
            }
            guard snapshot.volumeDisk != boot.systemVolumeDisk else {
                throw SnapshotError.refusedSystemVolume(snapshot.volumeDisk)
            }
        }

        // Deleting a snapshot needs admin rights; the GUI prompt is the consent step.
        let command = "diskutil apfs deleteSnapshot \(snapshot.volumeDisk) -uuid \(snapshot.uuid)"
        _ = try await runner.run(SystemExecutable.osascript, [
            "-e", "do shell script \"\(command)\" with administrator privileges"
        ], timeout: .seconds(120))
    }

    // MARK: - Internals

    private func dataVolumeIdentifier() async throws -> String {
        let data = try await runner.run(
            SystemExecutable.diskutil, ["info", "-plist", DiskInfoService.dataVolumeMountPoint]
        )
        return try DiskInfoService.decodeInfo(data).deviceIdentifier ?? ""
    }

    /// Mints a `DeletableSnapshot`, or refuses.
    static func makeDeletable(
        _ snapshot: SnapshotInfo,
        boot: BootSnapshotIdentity?
    ) throws -> DeletableSnapshot {
        if snapshot.isBootSnapshot {
            throw SnapshotError.refusedBootSnapshot(snapshot.uuid)
        }
        if let boot {
            if snapshot.uuid == boot.uuid {
                throw SnapshotError.refusedBootSnapshot(snapshot.uuid)
            }
            if snapshot.volumeDisk == boot.systemVolumeDisk {
                throw SnapshotError.refusedSystemVolume(snapshot.volumeDisk)
            }
        }
        return DeletableSnapshot(
            uuid: snapshot.uuid,
            name: snapshot.name,
            volumeDisk: snapshot.volumeDisk
        )
    }

    // MARK: - Parsing

    private struct SnapshotList: Decodable {
        var snapshots: [Entry]
        enum CodingKeys: String, CodingKey { case snapshots = "Snapshots" }

        struct Entry: Decodable {
            var uuid: String
            var name: String
            var purgeable: Bool?
            var limitingContainerShrink: Bool?
            enum CodingKeys: String, CodingKey {
                case uuid = "SnapshotUUID"
                case name = "SnapshotName"
                case purgeable = "Purgeable"
                case limitingContainerShrink = "LimitingContainerShrink"
            }
        }
    }

    static func parse(_ data: Data, volumeDisk: String, bootUUID: String?) -> [SnapshotInfo] {
        guard let list = try? PropertyListDecoder().decode(SnapshotList.self, from: data) else {
            return []
        }
        return list.snapshots.map { entry in
            SnapshotInfo(
                uuid: entry.uuid,
                name: entry.name,
                purgeable: entry.purgeable ?? false,
                limitingContainerShrink: entry.limitingContainerShrink ?? false,
                // Defence in depth: if the boot snapshot were ever returned by a
                // Data-volume listing, it is still flagged and never deletable.
                isBootSnapshot: bootUUID != nil && entry.uuid == bootUUID,
                volumeDisk: volumeDisk
            )
        }
    }
}
