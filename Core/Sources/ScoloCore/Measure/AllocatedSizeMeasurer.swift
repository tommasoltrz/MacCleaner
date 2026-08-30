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
    /// True when this tree contains an iCloud item that is not stored on this Mac.
    public var containsCloudOnlyItem: Bool

    public static let zero = SizeMeasurement(allocatedBytes: 0, fileCount: 0, unreadableCount: 0)

    public init(
        allocatedBytes: Int64 = 0,
        fileCount: Int = 0,
        unreadableCount: Int = 0,
        containsProtectedPattern: Bool = false,
        containsCloudOnlyItem: Bool = false
    ) {
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
        self.containsProtectedPattern = containsProtectedPattern
        self.containsCloudOnlyItem = containsCloudOnlyItem
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        SizeMeasurement(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount,
            containsProtectedPattern: lhs.containsProtectedPattern || rhs.containsProtectedPattern,
            containsCloudOnlyItem: lhs.containsCloudOnlyItem || rhs.containsCloudOnlyItem
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
/// ### By design: this measures occupancy, not reclaimable space
///
/// Block sharing between *distinct files* (APFS clones, as made by `cp -c` or by
/// Finder copying within one volume) is not reflected here. Two 16 MB clones
/// sharing all their blocks report 32 MB, though freeing both recovers only 16 MB.
/// Hard links are different — several directory entries for one inode — and those
/// are deduplicated below.
///
/// This is a property to disclose, not a defect to fix here: a reported total is an
/// upper bound on what deleting would reclaim. It is precisely why a real cleanup of
/// a pnpm content-addressable store frees less than the sum of its entries.
///
/// The filesystem *will* answer the other question — ``PrivateSizeMeasurer`` reads
/// `ATTR_CMNEXT_PRIVATESIZE` for it — but the kernel must consult each file's
/// extent map, which measured 62 % slower over `~/Library`. That price is paid
/// where the app promises to free space, not on every whole-disk walk.
///
/// Symlinks are not followed by default: the old scanner could double-count linked
/// build outputs. Enumeration also stays on the starting volume, so a mounted
/// external drive under the scan root cannot inflate a local category.
public struct AllocatedSizeMeasurer: Sendable {

    /// Available for specialized callers. App scans keep this off to prevent
    /// linked targets from counting under paths that do not own those bytes.
    public var followSymlinks: Bool

    /// Globs from Preferences › Exclusions, matched against every name the walk
    /// meets. A tree containing a match comes back flagged rather than being
    /// enumerated a second time by the caller.
    public var protectedPatterns: [String]

    /// Adds iCloud residency checks. Storage Explorer enables this safety scan.
    public var detectCloudOnlyItems: Bool

    /// How often to check for cancellation, in entries.
    private let cancellationCheckInterval = 512

    public init(
        followSymlinks: Bool = false,
        protectedPatterns: [String] = [],
        detectCloudOnlyItems: Bool = false
    ) {
        self.followSymlinks = followSymlinks
        self.protectedPatterns = protectedPatterns
        self.detectCloudOnlyItems = detectCloudOnlyItems
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

    private static let cloudKeys: [URLResourceKey] = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    private static func keys(detectingCloudItems: Bool) -> [URLResourceKey] {
        detectingCloudItems ? keys + cloudKeys : keys
    }

    // MARK: - Measuring
    //
    // All three entry points feed one parallel engine backed by a process-wide pool
    // of workers. The serial `FileManager.enumerator`
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
        _ inputURL: URL,
        progress: (@Sendable (SizeMeasurement) -> Void)? = nil
    ) async throws -> SizeMeasurement {
        let followSymlinks = self.followSymlinks
        let protectedPatterns = self.protectedPatterns
        let keys = Self.keys(detectingCloudItems: detectCloudOnlyItems)
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                // Path resolution and metadata reads can block on a network mount.
                // Keep both off Swift's cooperative executor.
                let url = followSymlinks
                    ? inputURL.resolvingSymlinksInPath()
                    : inputURL
                let rootValues = try? url.resourceValues(forKeys: Set(keys))

                // A plain file, or a symlink we are not following: measure and return.
                if rootValues?.isDirectory != true {
                    if rootValues?.isSymbolicLink == true && !followSymlinks { return .zero }
                    if let bytes = Self.allocatedSize(of: rootValues) {
                        return SizeMeasurement(
                            allocatedBytes: bytes,
                            fileCount: 1,
                            containsCloudOnlyItem: Self.isCloudOnly(rootValues)
                        )
                    }
                    return .zero
                }

                let key = url.standardizedFileURL
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    cancelled: cancelled,
                    keys: keys,
                    progress: progress
                )
                if Self.isCloudOnly(rootValues) { walker.markCloudOnly(key) }
                walker.enqueue(
                    listing: url,
                    attribution: [key],
                    grow: 0,
                    volume: rootValues?.volumeIdentifier as? NSObject
                )
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
        let keys = Self.keys(detectingCloudItems: detectCloudOnlyItems)
        let cancelled = CancellationFlag()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let standardRoot = root.standardizedFileURL
                let rootValues = try? standardRoot.resourceValues(forKeys: Set(keys))
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    cancelled: cancelled,
                    keys: keys,
                    progress: progress
                )
                if Self.isCloudOnly(rootValues) { walker.markCloudOnly(standardRoot) }
                walker.enqueue(
                    listing: standardRoot,
                    attribution: [standardRoot],
                    grow: depth,
                    volume: rootValues?.volumeIdentifier as? NSObject
                )
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
        let keys = Self.keys(detectingCloudItems: detectCloudOnlyItems)
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: []
                )) ?? []

                // One walker across all children, so an inode hard-linked into two
                // of them is attributed once and the children still sum to the
                // parent rather than exceeding it.
                let walker = ParallelTreeWalker(
                    followSymlinks: followSymlinks,
                    protectedPatterns: protectedPatterns,
                    cancelled: cancelled,
                    keys: keys,
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
                    guard let values = try? child.resourceValues(forKeys: Set(keys)) else {
                        walker.recordUnreadable(at: child)
                        continue
                    }
                    if Self.isCloudOnly(values) { walker.markCloudOnly(child) }
                    if values.isSymbolicLink == true {
                        guard followSymlinks else { continue }
                        // A direct symlink child reports neither directory nor
                        // regular file for itself; resolve it or the row measures
                        // nothing with the follow setting on.
                        let resolved = child.resolvingSymlinksInPath()
                        guard let target = try? resolved.resourceValues(
                            forKeys: Set(keys)
                        ) else {
                            walker.recordUnreadable(at: child)
                            continue
                        }
                        if Self.isCloudOnly(target) { walker.markCloudOnly(child) }
                        if target.isDirectory == true {
                            walker.enqueue(
                                listing: resolved,
                                attribution: [child],
                                grow: 0,
                                volume: target.volumeIdentifier as? NSObject
                            )
                        } else {
                            walker.measureLooseFile(
                                target,
                                at: child,
                                volume: target.volumeIdentifier as? NSObject
                            )
                        }
                        continue
                    }
                    if values.isDirectory == true {
                        // Each child defines its own boundary. A mounted child is a
                        // complete measured root, as it was before the parallel walk.
                        walker.enqueue(
                            listing: child,
                            attribution: [child],
                            grow: 0,
                            volume: values.volumeIdentifier as? NSObject
                        )
                    } else {
                        walker.measureLooseFile(
                            values,
                            at: child,
                            volume: values.volumeIdentifier as? NSObject
                        )
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

    fileprivate static func isCloudOnly(_ values: URLResourceValues?) -> Bool {
        values?.isUbiquitousItem == true
            && values?.ubiquitousItemDownloadingStatus != .current
    }

    /// Test support: repeated measurements must use these same long-lived threads.
    static var sharedWorkerIdentities: [ObjectIdentifier] {
        MeasurementWorkerPool.shared.workerIdentities
    }
}

// MARK: - Parallel engine

/// One measurement whose directory work runs on the shared worker pool.
///
/// Each worker pops a directory, lists it with attributes prefetched, adds its
/// regular files to every URL in the item's attribution chain, and pushes its
/// subdirectories back on the queue. One lock guards all shared state; the work
/// inside the lock is arithmetic only — the syscalls happen outside it.
private final class ParallelTreeWalker: @unchecked Sendable {

    private struct WorkItem: @unchecked Sendable {
        /// The directory to list — the real URL, whatever form the parent handed us.
        let listing: URL
        /// The totals keys this directory's files add to, root first. The last
        /// element is the deepest attributed ancestor, and child keys are built by
        /// appending to it — the same `appendPathComponent` chain the lookups use.
        let attribution: [URL]
        /// How many more levels may extend the attribution chain.
        let grow: Int
        /// The volume this measured root belongs to. `measureChildren` gives each
        /// immediate child its own boundary, including mounted children.
        let volume: NSObject?
    }

    private let followSymlinks: Bool
    private let protectedPatterns: [String]
    private let cancelled: CancellationFlag
    private let keys: [URLResourceKey]
    private let progress: (@Sendable (SizeMeasurement) -> Void)?

    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    /// Submitted or active work items. One pool job processes one directory, which
    /// lets concurrent measurements share the pool fairly.
    private var inFlight = 0
    private var isRunning = false
    private var totals: [URL: SizeMeasurement] = [:]
    private var unreadable: [URL: Int] = [:]
    private var claimedInodes = Set<NSObject>()
    /// Directories already queued, tracked only when following symlinks: a link
    /// into a subtree that is walked anyway must not count it twice, and a link to
    /// an ancestor must not walk forever. Keyed by resolved path.
    private var visitedDirectories = Set<String>()
    /// Attribution keys whose subtree holds something matching a protected glob.
    private var protectedKeys = Set<URL>()
    /// Attribution keys whose subtree holds an iCloud item that is not local.
    private var cloudOnlyKeys = Set<URL>()
    /// Every file once, regardless of how many ancestors it is attributed to —
    /// what the progress callback reports.
    private var grandTotal = SizeMeasurement.zero
    private var entriesSinceReport = 0
    private var pendingProgress: [SizeMeasurement] = []
    private var isReportingProgress = false

    /// How often to surface progress and poll cancellation, in entries.
    private static let reportInterval = 512

    init(
        followSymlinks: Bool,
        protectedPatterns: [String] = [],
        cancelled: CancellationFlag,
        keys: [URLResourceKey],
        progress: (@Sendable (SizeMeasurement) -> Void)?
    ) {
        self.followSymlinks = followSymlinks
        self.protectedPatterns = protectedPatterns
        self.cancelled = cancelled
        self.keys = keys
        self.progress = progress
    }

    func enqueue(
        listing: URL,
        attribution: [URL],
        grow: Int,
        volume: NSObject?
    ) {
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
        stack.append(WorkItem(
            listing: listing,
            attribution: attribution,
            grow: grow,
            volume: volume
        ))
        scheduleWorkLocked()
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

    func markCloudOnly(_ key: URL) {
        condition.lock()
        cloudOnlyKeys.insert(key)
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
    func measureLooseFile(
        _ values: URLResourceValues,
        at key: URL,
        volume: NSObject?
    ) {
        if AllocatedSizeMeasurer.isCloudOnly(values) { markCloudOnly(key) }
        if let entryVolume = values.volumeIdentifier as? NSObject, let volume,
           !entryVolume.isEqual(volume) { return }
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

    /// Runs this measurement to exhaustion and returns the totals, unreadable counts folded
    /// in. Throws `CancellationError` if the flag was raised mid-walk.
    func run() throws -> [URL: SizeMeasurement] {
        condition.lock()
        isRunning = true
        scheduleWorkLocked()
        while !stack.isEmpty || inFlight > 0 {
            if cancelled.isCancelled { stack.removeAll() }
            if stack.isEmpty && inFlight == 0 { break }
            condition.wait()
        }
        isRunning = false

        let wasCancelled = cancelled.isCancelled
        for (key, count) in unreadable {
            totals[key, default: .zero].unreadableCount += count
        }
        for key in protectedKeys {
            totals[key, default: .zero].containsProtectedPattern = true
        }
        for key in cloudOnlyKeys {
            totals[key, default: .zero].containsCloudOnlyItem = true
        }
        let result = totals
        condition.unlock()

        if wasCancelled { throw CancellationError() }
        return result
    }

    /// Assigns pending directories to the process-wide workers. Must hold `condition`.
    private func scheduleWorkLocked() {
        guard isRunning else { return }
        if cancelled.isCancelled {
            stack.removeAll()
            return
        }

        let width = MeasurementWorkerPool.shared.width
        while inFlight < width, let item = stack.popLast() {
            inFlight += 1
            MeasurementWorkerPool.shared.submit { [self] in
                process(item)
                finishWorkItem()
            }
        }
    }

    private func finishWorkItem() {
        condition.lock()
        inFlight -= 1
        if cancelled.isCancelled { stack.removeAll() }
        scheduleWorkLocked()
        if stack.isEmpty && inFlight == 0 { condition.broadcast() }
        condition.unlock()
    }

    private func process(_ item: WorkItem) {
        guard !cancelled.isCancelled else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: item.listing,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            // A permission-denied directory costs one entry — never a subtree,
            // and never the whole total.
            recordUnreadable(at: item.attribution[0])
            return
        }

        var localFiles: [Int64] = []

        for entry in entries {
            // Name check first: it needs no attributes, so a protected bundle is
            // recognised even where the entry itself cannot be read.
            if matchesProtectedPattern(entry.lastPathComponent) {
                for key in item.attribution { markProtected(key) }
            }
            guard let values = try? entry.resourceValues(
                forKeys: Set(keys)
            ) else {
                recordUnreadable(at: item.attribution[0])
                continue
            }
            // Never leave the starting volume — a mounted disk under the scan
            // root is not part of this category.
            if let volume = item.volume,
               let entryVolume = values.volumeIdentifier as? NSObject,
               !entryVolume.isEqual(volume) {
                continue
            }
            if AllocatedSizeMeasurer.isCloudOnly(values) {
                for key in item.attribution { markCloudOnly(key) }
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
                    forKeys: Set(keys)
                ) else {
                    recordUnreadable(at: item.attribution[0])
                    continue
                }
                if let volume = item.volume,
                   let targetVolume = target.volumeIdentifier as? NSObject,
                   !targetVolume.isEqual(volume) {
                    continue
                }
                if AllocatedSizeMeasurer.isCloudOnly(target) {
                    for key in item.attribution { markCloudOnly(key) }
                }
                if target.isDirectory == true {
                    let childKey = item.attribution[item.attribution.count - 1]
                        .appendingPathComponent(entry.lastPathComponent)
                    let attribution = item.grow > 0 ? item.attribution + [childKey] : item.attribution
                    enqueue(
                        listing: resolved,
                        attribution: attribution,
                        grow: max(0, item.grow - 1),
                        volume: item.volume
                    )
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
                        if flushIfNeeded(&localFiles, attribution: item.attribution) { return }
                    }
                }
                continue
            }

            if values.isDirectory == true {
                let childKey = item.attribution[item.attribution.count - 1]
                    .appendingPathComponent(entry.lastPathComponent)
                let attribution = item.grow > 0 ? item.attribution + [childKey] : item.attribution
                enqueue(
                    listing: entry,
                    attribution: attribution,
                    grow: max(0, item.grow - 1),
                    volume: item.volume
                )
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
            if flushIfNeeded(&localFiles, attribution: item.attribution) { return }
        }
        if !localFiles.isEmpty {
            let shouldDrain = flush(&localFiles, attribution: item.attribution)
            if shouldDrain { drainProgress() }
        }
    }

    /// Batches arithmetic while still polling cancellation in very wide folders.
    private func flushIfNeeded(_ sizes: inout [Int64], attribution: [URL]) -> Bool {
        guard sizes.count >= Self.reportInterval else { return false }
        let shouldDrain = flush(&sizes, attribution: attribution)
        if shouldDrain { drainProgress() }
        return cancelled.isCancelled
    }

    /// Adds one batch and queues a progress snapshot when the global interval is due.
    /// Returns true only for the worker that must drain the serial callback queue.
    private func flush(_ sizes: inout [Int64], attribution: [URL]) -> Bool {
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

        guard progress != nil, entriesSinceReport >= Self.reportInterval else {
            return false
        }
        entriesSinceReport = 0
        pendingProgress.append(grandTotal)
        guard !isReportingProgress else { return false }
        isReportingProgress = true
        return true
    }

    /// One worker delivers every queued callback. Snapshots remain ordered, and a
    /// caller never receives concurrent progress calls from separate workers.
    private func drainProgress() {
        guard let progress else { return }
        while true {
            condition.lock()
            guard !pendingProgress.isEmpty else {
                isReportingProgress = false
                condition.unlock()
                return
            }
            let snapshot = pendingProgress.removeFirst()
            condition.unlock()
            progress(snapshot)
        }
    }
}

// MARK: - Support

/// Long-lived filesystem workers shared by every measurement.
///
/// A pool job processes one directory. This keeps the thread count bounded while
/// allowing concurrent scans to interleave instead of waiting behind one large walk.
private final class MeasurementWorkerPool: @unchecked Sendable {
    typealias Job = @Sendable () -> Void

    static let shared = MeasurementWorkerPool()

    let width: Int
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var workers: [Thread] = []

    var workerIdentities: [ObjectIdentifier] {
        workers.map(ObjectIdentifier.init)
    }

    private init() {
        width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

        for _ in 0..<width {
            let worker = Thread { [weak self] in
                self?.workerLoop()
            }
            // The user is waiting for the Dashboard and Scanner figures.
            worker.qualityOfService = .userInitiated
            workers.append(worker)
        }
        for worker in workers { worker.start() }
    }

    func submit(_ job: @escaping Job) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func workerLoop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()

            autoreleasepool { job() }
        }
    }
}

/// Bridges structured-concurrency cancellation into the detached, blocking walk.
/// `Task.detached` does not inherit cancellation, so without this the scan's stop
/// button would do nothing.
/// Shared with `PrivateSizeMeasurer`: both walks hand a detached task a flag the
/// cancellation handler can raise from outside it.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return flag
    }
}
