import Foundation

/// A volume as the Dashboard's capacity card needs it.
public struct VolumeInfo: Sendable, Equatable, Codable {
    public var name: String
    /// APFS container capacity — what "of 228.27 GB used" refers to.
    public var capacityBytes: Int64
    public var freeBytes: Int64
    /// Container-wide usage: every volume in the container, not just this one.
    public var usedBytes: Int64 { max(0, capacityBytes - freeBytes) }
    public var filesystem: String
    public var isEncrypted: Bool

    /// Public so views can build preview fixtures without querying the real disk.
    public init(
        name: String,
        capacityBytes: Int64,
        freeBytes: Int64,
        filesystem: String,
        isEncrypted: Bool
    ) {
        self.name = name
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.filesystem = filesystem
        self.isEncrypted = isEncrypted
    }

    /// Renders the Dashboard eyebrow: `Macintosh HD · APFS · Encrypted`.
    public var eyebrow: String {
        var parts = [name, filesystem.uppercased()]
        if isEncrypted { parts.append("Encrypted") }
        return parts.joined(separator: " · ")
    }
}

/// The subset of `diskutil info -plist` we rely on.
///
/// Decoded with `PropertyListDecoder` rather than scraped with regexes. The Electron
/// version matched patterns against human-readable `diskutil` output, which broke
/// silently whenever a label shifted.
struct DiskUtilInfo: Decodable {
    var volumeName: String?
    var filesystemType: String?
    var deviceIdentifier: String?
    var containerSize: Int64?
    var containerFree: Int64?
    var capacityInUse: Int64?
    var encryption: Bool?
    var isSnapshot: Bool?
    var snapshotName: String?
    var snapshotUUID: String?

    enum CodingKeys: String, CodingKey {
        case volumeName = "VolumeName"
        case filesystemType = "FilesystemType"
        case deviceIdentifier = "DeviceIdentifier"
        case containerSize = "APFSContainerSize"
        case containerFree = "APFSContainerFree"
        case capacityInUse = "CapacityInUse"
        case encryption = "Encryption"
        case isSnapshot = "APFSSnapshot"
        case snapshotName = "APFSSnapshotName"
        case snapshotUUID = "APFSSnapshotUUID"
    }
}

public struct DiskInfoService: Sendable {

    /// The Data volume's mount point.
    ///
    /// Everything user-writable lives here. It must be addressed by this path and
    /// not through `/`, because firmlinks make `/System` resolve to the read-only
    /// System volume while the Data volume carries its *own* `/System` tree.
    public static let dataVolumeMountPoint = "/System/Volumes/Data"

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    // MARK: - Live queries

    public func volumeInfo() async throws -> VolumeInfo {
        Self.volumeInfo(from: try await info(for: "/"))
    }

    /// Bytes consumed by the Data volume alone.
    public func dataVolumeUsedBytes() async throws -> Int64 {
        try await info(for: Self.dataVolumeMountPoint).capacityInUse ?? 0
    }

    /// Identifies the sealed snapshot macOS is currently booted from.
    public func bootSnapshot() async throws -> BootSnapshotIdentity? {
        Self.bootSnapshot(from: try await info(for: "/"))
    }

    private func info(for path: String) async throws -> DiskUtilInfo {
        let data = try await runner.run(SystemExecutable.diskutil, ["info", "-plist", path])
        return try PropertyListDecoder().decode(DiskUtilInfo.self, from: data)
    }

    // MARK: - Pure parsing (fixture-tested)

    static func volumeInfo(from info: DiskUtilInfo) -> VolumeInfo {
        VolumeInfo(
            name: info.volumeName ?? "Macintosh HD",
            capacityBytes: info.containerSize ?? 0,
            freeBytes: info.containerFree ?? 0,
            filesystem: info.filesystemType ?? "apfs",
            isEncrypted: info.encryption ?? false
        )
    }

    static func bootSnapshot(from info: DiskUtilInfo) -> BootSnapshotIdentity? {
        guard info.isSnapshot == true,
              let uuid = info.snapshotUUID,
              let name = info.snapshotName else { return nil }
        // "disk3s1s1" is the snapshot volume; its parent "disk3s1" is the sealed
        // System volume. Both are recorded so deletions targeting either can be
        // refused — never to construct a delete target.
        let node = info.deviceIdentifier ?? ""
        let systemVolume = node.replacingOccurrences(
            of: "s[0-9]+$", with: "", options: .regularExpression
        )
        return BootSnapshotIdentity(uuid: uuid, name: name, systemVolumeDisk: systemVolume)
    }

    static func decodeInfo(_ data: Data) throws -> DiskUtilInfo {
        try PropertyListDecoder().decode(DiskUtilInfo.self, from: data)
    }
}
