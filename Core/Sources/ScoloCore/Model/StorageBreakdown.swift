import Foundation

/// Semantic colour names. Core stays free of SwiftUI; the design system maps these
/// to `NSColor`/`Color`, preferring the platform's semantic colours so the app
/// follows the user's accent choice and Increase Contrast setting.
public enum ColorToken: String, Sendable, Equatable, Codable {
    case accent, green, orange, red, yellow, purple, teal, pink, brown
    case gray, warmGray, darkGray, freeSpace
}

public enum StorageSegmentID: String, Sendable, CaseIterable, Codable {
    case macOSSystem, systemData
    case documentsDesktop, downloads, photos, music, movies, developer
    case appDataCaches, packageBuildCaches, otherFilesInHome
    case applications
    case unmeasured
    /// Slivers merged together so the capacity bar has no unreadable hairlines.
    case other
    case free

    public var displayName: String {
        switch self {
        case .macOSSystem:        "macOS System"
        case .systemData:         "System Data"
        case .documentsDesktop:   "Documents & Desktop"
        case .downloads:          "Downloads"
        case .photos:             "Photos & Images"
        case .music:              "Music"
        case .movies:             "Movies & TV"
        case .developer:          "Developer"
        case .appDataCaches:      "App Data & Caches"
        case .packageBuildCaches: "Package & Build Caches"
        case .otherFilesInHome:   "Other Files in Home"
        case .applications:       "Applications"
        case .unmeasured:         "Unmeasured"
        case .other:              "Other"
        case .free:               "Free"
        }
    }

    public var color: ColorToken {
        switch self {
        case .macOSSystem:        .gray
        case .systemData:         .warmGray
        case .documentsDesktop:   .orange
        case .downloads:          .green
        case .photos:             .pink
        case .music:              .purple
        case .movies:             .red
        case .developer:          .yellow
        case .appDataCaches:      .teal
        case .packageBuildCaches: .purple
        // Brown, not pink: Photos & Images is pink, and the two sat side by side
        // in the legend wearing the same dot.
        case .otherFilesInHome:   .brown
        case .applications:       .accent
        case .unmeasured:         .darkGray
        case .other:              .gray
        case .free:               .freeSpace
        }
    }

    /// `Unmeasured` and `Free` are never folded into `Other`, however small.
    ///
    /// Hiding `Unmeasured` is what made the predecessor's numbers look plausible
    /// while being wrong: unattributed space was relabelled twice — first as "APFS
    /// Snapshots", then as "Other User Accounts" — and both were fabrications. It is
    /// the honest residual and it stays visible.
    var isMergeable: Bool {
        switch self {
        case .unmeasured, .free, .other: false
        default: true
        }
    }
}

public struct StorageSegment: Sendable, Equatable, Identifiable, Codable {
    public let id: StorageSegmentID
    public var bytes: Int64

    public var displayName: String { id.displayName }
    public var color: ColorToken { id.color }

    public init(id: StorageSegmentID, bytes: Int64) {
        self.id = id
        self.bytes = bytes
    }
}

/// A complete account of a volume: every byte of capacity lands in exactly one
/// segment, including free space and the unattributed remainder.
public struct StorageBreakdown: Sendable, Equatable, Codable {
    public let capacityBytes: Int64
    /// Descending by size, `Other` and `Free` last.
    public let segments: [StorageSegment]
    /// Entries an unprivileged scan could not read, summed across the run.
    public let unreadableCount: Int

    public var usedBytes: Int64 { capacityBytes - freeBytes }
    public var freeBytes: Int64 { segments.first { $0.id == .free }?.bytes ?? 0 }

    /// The Dashboard legend. Every measured segment stays visible so the listed
    /// figures add up to the disk capacity.
    public var legendEntries: [StorageSegment] {
        segments.filter { $0.bytes > 0 }
    }

    public func percent(of segment: StorageSegment) -> Double {
        guard capacityBytes > 0 else { return 0 }
        return Double(segment.bytes) / Double(capacityBytes) * 100
    }

    /// Aligns the volatile volume figures with a new disk snapshot. Named category
    /// measurements stay unchanged. Any change since the walk lands in Unmeasured.
    public func reconcilingVolume(
        capacityBytes newCapacityBytes: Int64,
        freeBytes requestedFreeBytes: Int64
    ) -> StorageBreakdown {
        let capacity = max(0, newCapacityBytes)
        let namedSegments = segments.filter { $0.id != .free && $0.id != .unmeasured }
        let namedBytes = namedSegments.reduce(0) { $0 + $1.bytes }

        // A smaller replacement volume cannot contain the measured categories.
        // Keep the measured snapshot until a new walk replaces it.
        guard namedBytes <= capacity else { return self }

        let maximumFreeBytes = capacity - namedBytes
        let freeBytes = min(max(0, requestedFreeBytes), maximumFreeBytes)
        let unmeasuredBytes = capacity - namedBytes - freeBytes

        var rawSegments = Dictionary(
            uniqueKeysWithValues: namedSegments.map { ($0.id, $0.bytes) }
        )
        rawSegments[.unmeasured] = unmeasuredBytes
        rawSegments[.free] = freeBytes

        // The measured categories have already been merged. A zero threshold keeps
        // them stable while the volatile figures change.
        return StorageBreakdown.make(
            capacityBytes: capacity,
            rawSegments: rawSegments,
            unreadableCount: unreadableCount,
            mergeThresholdPercent: 0
        )
    }

    /// Builds a breakdown from raw per-segment byte counts.
    ///
    /// Segments smaller than `mergeThresholdPercent` of capacity are folded into
    /// `Other` so the capacity bar never renders an illegible sliver.
    public static func make(
        capacityBytes: Int64,
        rawSegments: [StorageSegmentID: Int64],
        unreadableCount: Int,
        mergeThresholdPercent: Double = 0.5
    ) -> StorageBreakdown {
        let threshold = Int64(Double(capacityBytes) * mergeThresholdPercent / 100)

        var kept: [StorageSegment] = []
        var mergedBytes: Int64 = 0

        for (id, bytes) in rawSegments where bytes > 0 {
            if id.isMergeable && bytes < threshold {
                mergedBytes += bytes
            } else {
                kept.append(StorageSegment(id: id, bytes: bytes))
            }
        }

        kept.sort { lhs, rhs in
            // Free always renders last in the bar and legend.
            if lhs.id == .free { return false }
            if rhs.id == .free { return true }
            return lhs.bytes > rhs.bytes
        }
        if mergedBytes > 0 {
            let freeIndex = kept.firstIndex { $0.id == .free } ?? kept.endIndex
            kept.insert(StorageSegment(id: .other, bytes: mergedBytes), at: freeIndex)
        }

        return StorageBreakdown(
            capacityBytes: capacityBytes,
            segments: kept,
            unreadableCount: unreadableCount
        )
    }
}
