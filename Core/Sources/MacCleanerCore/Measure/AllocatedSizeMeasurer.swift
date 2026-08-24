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
    /// True when something under this tree matched a protected glob — a
    /// `*.sparsebundle`, a keychain. Detected *during* the walk the caller was
    /// paying for anyway: the alternative, a second recursive enumeration per
    /// candidate at emission time, doubled the cost of every scan. A tree carrying
    /// this flag must not be offered for removal, because removing it recursively
    /// would take the protected thing with it.
    public var containsProtectedPattern: Bool

    public static let zero = SizeMeasurement(allocatedBytes: 0, fileCount: 0, unreadableCount: 0)

    public init(
        allocatedBytes: Int64 = 0,
        fileCount: Int = 0,
        unreadableCount: Int = 0,
        containsProtectedPattern: Bool = false
    ) {
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
        self.containsProtectedPattern = containsProtectedPattern
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        SizeMeasurement(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount,
            containsProtectedPattern: lhs.containsProtectedPattern || rhs.containsProtectedPattern
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

    /// Globs from Preferences › Exclusions, matched against every name the walk
    /// meets. A tree containing a match comes back flagged rather than being
    /// enumerated a second time by the caller.
    public var protectedPatterns: [String]

    /// How often to check for cancellation, in entries.
    private let cancellationCheckInterval = 512

    public init(followSymlinks: Bool = false, protectedPatterns: [String] = []) {
        self.followSymlinks = followSymlinks
        self.protectedPatterns = protectedPatterns
    }

    fileprivate static let keys: [URLResourceKey] = [
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
    //
    // All three entry points feed one parallel engine: a fixed pool of workers
    // draining a shared queue of directories. The serial `FileManager.enumerator`
    // walk this replaces spent ~80 s on a full breakdown of one real Mac — almost
    // entirely metadata syscalls, which APFS answers happily in parallel. The
    // rules the serial walk disclosed all still hold: unreadable entries cost one
    // entry, packages are descended, symlinks are not followed, the walk never
    // leaves the starting volume, and hard-linked inodes count once. The one
    // behavioural change: *which* sibling a shared inode is attributed to is now
    // first-come rather than enumeration order. Sums are unchanged.

    /// Measures a single tree.
    ///
    /// - Parameter progress: called periodically with the running total, for the
    ///   scan progress bar. Never called on a specific queue.
    public func measure(
        _ url: URL,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> SizeMeasurement {
        // With the follow setting on, a symlink root means its target.
        let url = followSymlinks ? url.resolvingSymlinksInPath() : url
        // A plain file, or a symlink we are not following: measure and return.
        let rootValues = try? url.resourceValues(forKeys: Set(Self.keys))
        if rootValues?.isDirectory != true {
            if rootValues?.isSymbolicLink == true && !followSymlinks { return .zero }
            if let bytes = Self.allocatedSize(of: rootValues) {
                return SizeMeasurement(allocatedBytes: bytes, fileCount: 1)
            }
            return .zero
        }

        let followSymlinks = self.followSymlinks
        let protectedPatterns = self.protectedPatterns
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let key = url.standardizedFileURL
                let detachedValues = try? url.resourceValues(forKeys: Set(Self.keys))
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    rootVolume: detachedValues?.volumeIdentifier as? NSObject,
                    cancelled: cancelled,
                    progress: progress
                )
                walker.enqueue(listing: url, attribution: [key], grow: 0)
                return try walker.run()[key] ?? .zero
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
        let protectedPatterns = self.protectedPatterns
        let cancelled = CancellationFlag()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let standardRoot = root.standardizedFileURL
                let rootValues = try? standardRoot.resourceValues(forKeys: Set(Self.keys))
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    rootVolume: rootValues?.volumeIdentifier as? NSObject,
                    cancelled: cancelled,
                    progress: progress
                )
                walker.enqueue(listing: standardRoot, attribution: [standardRoot], grow: depth)
                var totals = try walker.run()
                if totals[standardRoot] == nil { totals[standardRoot] = .zero }
                return totals
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Measures every immediate child of `url` in one traversal.
    ///
    /// Hard links shared *between* children are attributed to whichever claims the
    /// inode first, so the children sum to the parent rather than exceeding it.
    public func measureChildren(
        of url: URL,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> [URL: SizeMeasurement] {
        let followSymlinks = self.followSymlinks
        let protectedPatterns = self.protectedPatterns
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Self.keys,
                    options: []
                )) ?? []

                let parentValues = try? url.resourceValues(forKeys: Set(Self.keys))
                // One walker across all children, so an inode hard-linked into two
                // of them is attributed once and the children still sum to the
                // parent rather than exceeding it.
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    rootVolume: parentValues?.volumeIdentifier as? NSObject,
                    cancelled: cancelled,
                    progress: progress
                )
                for child in children {
                    walker.prefill(child)
                    // A child that is itself a protected bundle: the listing loop
                    // inside the walker never sees it, because this level was
                    // listed here.
                    if walker.matchesProtectedPattern(child.lastPathComponent) {
                        walker.markProtected(child)
                    }
                    guard let values = try? child.resourceValues(forKeys: Set(Self.keys)) else {
                        walker.recordUnreadable(at: child)
                        continue
                    }
                    if values.isSymbolicLink == true {
                        guard followSymlinks else { continue }
                        // A direct symlink child reports neither directory nor
                        // regular file for itself; resolve it or the row measures
                        // nothing with the follow setting on.
                        let resolved = child.resolvingSymlinksInPath()
                        guard let target = try? resolved.resourceValues(
                            forKeys: Set(Self.keys)
                        ) else {
                            walker.recordUnreadable(at: child)
                            continue
                        }
                        if target.isDirectory == true {
                            walker.enqueue(listing: resolved, attribution: [child], grow: 0)
                        } else {
                            walker.measureLooseFile(target, at: child)
                        }
                        continue
                    }
                    if values.isDirectory == true {
                        walker.enqueue(listing: child, attribution: [child], grow: 0)
                    } else {
                        walker.measureLooseFile(values, at: child)
                    }
                }
                return try walker.run()
            }.value
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// APFS-aware size, most accurate first.
    fileprivate static func allocatedSize(of values: URLResourceValues?) -> Int64? {
        guard let values else { return nil }
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return nil
    }
}

// MARK: - Parallel engine

/// A fixed pool of workers draining a shared queue of directories.
///
/// Each worker pops a directory, lists it with attributes prefetched, adds its
/// regular files to every URL in the item's attribution chain, and pushes its
/// subdirectories back on the queue. One lock guards all shared state; the work
/// inside the lock is arithmetic only — the syscalls happen outside it.
private final class ParallelTreeWalker: @unchecked Sendable {

    private struct WorkItem {
        /// The directory to list — the real URL, whatever form the parent handed us.
        let listing: URL
        /// The totals keys this directory's files add to, root first. The last
        /// element is the deepest attributed ancestor, and child keys are built by
        /// appending to it — the same `appendPathComponent` chain the lookups use.
        let attribution: [URL]
        /// How many more levels may extend the attribution chain.
        let grow: Int
    }

    private let followSymlinks: Bool
    private let protectedPatterns: [String]
    private let rootVolume: NSObject?
    private let cancelled: CancellationFlag
    private let progress: (@Sendable (SizeMeasurement) -> Void)?

    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    private var active = 0
    private var totals: [URL: SizeMeasurement] = [:]
    private var unreadable: [URL: Int] = [:]
    private var claimedInodes = Set<NSObject>()
    /// Directories already queued, tracked only when following symlinks: a link
    /// into a subtree that is walked anyway must not count it twice, and a link to
    /// an ancestor must not walk forever. Keyed by resolved path.
    private var visitedDirectories = Set<String>()
    /// Attribution keys whose subtree holds something matching a protected glob.
    private var protectedKeys = Set<URL>()
    /// Every file once, regardless of how many ancestors it is attributed to —
    /// what the progress callback reports.
    private var grandTotal = SizeMeasurement.zero
    private var entriesSinceReport = 0

    /// How often to surface progress and poll cancellation, in entries.
    private static let reportInterval = 512

    init(
        followSymlinks: Bool,
        protectedPatterns: [String] = [],
        rootVolume: NSObject?,
        cancelled: CancellationFlag,
        progress: (@Sendable (SizeMeasurement) -> Void)?
    ) {
        self.followSymlinks = followSymlinks
        self.protectedPatterns = protectedPatterns
        self.rootVolume = rootVolume
        self.cancelled = cancelled
        self.progress = progress
    }

    func enqueue(listing: URL, attribution: [URL], grow: Int) {
        condition.lock()
        if followSymlinks {
            // Every directory funnels through here, so this one check is the whole
            // cycle- and double-count guard.
            let canonical = listing.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedDirectories.insert(canonical).inserted else {
                condition.unlock()
                return
            }
        }
        stack.append(WorkItem(listing: listing, attribution: attribution, grow: grow))
        condition.signal()
        condition.unlock()
    }

    /// Whether a bare name matches any configured glob. Cheap: no attributes are
    /// read, and it is skipped entirely when no patterns are configured.
    func matchesProtectedPattern(_ name: String) -> Bool {
        guard !protectedPatterns.isEmpty else { return false }
        return protectedPatterns.contains { fnmatch($0, name, 0) == 0 }
    }

    func markProtected(_ key: URL) {
        condition.lock()
        protectedKeys.insert(key)
        condition.unlock()
    }

    /// Guarantees the key appears in the result even if nothing is under it.
    func prefill(_ key: URL) {
        condition.lock()
        if totals[key] == nil { totals[key] = .zero }
        condition.unlock()
    }

    func recordUnreadable(at key: URL) {
        condition.lock()
        unreadable[key, default: 0] += 1
        condition.unlock()
    }

    /// A direct file child in `measureChildren` — no directory to walk.
    func measureLooseFile(_ values: URLResourceValues, at key: URL) {
        if let entryVolume = values.volumeIdentifier as? NSObject, let rootVolume,
           !entryVolume.isEqual(rootVolume) { return }
        guard values.isRegularFile == true else { return }
        condition.lock()
        defer { condition.unlock() }
        if (values.linkCount ?? 1) > 1 {
            guard let id = values.fileResourceIdentifier as? NSObject,
                  claimedInodes.insert(id).inserted else { return }
        }
        guard let bytes = AllocatedSizeMeasurer.allocatedSize(of: values) else { return }
        totals[key, default: .zero].allocatedBytes += bytes
        totals[key, default: .zero].fileCount += 1
        grandTotal.allocatedBytes += bytes
        grandTotal.fileCount += 1
    }

    /// Runs the pool to exhaustion and returns the totals, unreadable counts folded
    /// in. Throws `CancellationError` if the flag was raised mid-walk.
    func run() throws -> [URL: SizeMeasurement] {
        let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        // Dedicated threads, not GCD global-queue blocks. The caller is a detached
        // task blocking on the result, and Swift's cooperative pool shares
        // libdispatch's thread pool: with several measurements in flight the
        // blocked callers starved the queued worker blocks, which never started —
        // a deadlock the test suite reproduced on the first run. Real pthreads
        // owe libdispatch nothing.
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<width {
            let worker = Thread {
                self.workerLoop()
                finished.signal()
            }
            // `.userInitiated`, not `.utility`: on Apple silicon utility threads
            // are scheduled onto the efficiency cores, and eight of them there
            // amounted to about one and a half cores of throughput. The user is
            // waiting on this figure — it is the Dashboard's first card.
            worker.qualityOfService = .userInitiated
            worker.start()
        }
        for _ in 0..<width { finished.wait() }
        if cancelled.isCancelled { throw CancellationError() }

        condition.lock()
        defer { condition.unlock() }
        for (key, count) in unreadable {
            totals[key, default: .zero].unreadableCount += count
        }
        for key in protectedKeys {
            totals[key, default: .zero].containsProtectedPattern = true
        }
        return totals
    }

    private func workerLoop() {
        while let item = nextItem() {
            process(item)
            condition.lock()
            active -= 1
            if (stack.isEmpty && active == 0) || cancelled.isCancelled {
                condition.broadcast()
            } else {
                condition.signal()
            }
            condition.unlock()
        }
    }

    private func nextItem() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled.isCancelled { condition.broadcast(); return nil }
            if let item = stack.popLast() {
                active += 1
                return item
            }
            if active == 0 { condition.broadcast(); return nil }
            condition.wait()
        }
    }

    private func process(_ item: WorkItem) {
        guard !cancelled.isCancelled else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: item.listing,
            includingPropertiesForKeys: AllocatedSizeMeasurer.keys,
            options: []
        ) else {
            // A permission-denied directory costs one entry — never a subtree,
            // and never the whole total.
            recordUnreadable(at: item.attribution[0])
            return
        }

        var localFiles: [Int64] = []
        var report: SizeMeasurement?

        for entry in entries {
            // Name check first: it needs no attributes, so a protected bundle is
            // recognised even where the entry itself cannot be read.
            if matchesProtectedPattern(entry.lastPathComponent) {
                for key in item.attribution { markProtected(key) }
            }
            guard let values = try? entry.resourceValues(
                forKeys: Set(AllocatedSizeMeasurer.keys)
            ) else {
                recordUnreadable(at: item.attribution[0])
                continue
            }

            // Never leave the starting volume — a mounted disk under the scan
            // root is not part of this category.
            if let rootVolume, let entryVolume = values.volumeIdentifier as? NSObject,
               !entryVolume.isEqual(rootVolume) {
                continue
            }
            if values.isSymbolicLink == true {
                guard followSymlinks else { continue }
                // The setting is on: measure the target as if it lived here. The
                // visited set breaks cycles and stops a target that is walked
                // anyway from counting twice; Advanced warns this can double-count
                // across *distinct* links to the same files, which inode dedup
                // catches for hard content and misses for directories re-linked
                // under different names — the disclosed price of the option.
                let resolved = entry.resolvingSymlinksInPath()
                guard let target = try? resolved.resourceValues(
                    forKeys: Set(AllocatedSizeMeasurer.keys)
                ) else {
                    recordUnreadable(at: item.attribution[0])
                    continue
                }
                if let rootVolume, let targetVolume = target.volumeIdentifier as? NSObject,
                   !targetVolume.isEqual(rootVolume) {
                    continue
                }
                if target.isDirectory == true {
                    let childKey = item.attribution[item.attribution.count - 1]
                        .appendingPathComponent(entry.lastPathComponent)
                    let attribution = item.grow > 0 ? item.attribution + [childKey] : item.attribution
                    enqueue(listing: resolved, attribution: attribution, grow: max(0, item.grow - 1))
                } else if target.isRegularFile == true {
                    if (target.linkCount ?? 1) > 1 {
                        condition.lock()
                        let fresh = (target.fileResourceIdentifier as? NSObject).map {
                            claimedInodes.insert($0).inserted
                        } ?? true
                        condition.unlock()
                        guard fresh else { continue }
                    }
                    if let bytes = AllocatedSizeMeasurer.allocatedSize(of: target) {
                        localFiles.append(bytes)
                    }
                }
                continue
            }

            if values.isDirectory == true {
                let childKey = item.attribution[item.attribution.count - 1]
                    .appendingPathComponent(entry.lastPathComponent)
                let attribution = item.grow > 0 ? item.attribution + [childKey] : item.attribution
                enqueue(listing: entry, attribution: attribution, grow: max(0, item.grow - 1))
                continue
            }

            guard values.isRegularFile == true else { continue }

            if (values.linkCount ?? 1) > 1 {
                condition.lock()
                let fresh = (values.fileResourceIdentifier as? NSObject).map {
                    claimedInodes.insert($0).inserted
                } ?? true
                condition.unlock()
                guard fresh else { continue }
            }
            guard let bytes = AllocatedSizeMeasurer.allocatedSize(of: values) else { continue }
            localFiles.append(bytes)

            // Batch the arithmetic under one lock acquisition per directory where
            // possible, but surface progress and poll cancellation often enough
            // that a huge directory cannot go quiet.
            if localFiles.count % Self.reportInterval == 0 {
                report = flush(&localFiles, attribution: item.attribution)
                if cancelled.isCancelled { return }
                if let report { progress?(report) }
                report = nil
            }
        }
        if !localFiles.isEmpty || report != nil {
            let snapshot = flush(&localFiles, attribution: item.attribution)
            maybeReport(snapshot)
        }
    }

    /// Adds the batched sizes to every attributed ancestor; returns the grand total.
    private func flush(_ sizes: inout [Int64], attribution: [URL]) -> SizeMeasurement {
        condition.lock()
        defer { condition.unlock() }
        let bytes = sizes.reduce(0, +)
        let count = sizes.count
        for key in attribution {
            totals[key, default: .zero].allocatedBytes += bytes
            totals[key, default: .zero].fileCount += count
        }
        grandTotal.allocatedBytes += bytes
        grandTotal.fileCount += count
        entriesSinceReport += count
        sizes.removeAll(keepingCapacity: true)
        return grandTotal
    }

    private func maybeReport(_ snapshot: SizeMeasurement) {
        condition.lock()
        let due = entriesSinceReport >= Self.reportInterval
        if due { entriesSinceReport = 0 }
        condition.unlock()
        if due { progress?(snapshot) }
    }
}

// MARK: - Support

/// Bridges structured-concurrency cancellation into the detached, blocking walk.
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
