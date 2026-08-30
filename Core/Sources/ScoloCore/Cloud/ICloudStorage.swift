import Foundation

/// What iCloud is holding, and how much of it we can actually account for.
///
/// Only two of the figures Apple shows are obtainable without private API: the free
/// space, which `brctl quota` reports exactly, and iCloud Drive, which can be
/// measured by walking the ubiquity container. Photos, device backups and Mail have
/// no public interface at all — so rather than guess at them, everything unaccounted
/// for is reported as `Unmeasured`, the same honest residual the disk breakdown uses.
public struct ICloudStorage: Sendable, Equatable, Codable {

    /// The plan size. See `ICloudStorageService.inferPlan` for where this comes from
    /// when the user has not set it — there is no API for it.
    public let totalBytes: Int64
    /// Reported by `brctl quota`, exactly.
    public let freeBytes: Int64
    /// iCloud Drive, measured by walking the ubiquity container. Counts what is *in
    /// iCloud*, not what has been downloaded — an evicted file still occupies quota.
    public let documentsBytes: Int64
    /// How much of `documentsBytes` is also on this Mac. The gap between the two is
    /// what evicting has already saved locally.
    public let documentsOnDiskBytes: Int64
    /// True when `totalBytes` was guessed from the free space rather than set by the
    /// user, so the UI can avoid stating it as fact.
    public let planWasInferred: Bool
    /// Ubiquitous items that could not be read.
    public let unreadableCount: Int
    public let measuredAt: Date

    public init(
        totalBytes: Int64,
        freeBytes: Int64,
        documentsBytes: Int64,
        documentsOnDiskBytes: Int64 = 0,
        planWasInferred: Bool = true,
        unreadableCount: Int = 0,
        measuredAt: Date = Date()
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.documentsBytes = documentsBytes
        self.documentsOnDiskBytes = documentsOnDiskBytes
        self.planWasInferred = planWasInferred
        self.unreadableCount = unreadableCount
        self.measuredAt = measuredAt
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// Everything in iCloud that is not iCloud Drive — in practice Photos, the device
    /// backup and Mail. Named for what it is: not measured.
    ///
    /// Clamped at zero because the two figures come from different sources and a
    /// Drive measurement taken moments after the quota reading can legitimately
    /// exceed it. A negative segment would render as a glitch and imply precision
    /// neither number has.
    public var unmeasuredBytes: Int64 { max(0, usedBytes - documentsBytes) }

    public var segments: [ICloudSegment] {
        [
            ICloudSegment(id: .documents, bytes: documentsBytes),
            ICloudSegment(id: .unmeasured, bytes: unmeasuredBytes),
            ICloudSegment(id: .free, bytes: freeBytes)
        ].filter { $0.bytes > 0 }
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    /// True when the account is close enough to full to be worth flagging.
    public var isNearlyFull: Bool { usedFraction >= 0.9 }
}

public enum ICloudSegmentID: String, Sendable, Codable, CaseIterable {
    case documents, unmeasured, free

    public var displayName: String {
        switch self {
        case .documents:  "iCloud Drive"
        case .unmeasured: "Unmeasured"
        case .free:       "Free"
        }
    }

    /// What the segment covers, for the row's tooltip. `Unmeasured` says plainly why
    /// it cannot be broken down rather than leaving the user to wonder.
    public var explanation: String? {
        switch self {
        case .documents:
            "Documents and app data in iCloud Drive, including files not downloaded here."
        case .unmeasured:
            "Photos, device backups and Mail. macOS exposes no public way to measure "
                + "these, so they are reported together rather than guessed at."
        case .free:
            nil
        }
    }

    public var color: ColorToken {
        switch self {
        case .documents:  .accent
        case .unmeasured: .gray
        case .free:       .freeSpace
        }
    }
}

public struct ICloudSegment: Sendable, Equatable, Codable, Identifiable {
    public let id: ICloudSegmentID
    public var bytes: Int64

    public init(id: ICloudSegmentID, bytes: Int64) {
        self.id = id
        self.bytes = bytes
    }

    public var displayName: String { id.displayName }
    public var color: ColorToken { id.color }
}
