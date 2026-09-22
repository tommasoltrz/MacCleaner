import Foundation

/// Runs a duplicate sweep end to end.
///
/// An actor for the same reason `ScanCoordinator` is one: a sweep is reachable from
/// the sidebar and the toolbar, and starting a second one while the first is
/// fingerprinting would double the work — and, now that misses are fetched from
/// iCloud, double the network traffic too.
public actor PhotoDuplicateService {

    public struct Progress: Sendable, Equatable {
        public enum Stage: String, Sendable {
            case fetching, grouping, fingerprinting, done
        }
        public var stage: Stage
        public var percent: Int
        /// Assets fingerprinted so far, and how many need one. Shown as a count
        /// rather than a bare percentage: most of the wait is network, and "4,120 of
        /// 12,963" tells the user something a spinner does not.
        public var completed: Int
        public var total: Int
        /// Prints served from cache — work this sweep did not have to redo.
        public var fromCache: Int

        public init(
            stage: Stage, percent: Int, completed: Int = 0, total: Int = 0, fromCache: Int = 0
        ) {
            self.stage = stage
            self.percent = percent
            self.completed = completed
            self.total = total
            self.fromCache = fromCache
        }
    }

    /// Fingerprint requests in flight at once.
    ///
    /// Each miss is an iCloud round-trip, so running them one at a time would take
    /// hours across a 13,000-asset library. Kept modest deliberately: PhotoKit
    /// serialises its own image requests internally, and a larger window mostly buys
    /// queueing rather than throughput.
    private static let fingerprintConcurrency = 8

    private let library: any PhotoLibraryProviding
    private let grouper: DuplicateGrouper
    private let visionRevision: UInt32
    private let cacheDirectory: URL?
    private var running: Task<Sweep, Error>?
    private var runningID: UUID?
    private var runningCancellation: SweepCancellation?
    /// What the last finished sweep grouped, kept so that changing the similarity
    /// setting costs nothing at all.
    ///
    /// The graph holds every pair within the loosest setting the picker offers, so
    /// each setting is a filter over it rather than a reason to compare again. On a
    /// real library of 11,220 prints that is 12,695 pairs out of 62,938,590 — 148 KB
    /// — against the 34 MB the prints themselves would cost to retain, and a lookup
    /// against the seconds the arithmetic takes.
    private var lastSweep: (assets: [PhotoAsset], graph: PhotoNeighbourGraph)?

    /// - Parameter cacheDirectory: where the fingerprint cache is read and written.
    ///   Nil is the app's own Application Support folder; a test passes a temporary
    ///   directory so a sweep cannot overwrite the real one.
    public init(
        library: any PhotoLibraryProviding,
        grouper: DuplicateGrouper = DuplicateGrouper(),
        visionRevision: UInt32,
        cacheDirectory: URL? = nil
    ) {
        self.library = library
        self.grouper = grouper
        self.visionRevision = visionRevision
        self.cacheDirectory = cacheDirectory
    }

    public var isSweeping: Bool { running != nil }

    public func cancel() {
        runningCancellation?.cancel()
        running?.cancel()
    }

    /// Sweeps the library, or joins the sweep already in flight.
    ///
    /// - Parameter minimumAssets: refuse to run below this count. A library still
    ///   coming down from iCloud yields confident-looking groups computed over a
    ///   fraction of the photos, and the copies that would have been kept may not
    ///   have arrived yet. Zero disables the guard.
    /// - Parameter similarity: how alike the similar tier requires two photographs
    ///   to be. Re-running at a different setting costs the comparing phase and
    ///   nothing else: the feature prints come back from the cache, which is the
    ///   expensive half and is unaffected by the threshold.
    public func sweep(
        minimumAssets: Int = 0,
        similarity: PhotoSimilarity = .default,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> PhotoDuplicateResults {
        try Task.checkCancellation()
        if let running {
            if running.isCancelled {
                // Finish canceled work before another sweep uses the same cache.
                let previousID = runningID
                _ = try? await running.value
                try Task.checkCancellation()
                if runningID == previousID {
                    self.running = nil
                    runningID = nil
                    runningCancellation = nil
                }
                return try await sweep(minimumAssets: minimumAssets, similarity: similarity, onProgress: onProgress)
            }
            let cancellation = runningCancellation
            let result = try await withTaskCancellationHandler {
                try await running.value
            } onCancel: {
                cancellation?.cancel()
                running.cancel()
            }
            try Task.checkCancellation()
            return result.results
        }

        // Everything the injected grouper was given, with the one option that is
        // the user's to set replaced. Built here rather than at init so that
        // changing the setting does not mean rebuilding the service — and with it
        // the in-flight-sweep guard above.
        var options = grouper.options
        similarity.apply(to: &options)
        let grouper = DuplicateGrouper(options: options)

        let id = UUID()
        let cancellation = SweepCancellation()
        let task = Task.detached { [library, grouper, visionRevision, cacheDirectory] in
            try Task.checkCancellation()
            let startedAt = Date()
            let access = await library.authorize()
            try Task.checkCancellation()
            guard access.canSweep else { throw PhotoSweepUnavailable.access(access) }

            onProgress?(Progress(stage: .fetching, percent: 0))
            let assets = try await library.fetchAssets()
            try Task.checkCancellation()

            if minimumAssets > 0, assets.count < minimumAssets {
                throw PhotoSweepUnavailable.librarySyncing(assetCount: assets.count)
            }

            // Bursts first. Theirs is the one verdict that needs no pixels: the burst
            // identifier comes from Photos itself, so those assets can be claimed
            // before any fingerprinting and excluded from the expensive pass.
            //
            // Nothing else can be settled here. Grouping on metadata alone was
            // measured against a real library and was wrong every single time, so
            // both remaining tiers require a fingerprint and this call returns
            // bursts only.
            onProgress?(Progress(stage: .grouping, percent: 5))
            let bursts = grouper.group(assets: assets)
            try Task.checkCancellation()
            let claimed = Set(bursts.flatMap(\.assets).map(\.id))

            let candidates = assets.filter {
                !claimed.contains($0.id) && !$0.isHidden && $0.mediaType == .image
            }

            var cache = FingerprintCache.load(expectingRevision: visionRevision, in: cacheDirectory)
                ?? FingerprintCache(visionRevision: visionRevision, elementCount: 0)
            try Task.checkCancellation()
            cache.retaining(Set(assets.map(\.id)))

            let needed = candidates.filter { cache[$0.id] == nil }
            let cached = candidates.count - needed.count
            // The bar divides by predicted work, not a fixed schedule. Fingerprinting
            // dominates only when prints are missing — each miss can cost an iCloud
            // round trip — while a fully cached sweep spends nearly all its time
            // comparing. Scale its band by the share of prints actually needed and
            // let comparing take everything that remains.
            let fingerprintBand = 85.0 * Double(needed.count) / Double(max(candidates.count, 1))
            let comparingBase = 10.0 + fingerprintBand
            onProgress?(Progress(
                stage: .fingerprinting, percent: 10,
                completed: cached, total: candidates.count, fromCache: cached
            ))

            var fresh: [String: PhotoFingerprint] = [:]
            var skipped = 0
            var done = 0

            // Bounded concurrency: refill a slot as each request lands, rather than
            // waiting for a whole batch, so one slow iCloud fetch cannot stall seven
            // idle workers.
            await withTaskGroup(of: (String, PhotoFingerprint?).self) { group in
                var next = needed.startIndex
                func addTask() {
                    guard !Task.isCancelled, next < needed.endIndex else { return }
                    let assetID = needed[next].id
                    next = needed.index(after: next)
                    group.addTask { (assetID, await library.fingerprint(assetID: assetID)) }
                }
                for _ in 0..<Self.fingerprintConcurrency { addTask() }

                while let (assetID, fingerprint) = await group.next() {
                    if let fingerprint {
                        fresh[assetID] = fingerprint
                    } else {
                        // No thumbnail and none obtainable. Counted, never silently
                        // treated as "no match".
                        skipped += 1
                    }
                    done += 1
                    if done % 25 == 0 || done == needed.count {
                        let ratio = Double(done) / Double(max(needed.count, 1))
                        onProgress?(Progress(
                            stage: .fingerprinting, percent: 10 + Int(ratio * fingerprintBand),
                            completed: cached + done, total: candidates.count, fromCache: cached
                        ))
                    }
                    if Task.isCancelled { break }
                    addTask()
                }
                group.cancelAll()
            }

            // Persist before checking cancellation: prints already paid for over the
            // network are worth keeping even if the user stopped the sweep.
            for (id, fingerprint) in fresh { cache[id] = fingerprint }
            if let width = fresh.values.first?.vector.count ?? cache.prints.values.first?.vector.count {
                FingerprintCache(
                    visionRevision: visionRevision,
                    elementCount: UInt32(width),
                    prints: cache.prints
                ).save(in: cacheDirectory)
            }
            try Task.checkCancellation()

            // Every pair close enough to matter at *any* setting, found once. The
            // ceiling is the loosest the picker offers, so from here on a change of
            // setting is a filter rather than this work again.
            let graph = PhotoNeighbourGraph.build(
                assets: assets,
                fingerprints: cache.prints,
                bucketInterval: grouper.options.bucketInterval,
                ceiling: PhotoSimilarity.ceiling,
                isCancelled: { cancellation.isCancelled }
            ) { fraction in
                onProgress?(Progress(
                    stage: .grouping,
                    percent: Int(comparingBase + fraction * (100 - comparingBase)),
                    completed: candidates.count, total: candidates.count, fromCache: cached
                ))
            }
            try Task.checkCancellation()

            // Bursts reach the same verdict they did above — that tier never
            // consults fingerprints — so this is one pass producing one disjoint
            // set, not two sets to reconcile.
            guard let groups = grouper.group(assets: assets, graph: graph) else {
                // Unreachable while the ceiling is the maximum the picker offers,
                // and a throw rather than a silent empty result if that ever stops
                // being true: a grouping nobody could compute is not "no duplicates".
                throw PhotoSweepUnavailable.access(.authorized)
            }
            // A cancelled grouper returns early with partial groups; surface the
            // cancellation rather than presenting them as a finished sweep.
            try Task.checkCancellation()

            // Done only now: this used to fire before comparing, so the bar touched
            // 100 and then fell back for the longest phase of a cached sweep.
            onProgress?(Progress(
                stage: .done, percent: 100,
                completed: candidates.count, total: candidates.count, fromCache: cached
            ))

            return Sweep(
                results: PhotoDuplicateResults(
                    groups: groups,
                    examinedCount: assets.filter { !$0.isHidden }.count,
                    skippedCount: skipped,
                    startedAt: startedAt,
                    finishedAt: Date()
                ),
                assets: assets,
                graph: graph
            )
        }

        running = task
        runningID = id
        runningCancellation = cancellation
        defer {
            if runningID == id {
                running = nil
                runningID = nil
                runningCancellation = nil
            }
        }
        let sweep = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        lastSweep = (sweep.assets, sweep.graph)
        return sweep.results
    }

    /// Everything a sweep produced, including what a regroup will need again.
    private struct Sweep: Sendable {
        var results: PhotoDuplicateResults
        var assets: [PhotoAsset]
        var graph: PhotoNeighbourGraph
    }

    /// Shares cancellation with dispatch workers that have no Swift task context.
    private final class SweepCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() { lock.withLock { cancelled = true } }
    }

    /// Re-groups the last sweep at a different similarity, without sweeping.
    ///
    /// Returns nil when there is nothing to regroup — no sweep has run in this
    /// session — which is the caller's cue to run one.
    ///
    /// No comparing happens here at all: every pair the grouping could care about
    /// is already in the graph, and this walks it. Measured against the arithmetic
    /// it replaces, it is a dictionary lookup per pair instead of up to 768
    /// subtractions, over 12,695 stored pairs instead of 62.9 million computed ones.
    public func regroup(
        similarity: PhotoSimilarity,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> PhotoDuplicateResults? {
        guard running == nil, let lastSweep else { return nil }

        var options = grouper.options
        similarity.apply(to: &options)
        let grouper = DuplicateGrouper(options: options)
        let startedAt = Date()

        guard let groups = grouper.group(assets: lastSweep.assets, graph: lastSweep.graph) else {
            // The graph cannot answer for this threshold. Nil, never an empty
            // result: "not examined" is not "no duplicates".
            return nil
        }
        try Task.checkCancellation()
        onProgress?(Progress(stage: .done, percent: 100))

        return PhotoDuplicateResults(
            groups: groups,
            examinedCount: lastSweep.assets.filter { !$0.isHidden }.count,
            // The same photographs went unfingerprinted as before: this pass read
            // no thumbnails at all, so it can neither add to that count nor cure it.
            skippedCount: skipped(in: lastSweep),
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    /// Image assets with no fingerprint — the ones a sweep could not read.
    private func skipped(
        in sweep: (assets: [PhotoAsset], graph: PhotoNeighbourGraph)
    ) -> Int {
        sweep.assets.filter {
            !$0.isHidden && $0.mediaType == .image && !sweep.graph.fingerprinted.contains($0.id)
        }.count
    }

    /// Deletes the assets the user confirmed.
    ///
    /// Takes ids rather than groups so the caller cannot accidentally hand over a
    /// whole group — including its keeper — by passing the wrong property.
    public func delete(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        try await library.delete(assetIDs: assetIDs)
    }
}
