import Foundation

/// Turns a finished measurement into a snapshot the growth report can read.
///
/// Pure, and every source of variation is a parameter: the clock, the identifier,
/// the thresholds and the snapshot's own identifier. A test builds a measurement by
/// hand and gets the same snapshot every run.
public enum SnapshotCapture {

    /// Directories below this size are not recorded.
    ///
    /// A snapshot is a record of *where the disk went*, not an index of the disk. At
    /// 100 MB the user's home produces a few hundred nodes; at 1 MB it produces tens
    /// of thousands, and the report would still refuse to name any of them, because
    /// nothing under 100 MB survives the attribution threshold either.
    public static let defaultMinimumNodeBytes: Int64 = 100_000_000

    /// A hard stop on the file size, in case a disk holds far more large folders
    /// than the user's does. The largest are kept.
    public static let defaultMaximumNodes = 5_000

    /// Builds a snapshot, or returns `nil` if the measurement does not add up.
    ///
    /// The capacity contract is checked before anything is stored: a breakdown whose
    /// segments do not sum to capacity is a measurement that went wrong, and storing
    /// it would put a wrong figure into every future comparison. A dropped snapshot
    /// costs one comparison; a stored bad one poisons the history.
    ///
    /// - Parameters:
    ///   - identity: reads a directory's `device:inode`. One `lstat` per recorded
    ///     node — a few hundred on the user's Mac. Injected so tests do not need a
    ///     real filesystem.
    public static func snapshot(
        from measurement: StorageMeasurement,
        trigger: SnapshotTrigger,
        now: Date = Date(),
        id: UUID = UUID(),
        minimumNodeBytes: Int64 = SnapshotCapture.defaultMinimumNodeBytes,
        maximumNodes: Int = SnapshotCapture.defaultMaximumNodes,
        identity: (URL) -> String? = FileIdentity.of
    ) -> StorageSnapshot? {
        guard measurement.breakdown.isConsistent else { return nil }

        let home = measurement.home.standardizedFileURL
        var nodes: [SnapshotNode] = []

        // Machine-wide roots first. Each is one measured tree owned by one segment,
        // and each sits at depth 0 because none of them is below home.
        for (url, size) in measurement.rootMeasurements {
            guard size.allocatedBytes >= minimumNodeBytes,
                  let segment = StorageBreakdownService.segment(forRoot: url) else { continue }
            nodes.append(SnapshotNode(
                path: url.standardizedFileURL.path,
                identity: identity(url),
                allocatedBytes: size.allocatedBytes,
                fileCount: size.fileCount,
                depth: 0,
                segment: segment
            ))
        }

        // Then everything under home. `$HOME` itself is skipped: it holds every home
        // segment at once, so no segment owns it, and a change to the whole of home
        // names no place. The report says that with a segment line instead.
        for (url, size) in measurement.homeTree {
            guard size.allocatedBytes >= minimumNodeBytes else { continue }
            guard let components = homeRelativeComponents(of: url, under: home),
                  let segment = StorageBreakdownService.segment(
                      forHomeRelativeComponents: components
                  ) else { continue }
            nodes.append(SnapshotNode(
                path: url.standardizedFileURL.path,
                identity: identity(url),
                allocatedBytes: size.allocatedBytes,
                fileCount: size.fileCount,
                depth: components.count,
                segment: segment
            ))
        }

        // Largest first, then capped: if the cap has to bite, the folders that can
        // explain a change are the ones worth keeping.
        nodes.sort { lhs, rhs in
            lhs.allocatedBytes == rhs.allocatedBytes
                ? lhs.path < rhs.path
                : lhs.allocatedBytes > rhs.allocatedBytes
        }
        if nodes.count > maximumNodes { nodes.removeLast(nodes.count - maximumNodes) }

        return StorageSnapshot(
            id: id,
            measuredAt: now,
            trigger: trigger,
            contract: MeasurementContract(
                homePath: home.path,
                volumeName: measurement.volume.name,
                capacityBytes: measurement.volume.capacityBytes,
                nodeDepth: measurement.nodeDepth,
                minimumNodeBytes: minimumNodeBytes
            ),
            volume: measurement.volume,
            rawSegments: measurement.rawSegments,
            breakdown: measurement.breakdown,
            nodes: nodes
        )
    }

    /// The path components of `url` below `home`, or `nil` if it is not below home.
    ///
    /// Compared component by component rather than by string prefix: `/Users/me2`
    /// starts with the characters of `/Users/me` and is a different person's folder.
    /// `$HOME` itself returns an empty array, which the caller skips.
    static func homeRelativeComponents(of url: URL, under home: URL) -> [String]? {
        let homeComponents = home.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= homeComponents.count,
              Array(urlComponents.prefix(homeComponents.count)) == homeComponents
        else { return nil }
        return Array(urlComponents.dropFirst(homeComponents.count))
    }
}
