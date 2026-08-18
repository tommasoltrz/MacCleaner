import Foundation

/// The result of measuring a directory tree.
///
/// `unreadableCount` is part of the result rather than swallowed, because honesty
/// about what could not be read is a product requirement: whatever this measurer
/// cannot reach ends up in the Dashboard's `Unmeasured` bucket, and that bucket is
/// only trustworthy if callers can see the gap.
public struct SizeMeasurement: Sendable, Equatable {
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var unreadableCount: Int

    public static let zero = SizeMeasurement(allocatedBytes: 0, fileCount: 0, unreadableCount: 0)

    public init(allocatedBytes: Int64 = 0, fileCount: Int = 0, unreadableCount: Int = 0) {
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        SizeMeasurement(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount
        )
    }
}

/// Measures on-disk size. **The only sizing primitive in the app.**
///
/// The Electron version this replaces shelled out to `du -sk`, which produced two
/// classes of wrong answer that must never come back:
///
/// 1. **`du` exits non-zero on the first unreadable directory.** The old code's
///    `catch` turned that into `0`, so a single permission-denied folder silently
///    zeroed an entire category. Here the enumerator's `errorHandler` counts the
///    failure and returns `true`, so one unreadable entry costs one entry — never a
///    subtree, and never the whole total.
/// 2. **`du` reports block counts, not allocated size.** `totalFileAllocatedSize`
///    reflects what the file actually occupies, including compression, which `du`
///    approximates.
///
/// ### Known limitation: APFS clones
///
/// Block sharing between *distinct files* (APFS clones, as made by `cp -c` or
/// Finder duplication) is invisible to every per-file API, this one included. Two
/// 16 MB clones sharing all their blocks report 32 MB, though freeing both recovers
/// only 16 MB. Hard links are different — several directory entries for one inode —
/// and those are deduplicated below.
///
/// This is not a defect to fix but a property to disclose: a reported total is an
/// upper bound on what deleting would reclaim. It is precisely why a real cleanup of
/// a pnpm content-addressable store frees less than the sum of its entries.
///
/// Symlinks are not followed by default: the old scanner could double-count linked
/// build outputs. Enumeration also stays on the starting volume, so a mounted
/// external drive under the scan root cannot inflate a local category.
public struct AllocatedSizeMeasurer: Sendable {

    /// Set when the user enables "Follow symlinks while measuring" in Advanced.
    /// Off by default — the setting's own description warns it can double-count.
    public var followSymlinks: Bool

    /// How often to check for cancellation, in entries.
    private let cancellationCheckInterval = 512

    public init(followSymlinks: Bool = false) {
        self.followSymlinks = followSymlinks
    }

    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .linkCountKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]

    // MARK: - Measuring

    /// Measures a single tree.
    ///
    /// - Parameter progress: called periodically with the running total, for the
    ///   scan progress bar. Never called on a specific queue.
    public func measure(
        _ url: URL,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> SizeMeasurement {
        let followSymlinks = self.followSymlinks
        let interval = cancellationCheckInterval
        // `Task.detached` keeps the blocking walk off the cooperative pool, but a
        // detached task does NOT inherit cancellation — so the flag bridges it. The
        // toolbar's stop button depends on this.
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                var deduplicator = HardLinkDeduplicator()
                return try Self.walk(
                    url,
                    followSymlinks: followSymlinks,
                    cancellationCheckInterval: interval,
                    cancelled: cancelled,
                    deduplicator: &deduplicator,
                    progress: progress
                )
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Measures every descendant directory down to `depth`, in a **single** traversal.
    ///
    /// The equivalent of `du -d <depth>`, and the primitive the storage breakdown is
    /// built on: it needs both the top-level children of `$HOME` and the children of
    /// `~/Library`, and walking the tree twice to get them would nearly double the
    /// cost of the most expensive scan in the app.
    ///
    /// Every returned entry is a full recursive total. Each file is attributed to all
    /// of its ancestors up to `depth`, and to `root` itself, so parents always
    /// contain their children exactly.
    public func measureSubtrees(
        of root: URL,
        depth: Int,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> [URL: SizeMeasurement] {
        precondition(depth >= 1, "depth must be at least 1")
        let followSymlinks = self.followSymlinks
        let interval = cancellationCheckInterval
        let cancelled = CancellationFlag()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Self.walkSubtrees(
                    root,
                    depth: depth,
                    followSymlinks: followSymlinks,
                    cancellationCheckInterval: interval,
                    cancelled: cancelled,
                    progress: progress
                )
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Measures every immediate child of `url` in one traversal.
    ///
    /// Hard links shared *between* children are attributed to whichever is
    /// encountered first, so the children sum to the parent rather than exceeding it.
    public func measureChildren(
        of url: URL,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> [URL: SizeMeasurement] {
        let followSymlinks = self.followSymlinks
        let interval = cancellationCheckInterval
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Self.keys,
                    options: []
                )) ?? []

                // One deduplicator across all children, so an inode hard-linked into
                // two of them is attributed once and the children still sum to the
                // parent rather than exceeding it.
                var deduplicator = HardLinkDeduplicator()
                var results: [URL: SizeMeasurement] = [:]
                for child in children {
                    if cancelled.isCancelled { throw CancellationError() }
                    results[child] = try Self.walk(
                        child,
                        followSymlinks: followSymlinks,
                        cancellationCheckInterval: interval,
                        cancelled: cancelled,
                        deduplicator: &deduplicator,
                        progress: progress
                    )
                }
                return results
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    // MARK: - Core traversal

    private static func walk(
        _ url: URL,
        followSymlinks: Bool,
        cancellationCheckInterval: Int,
        cancelled: CancellationFlag,
        deduplicator: inout HardLinkDeduplicator,
        progress: (@Sendable (SizeMeasurement) -> Void)?
    ) throws -> SizeMeasurement {
        let fileManager = FileManager.default
        var total = SizeMeasurement.zero

        // A plain file, or a symlink we are not following: measure and return.
        let rootValues = try? url.resourceValues(forKeys: Set(Self.keys))
        if rootValues?.isDirectory != true {
            if rootValues?.isSymbolicLink == true && !followSymlinks { return .zero }
            if let bytes = Self.allocatedSize(of: rootValues) {
                total.allocatedBytes = bytes
                total.fileCount = 1
            }
            return total
        }

        let rootVolume = rootValues?.volumeIdentifier

        // No `.skipsPackageDescendants`: an .app, .photoslibrary or .rtfd is a
        // package, and skipping package contents makes /Applications measure as
        // ~0 bytes. A disk-usage measurer must descend into packages — they are
        // exactly where the space is.
        let options: FileManager.DirectoryEnumerationOptions = []

        // The errorHandler is the whole point: return `true` so a permission-denied
        // entry is counted and skipped rather than aborting the walk.
        let unreadable = UnreadableCounter()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.keys,
            options: options,
            errorHandler: { _, _ in
                unreadable.increment()
                return true
            }
        ) else {
            return SizeMeasurement(allocatedBytes: 0, fileCount: 0, unreadableCount: 1)
        }

        var seen = 0
        while let entry = enumerator.nextObject() as? URL {
            seen += 1
            if seen % cancellationCheckInterval == 0 {
                if cancelled.isCancelled { throw CancellationError() }
                progress?(SizeMeasurement(
                    allocatedBytes: total.allocatedBytes,
                    fileCount: total.fileCount,
                    unreadableCount: unreadable.value
                ))
            }

            guard let values = try? entry.resourceValues(forKeys: Set(Self.keys)) else {
                unreadable.increment()
                continue
            }

            // Never leave the starting volume — a mounted disk under the scan root
            // is not part of this category.
            if let rootVolume, let entryVolume = values.volumeIdentifier,
               !entryVolume.isEqual(rootVolume) {
                enumerator.skipDescendants()
                continue
            }

            if values.isSymbolicLink == true && !followSymlinks { continue }
            guard values.isRegularFile == true else { continue }

            // Count a hard-linked inode once per measurement pass.
            if (values.linkCount ?? 1) > 1, !deduplicator.claim(values.fileResourceIdentifier) {
                continue
            }

            if let bytes = Self.allocatedSize(of: values) {
                total.allocatedBytes += bytes
                total.fileCount += 1
            }
        }

        total.unreadableCount += unreadable.value
        return total
    }

    /// Single-pass depth-limited traversal. See `measureSubtrees(of:depth:)`.
    private static func walkSubtrees(
        _ root: URL,
        depth: Int,
        followSymlinks: Bool,
        cancellationCheckInterval: Int,
        cancelled: CancellationFlag,
        progress: (@Sendable (SizeMeasurement) -> Void)?
    ) throws -> [URL: SizeMeasurement] {
        let standardRoot = root.standardizedFileURL
        let rootComponentCount = standardRoot.pathComponents.count
        let rootValues = try? standardRoot.resourceValues(forKeys: Set(keys))
        let rootVolume = rootValues?.volumeIdentifier

        var totals: [URL: SizeMeasurement] = [standardRoot: .zero]
        var deduplicator = HardLinkDeduplicator()
        let unreadable = UnreadableCounter()

        guard let enumerator = FileManager.default.enumerator(
            at: standardRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                unreadable.increment()
                return true
            }
        ) else {
            return [standardRoot: SizeMeasurement(unreadableCount: 1)]
        }

        var seen = 0
        while let entry = enumerator.nextObject() as? URL {
            seen += 1
            if seen % cancellationCheckInterval == 0 {
                if cancelled.isCancelled { throw CancellationError() }
                progress?(totals[standardRoot] ?? .zero)
            }

            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                unreadable.increment()
                continue
            }
            if let rootVolume, let entryVolume = values.volumeIdentifier,
               !entryVolume.isEqual(rootVolume) {
                enumerator.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true && !followSymlinks { continue }
            guard values.isRegularFile == true else { continue }
            if (values.linkCount ?? 1) > 1, !deduplicator.claim(values.fileResourceIdentifier) {
                continue
            }
            guard let bytes = allocatedSize(of: values) else { continue }

            // Attribute the file to the root and to each ancestor within `depth`.
            totals[standardRoot, default: .zero].allocatedBytes += bytes
            totals[standardRoot, default: .zero].fileCount += 1

            let components = entry.standardizedFileURL.pathComponents
            guard components.count > rootComponentCount else { continue }
            let maximumLevel = min(depth, components.count - rootComponentCount - 1)
            guard maximumLevel >= 1 else { continue }

            var ancestor = standardRoot
            for level in 1...maximumLevel {
                ancestor.appendPathComponent(components[rootComponentCount + level - 1])
                totals[ancestor, default: .zero].allocatedBytes += bytes
                totals[ancestor, default: .zero].fileCount += 1
            }
        }

        totals[standardRoot, default: .zero].unreadableCount += unreadable.value
        return totals
    }

    /// APFS-aware size, most accurate first.
    private static func allocatedSize(of values: URLResourceValues?) -> Int64? {
        guard let values else { return nil }
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return nil
    }
}

// MARK: - Support

/// Tracks inodes already counted, so a file with several hard links contributes
/// its bytes once.
private struct HardLinkDeduplicator {
    private var claimed = Set<NSObject>()

    /// Returns `true` if this inode has not been counted yet.
    mutating func claim(_ identifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?) -> Bool {
        guard let object = identifier as? NSObject else { return true }
        return claimed.insert(object).inserted
    }
}

/// Bridges structured-concurrency cancellation into the detached, synchronous walk.
/// `Task.detached` does not inherit cancellation, so without this the scan's stop
/// button would do nothing.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return flag
    }
}

/// Mutable counter usable from the enumerator's `@Sendable` error handler.
private final class UnreadableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}
