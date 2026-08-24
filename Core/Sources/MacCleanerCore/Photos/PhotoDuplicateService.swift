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
    private var running: Task<PhotoDuplicateResults, Error>?

    public init(
        library: any PhotoLibraryProviding,
        grouper: DuplicateGrouper = DuplicateGrouper(),
        visionRevision: UInt32
    ) {
        self.library = library
        self.grouper = grouper
        self.visionRevision = visionRevision
    }

    public var isSweeping: Bool { running != nil }

    public func cancel() {
        running?.cancel()
        running = nil
    }

    /// Sweeps the library, or joins the sweep already in flight.
    ///
    /// - Parameter minimumAssets: refuse to run below this count. A library still
    ///   coming down from iCloud yields confident-looking groups computed over a
    ///   fraction of the photos, and the copies that would have been kept may not
    ///   have arrived yet. Zero disables the guard.
    public func sweep(
        minimumAssets: Int = 0,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> PhotoDuplicateResults {
        if let running { return try await running.value }

        let task = Task { [library, grouper, visionRevision] in
            let startedAt = Date()
            let access = await library.authorize()
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
            let claimed = Set(bursts.flatMap(\.assets).map(\.id))

            let candidates = assets.filter {
                !claimed.contains($0.id) && !$0.isHidden && $0.mediaType == .image
            }

            var cache = FingerprintCache.load(expectingRevision: visionRevision)
                ?? FingerprintCache(visionRevision: visionRevision, elementCount: 0)
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
                    guard next < needed.endIndex else { return }
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
                ).save()
            }
            try Task.checkCancellation()

            // Re-group with prints in hand. Bursts reach the same verdict they did
            // above — that tier never consults fingerprints — so this is one pass
            // producing one disjoint set, not two sets to reconcile.
            let groups = grouper.group(assets: assets, fingerprints: cache.prints) { fraction in
                onProgress?(Progress(
                    stage: .grouping,
                    percent: Int(comparingBase + fraction * (100 - comparingBase)),
                    completed: candidates.count, total: candidates.count, fromCache: cached
                ))
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

            return PhotoDuplicateResults(
                groups: groups,
                examinedCount: assets.filter { !$0.isHidden }.count,
                skippedCount: skipped,
                startedAt: startedAt,
                finishedAt: Date()
            )
        }

        running = task
        defer { running = nil }
        return try await task.value
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
