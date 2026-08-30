import Foundation

/// Which stored measurement the report compares against.
public enum GrowthBaseline: String, Codable, Sendable, CaseIterable {
    case previousMeasurement
    case sevenDays
    case lastCleanup

    /// Interface text. The report names the baseline's real date beside this, because
    /// "7 days" is a request and the date is what was actually found.
    public var displayName: String {
        switch self {
        case .previousMeasurement: "Previous measurement"
        case .sevenDays:           "7 days"
        case .lastCleanup:         "Last clean-up"
        }
    }
}

/// The five answers to "whose space is this?".
///
/// Twelve segments is the right level of detail for a capacity card and the wrong
/// level for a change: a user reading "what grew" wants to know whether it was their
/// own files, an application filling its caches, or macOS. The segments stay
/// available underneath.
public enum GrowthClass: String, Sendable, CaseIterable, Codable {
    /// Documents, Desktop, Downloads, Pictures, Music, Movies, Developer and
    /// everything else in home that no other segment names.
    case user
    case applications
    /// Application support folders and package or build caches. Mostly churn, and
    /// mostly regenerable.
    case appDataAndCaches
    case macOS
    /// Space no unprivileged measurement can reach, plus any part of the change the
    /// named segments do not account for.
    case unmeasured

    public var displayName: String {
        switch self {
        case .user:             "Your Files"
        case .applications:     "Applications"
        case .appDataAndCaches: "App Data & Caches"
        case .macOS:            "macOS"
        case .unmeasured:       "Unmeasured"
        }
    }

    /// The legend dot, taken from the segment that dominates the class.
    public var color: ColorToken {
        switch self {
        case .user:             .orange
        case .applications:     .accent
        case .appDataAndCaches: .teal
        case .macOS:            .gray
        case .unmeasured:       .darkGray
        }
    }

    public static func of(_ segment: StorageSegmentID) -> GrowthClass {
        switch segment {
        case .documentsDesktop, .downloads, .photos, .music, .movies,
             .developer, .otherFilesInHome:
            .user
        case .applications:
            .applications
        case .appDataCaches, .packageBuildCaches:
            .appDataAndCaches
        case .macOSSystem, .systemData:
            .macOS
        // `other` never appears in a raw segment table — it is made by the merge —
        // and `free` is excluded before this is called. Both are named honestly
        // rather than filed under a category that did not produce them.
        case .unmeasured, .other, .free:
            .unmeasured
        }
    }
}

/// One place that explains part of the change.
public struct GrowthAttribution: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable {
        case grew
        case shrank
        /// Absent from the baseline. The delta is the whole size.
        case appeared
        /// Absent from the latest measurement. The delta is the whole size, negative.
        case disappeared
        /// The same directory, by `device:inode`, that used to be at this path.
        case movedIn(from: String)
        /// The same directory, by `device:inode`, that is now at this path.
        case movedOut(to: String)
    }

    /// Absolute path. `FileEntry.abbreviate` renders it for the interface.
    public let path: String
    public let segment: StorageSegmentID
    public let deltaBytes: Int64
    public let kind: Kind

    public var id: String { path }

    public init(path: String, segment: StorageSegmentID, deltaBytes: Int64, kind: Kind) {
        self.path = path
        self.segment = segment
        self.deltaBytes = deltaBytes
        self.kind = kind
    }
}

/// What changed between two measurements.
public struct StorageGrowthReport: Sendable, Equatable {
    public let baseline: StorageSnapshot
    public let latest: StorageSnapshot

    /// The change in used space, taken from the volume itself. This is the figure
    /// the report leads with, because it is the one the disk agrees with.
    public let usedDeltaBytes: Int64

    /// Per-segment changes, from the raw tables and excluding `Free`. Only segments
    /// that actually changed appear.
    public let segmentDeltas: [StorageSegmentID: Int64]

    /// The same change in five classes. All five are always present, and they sum
    /// to ``usedDeltaBytes``.
    public let classDeltas: [GrowthClass: Int64]

    /// The places that explain the change, largest first.
    public let attributions: [GrowthAttribution]

    public init(
        baseline: StorageSnapshot,
        latest: StorageSnapshot,
        usedDeltaBytes: Int64,
        segmentDeltas: [StorageSegmentID: Int64],
        classDeltas: [GrowthClass: Int64],
        attributions: [GrowthAttribution]
    ) {
        self.baseline = baseline
        self.latest = latest
        self.usedDeltaBytes = usedDeltaBytes
        self.segmentDeltas = segmentDeltas
        self.classDeltas = classDeltas
        self.attributions = attributions
    }
}

public enum GrowthComparison: Sendable, Equatable {
    case report(StorageGrowthReport)
    /// The two measurements were made under different rules. The reason is one
    /// sentence for the Dashboard.
    case notComparable(reason: String)
    /// Fewer than two measurements, or none that matches the requested baseline.
    case insufficientHistory
}

/// Subtracts one stored measurement from another. Pure: no clock, no filesystem.
///
/// Every figure it produces is a difference of two measured figures made under the
/// same rules. Nothing here estimates, and nothing here fills a gap with a plausible
/// name — a change the segments do not account for is reported as `Unmeasured`.
public enum StorageGrowth {

    /// A change smaller than this is not worth naming a folder for.
    public static let defaultMinimumAttributionBytes: Int64 = 100_000_000

    /// How many places the report names.
    public static let defaultMaximumAttributions = 8

    /// A child must explain this much of its parent's change before the report
    /// names the child instead of the parent.
    ///
    /// Eight tenths, so "Documents & Desktop +11.2 GB" becomes
    /// "Documents/Renewals/build +11.0 GB" but a parent that grew in two places at
    /// once keeps its own name — naming one of two causes would be a false lead.
    static let collapseNumerator: Int64 = 8
    static let collapseDenominator: Int64 = 10

    /// How far two sizes may differ and still be the same directory, moved.
    static let moveTolerancePercent: Int64 = 5

    // MARK: - Comparing

    public static func compare(
        baseline: StorageSnapshot,
        latest: StorageSnapshot,
        minimumAttributionBytes: Int64 = StorageGrowth.defaultMinimumAttributionBytes,
        maximumAttributions: Int = StorageGrowth.defaultMaximumAttributions
    ) -> GrowthComparison {
        if let reason = baseline.contract.incompatibility(with: latest.contract) {
            return .notComparable(reason: reason)
        }

        let usedDelta = latest.usedBytes - baseline.usedBytes
        let segmentDeltas = segmentDeltas(baseline: baseline, latest: latest)
        let classDeltas = classDeltas(from: segmentDeltas, usedDelta: usedDelta)
        let attributions = attributions(
            baseline: baseline,
            latest: latest,
            minimumAttributionBytes: minimumAttributionBytes,
            maximumAttributions: maximumAttributions
        )

        return .report(StorageGrowthReport(
            baseline: baseline,
            latest: latest,
            usedDeltaBytes: usedDelta,
            segmentDeltas: segmentDeltas,
            classDeltas: classDeltas,
            attributions: attributions
        ))
    }

    /// Picks a baseline and compares it with the newest measurement.
    ///
    /// - Parameter snapshots: newest first, as ``StorageSnapshotStore/load()``
    ///   returns them.
    public static func comparison(
        _ kind: GrowthBaseline,
        in snapshots: [StorageSnapshot],
        minimumAttributionBytes: Int64 = StorageGrowth.defaultMinimumAttributionBytes,
        maximumAttributions: Int = StorageGrowth.defaultMaximumAttributions
    ) -> GrowthComparison {
        guard let latest = snapshots.first,
              let baseline = baseline(kind, in: snapshots, latest: latest)
        else { return .insufficientHistory }

        return compare(
            baseline: baseline,
            latest: latest,
            minimumAttributionBytes: minimumAttributionBytes,
            maximumAttributions: maximumAttributions
        )
    }

    /// Finds the measurement a baseline names.
    ///
    /// The seven days are counted back from `latest.measuredAt`, not from the wall
    /// clock: a report must read the same tomorrow as it does today, and a stale
    /// latest measurement must not silently widen the window.
    ///
    /// - Parameter snapshots: newest first.
    public static func baseline(
        _ kind: GrowthBaseline,
        in snapshots: [StorageSnapshot],
        latest: StorageSnapshot
    ) -> StorageSnapshot? {
        let older = snapshots.filter {
            $0.id != latest.id && $0.measuredAt < latest.measuredAt
        }
        switch kind {
        case .previousMeasurement:
            return older.first
        case .sevenDays:
            let cutoff = latest.measuredAt.addingTimeInterval(-7 * 24 * 60 * 60)
            // Nothing that old yet: the oldest there is, and the card shows its real
            // date. Silently reporting a two-day change as a week is the lie.
            return older.first { $0.measuredAt <= cutoff } ?? older.last
        case .lastCleanup:
            return older.first { $0.trigger == .removal }
        }
    }

    // MARK: - Segment and class arithmetic

    static func segmentDeltas(
        baseline: StorageSnapshot,
        latest: StorageSnapshot
    ) -> [StorageSegmentID: Int64] {
        var deltas: [StorageSegmentID: Int64] = [:]
        // Free space is the mirror image of used space. Listing it would state the
        // same change a second time with the opposite sign.
        let ids = Set(baseline.rawSegments.keys)
            .union(latest.rawSegments.keys)
            .subtracting([.free])
        for id in ids {
            let delta = (latest.rawSegments[id] ?? 0) - (baseline.rawSegments[id] ?? 0)
            if delta != 0 { deltas[id] = delta }
        }
        return deltas
    }

    static func classDeltas(
        from segmentDeltas: [StorageSegmentID: Int64],
        usedDelta: Int64
    ) -> [GrowthClass: Int64] {
        var deltas = Dictionary(uniqueKeysWithValues: GrowthClass.allCases.map { ($0, Int64(0)) })
        for (segment, delta) in segmentDeltas {
            deltas[GrowthClass.of(segment), default: 0] += delta
        }
        // The segments account for the whole change only while `Unmeasured` stays
        // positive on both sides; it is clamped at zero, so a disk whose measured
        // roots exceed its used space leaves a remainder. It belongs to nothing that
        // was measured, so it goes where every unattributed byte goes.
        let named = segmentDeltas.values.reduce(Int64(0), +)
        deltas[.unmeasured, default: 0] += usedDelta - named
        return deltas
    }

    // MARK: - Where the change happened

    static func attributions(
        baseline: StorageSnapshot,
        latest: StorageSnapshot,
        minimumAttributionBytes: Int64,
        maximumAttributions: Int
    ) -> [GrowthAttribution] {
        let baselineNodes = Dictionary(
            baseline.nodes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let latestNodes = Dictionary(
            latest.nodes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let moves = moves(baselineNodes: baselineNodes, latestNodes: latestNodes)

        let allPaths = Set(baselineNodes.keys).union(latestNodes.keys)
        var children: [String: [String]] = [:]
        for path in allPaths {
            let parent = parentPath(of: path)
            guard parent != path else { continue }
            children[parent, default: []].append(path)
        }

        func delta(_ path: String) -> Int64 {
            (latestNodes[path]?.allocatedBytes ?? 0) - (baselineNodes[path]?.allocatedBytes ?? 0)
        }

        /// Walks down to the deepest folder that still explains the change.
        func deepest(from path: String) -> String {
            let parentDelta = delta(path)
            let threshold = (abs(parentDelta) * collapseNumerator) / collapseDenominator
            // Largest change first, ties broken by path, so the report reads the
            // same on every run.
            let ranked = (children[path] ?? []).sorted { lhs, rhs in
                abs(delta(lhs)) == abs(delta(rhs))
                    ? lhs < rhs
                    : abs(delta(lhs)) > abs(delta(rhs))
            }
            guard let dominant = ranked.first else { return path }
            let childDelta = delta(dominant)
            guard childDelta.signum() == parentDelta.signum(), abs(childDelta) >= threshold else {
                return path
            }
            return deepest(from: dominant)
        }

        // Start at the topmost recorded folders — those whose parent is not itself a
        // recorded folder. `$HOME` is never recorded, so its children start here,
        // and so does every machine-wide root.
        let roots = allPaths.filter { !allPaths.contains(parentPath(of: $0)) }

        var found: [GrowthAttribution] = []
        for root in roots.sorted() where abs(delta(root)) >= minimumAttributionBytes {
            let path = deepest(from: root)
            let node = latestNodes[path] ?? baselineNodes[path]
            guard let segment = node?.segment else { continue }
            found.append(GrowthAttribution(
                path: path,
                segment: segment,
                deltaBytes: delta(path),
                kind: kind(
                    of: path,
                    delta: delta(path),
                    inBaseline: baselineNodes[path] != nil,
                    inLatest: latestNodes[path] != nil,
                    moves: moves
                )
            ))
        }

        found.sort { lhs, rhs in
            abs(lhs.deltaBytes) == abs(rhs.deltaBytes)
                ? lhs.path < rhs.path
                : abs(lhs.deltaBytes) > abs(rhs.deltaBytes)
        }
        return Array(found.prefix(maximumAttributions))
    }

    private static func kind(
        of path: String,
        delta: Int64,
        inBaseline: Bool,
        inLatest: Bool,
        moves: (in: [String: String], out: [String: String])
    ) -> GrowthAttribution.Kind {
        if let from = moves.in[path] { return .movedIn(from: from) }
        if let to = moves.out[path] { return .movedOut(to: to) }
        if !inBaseline { return .appeared }
        if !inLatest { return .disappeared }
        return delta >= 0 ? .grew : .shrank
    }

    /// Matches a folder that left one path with the folder that arrived at another.
    ///
    /// A move is the one change that reads as growth in one place and an equal loss
    /// in another while nothing was written or deleted. `device:inode` is what tells
    /// them apart: the moved folder keeps its inode, so a path that vanished and a
    /// path that appeared carrying the same identity are one folder, not two events.
    ///
    /// The size must also agree within five percent. An inode is reused after a
    /// folder is deleted, so identity alone can pair two unrelated folders; a folder
    /// that is the same size as well is the same folder.
    static func moves(
        baselineNodes: [String: SnapshotNode],
        latestNodes: [String: SnapshotNode]
    ) -> (in: [String: String], out: [String: String]) {
        let gone = baselineNodes.values.filter { latestNodes[$0.path] == nil }
        let arrived = latestNodes.values.filter { baselineNodes[$0.path] == nil }

        var goneByIdentity: [String: SnapshotNode] = [:]
        var ambiguous = Set<String>()
        for node in gone {
            guard let identity = node.identity else { continue }
            if goneByIdentity.updateValue(node, forKey: identity) != nil {
                ambiguous.insert(identity)
            }
        }

        var movedIn: [String: String] = [:]
        var movedOut: [String: String] = [:]
        for node in arrived.sorted(by: { $0.path < $1.path }) {
            guard let identity = node.identity,
                  !ambiguous.contains(identity),
                  let partner = goneByIdentity[identity],
                  movedOut[partner.path] == nil,
                  sizesAgree(partner.allocatedBytes, node.allocatedBytes)
            else { continue }
            movedIn[node.path] = partner.path
            movedOut[partner.path] = node.path
        }
        return (movedIn, movedOut)
    }

    private static func sizesAgree(_ lhs: Int64, _ rhs: Int64) -> Bool {
        let larger = max(abs(lhs), abs(rhs))
        guard larger > 0 else { return true }
        return abs(lhs - rhs) * 100 <= larger * moveTolerancePercent
    }

    /// The containing folder. `"/"` is its own parent, which ends every walk upwards.
    private static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
