import Foundation

/// Turns a library into duplicate groups.
///
/// Pure logic over `PhotoAsset` values — no PhotoKit, no Vision, no I/O — so every
/// rule below is exercised by `swift test` rather than discovered against a real
/// library after something has already been deleted.
public struct DuplicateGrouper: Sendable {

    public struct Options: Sendable {
        /// Vision feature-print distance below which two images are called the same.
        ///
        /// This wants calibrating against a real library before it is trusted: too
        /// loose merges a series of similar shots into one group and proposes
        /// deleting photos the user meant to keep. It is deliberately conservative,
        /// and `.similar` groups are never pre-selected regardless.
        public var similarityThreshold: Float
        /// Whether the similar tier runs at all.
        ///
        /// Off, the only groups are the ones no threshold decided — a burst, which
        /// is Apple's own grouping, and an identical match, which is a metadata
        /// signature the prints then confirmed. That is a different request from a
        /// very tight threshold: tightening asks for fewer judgement calls, this
        /// asks for none. `similarityThreshold` is left alone rather than set to
        /// zero, because zero is a threshold and would still group prints that
        /// match exactly.
        public var comparesAppearance: Bool
        /// Distance below which two images sharing a metadata signature are called
        /// the same photograph. Far tighter than `similarityThreshold`: this tier
        /// claims certainty, so it must earn it.
        public var exactThreshold: Float
        /// Similar-tier comparison only happens inside a bucket of this width.
        ///
        /// Fingerprint comparison is O(n²), and a 13,000-asset library is 84 million
        /// pairs. Near-duplicates are, essentially by definition, captured close
        /// together, so bucketing by capture time makes the sweep tractable without
        /// costing real matches.
        public var bucketInterval: TimeInterval
        /// Favourites are never proposed for deletion.
        public var protectFavorites: Bool

        public init(
            similarityThreshold: Float = 0.35,
            comparesAppearance: Bool = true,
            exactThreshold: Float = 0.05,
            bucketInterval: TimeInterval = 86_400,
            protectFavorites: Bool = true
        ) {
            self.similarityThreshold = similarityThreshold
            self.comparesAppearance = comparesAppearance
            self.exactThreshold = exactThreshold
            self.bucketInterval = bucketInterval
            self.protectFavorites = protectFavorites
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// How "are these two within `threshold`" gets answered.
    ///
    /// Two sources, one clustering. The arithmetic is the definition; the graph is
    /// the same answers computed once and looked up, which is what makes changing
    /// the similarity setting free. They are held to being the same thing by
    /// `PhotoGraphGroupingTests`, which groups a library both ways at every
    /// threshold and requires the results to be identical — because the moment they
    /// disagree, the fast path is deleting photographs the slow one would keep.
    struct Comparison {
        /// Assets that were fingerprinted. An asset outside this set is never
        /// grouped by a tier that needs pixels: absence of evidence cannot promote
        /// a photo to "duplicate".
        let comparable: Set<String>
        let isWithin: @Sendable (Float, String, String) -> Bool
        let distance: @Sendable (String, String) -> Float?
        /// Everything within the threshold of an id, where that is known without
        /// computing it. Nil means it is not, and the clustering falls back to
        /// asking about every cluster — which is what it always did.
        let neighbours: (@Sendable (Float, String) -> [String])?

        static func prints(_ fingerprints: [String: PhotoFingerprint]) -> Comparison {
            Comparison(
                comparable: Set(fingerprints.keys),
                isWithin: { threshold, a, b in
                    guard let left = fingerprints[a], let right = fingerprints[b] else {
                        return false
                    }
                    return left.isWithin(threshold, of: right)
                },
                distance: { a, b in
                    guard let left = fingerprints[a], let right = fingerprints[b] else {
                        return nil
                    }
                    return left.distance(to: right)
                },
                // Finding them would mean comparing everything against everything,
                // which is the work this would be short-cutting.
                neighbours: nil
            )
        }

        static func graph(_ graph: PhotoNeighbourGraph) -> Comparison {
            Comparison(
                comparable: graph.fingerprinted,
                isWithin: { threshold, a, b in graph.isWithin(threshold, a, b) },
                distance: { a, b in graph.distance(a, b) },
                neighbours: { threshold, id in graph.neighbours(within: threshold, of: id) }
            )
        }
    }

    /// Groups `assets`, consulting `fingerprints` only for the similar tier.
    ///
    /// Each asset lands in at most one group: the tiers run strongest-first and every
    /// tier skips assets already claimed. Without that, a burst frame would also
    /// match its neighbours on similarity and appear twice, and a user clearing both
    /// groups would delete the frame they had chosen to keep in the other.
    /// - Parameter onProgress: fraction complete, 0...1, reported as buckets are
    ///   compared *and inside a bucket* as its pairs are ground through. Comparison
    ///   is quadratic inside a bucket and one real library put 11,103 photographs
    ///   into a single one, so this phase can run for a noticeable time — long
    ///   enough that a UI with no readout during it looks hung, which is exactly
    ///   how it was first reported.
    ///
    /// Cancellation is cooperative: inside a task, the quadratic loops poll
    /// `Task.isCancelled` every few thousand comparisons and return early with
    /// whatever they had. The result of a cancelled run is partial and must be
    /// discarded — `PhotoDuplicateService` does so by checking cancellation right
    /// after this returns. Polled rather than thrown so the pure API stays pure.
    public func group(
        assets: [PhotoAsset],
        fingerprints: [String: PhotoFingerprint] = [:],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> [DuplicateGroup] {
        group(assets: assets, comparing: .prints(fingerprints), onProgress: onProgress)
    }

    /// The same grouping, reading a graph built once instead of comparing again.
    ///
    /// Returns nil when the graph cannot answer for this threshold — it holds every
    /// pair within its ceiling and nothing beyond, so a stricter question is a
    /// lookup and a looser one is unanswerable. "Not examined" is not "not a match",
    /// and quietly treating it as one would silently drop real duplicates.
    public func group(
        assets: [PhotoAsset],
        graph: PhotoNeighbourGraph,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> [DuplicateGroup]? {
        guard options.exactThreshold <= graph.ceiling,
              !options.comparesAppearance || options.similarityThreshold <= graph.ceiling
        else { return nil }
        return group(assets: assets, comparing: .graph(graph), onProgress: onProgress)
    }

    private func group(
        assets: [PhotoAsset],
        comparing comparison: Comparison,
        onProgress: (@Sendable (Double) -> Void)?
    ) -> [DuplicateGroup] {

        // Hidden assets are a deliberate act by the user. Surfacing them in a bulk
        // delete grid would both expose them and invite removing them by accident.
        let visible = assets.filter { !$0.isHidden }

        var claimed: Set<String> = []
        var groups: [DuplicateGroup] = []

        groups += burstGroups(visible, claiming: &claimed)
        groups += exactGroups(visible, comparing: comparison, claiming: &claimed)
        groups += similarGroups(
            visible, comparing: comparison, claiming: &claimed, onProgress: onProgress
        )

        // Largest first: the biggest wins are the ones worth a person's attention.
        // Ties fall back to the group id so the order is stable between sweeps —
        // a grid that reshuffles under the cursor loses selections.
        return groups.sorted {
            $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count
        }
    }

    // MARK: - Tiers

    private func burstGroups(_ assets: [PhotoAsset], claiming claimed: inout Set<String>) -> [DuplicateGroup] {
        let buckets = Dictionary(grouping: assets.filter { $0.burstIdentifier != nil }) {
            $0.burstIdentifier!
        }
        return buckets.compactMap { identifier, members in
            makeGroup(id: "burst:\(identifier)", kind: .burst, members: members, claiming: &claimed)
        }
    }

    /// Metadata signature *and* visual confirmation.
    ///
    /// The signature alone is not evidence. Measured against a real 9,571-asset
    /// library it produced 803 groups proposing 1,089 deletions, and **every one was
    /// wrong**: the library was largely bulk-imported, so `creationDate` holds the
    /// import timestamp rather than a capture time, and hundreds of distinct
    /// photographs shared a second. Eight different pictures, 171 KB to 453 KB, all
    /// stamped 2023-03-07 10:56:37 at 2048x1536, would have been reduced to one.
    ///
    /// So the signature is demoted to a cheap bucketing key and the tier only groups
    /// what the feature prints agree on. An asset with no fingerprint is never
    /// grouped here — absence of evidence cannot promote a photo to "duplicate".
    private func exactGroups(
        _ assets: [PhotoAsset],
        comparing comparison: Comparison,
        claiming claimed: inout Set<String>
    ) -> [DuplicateGroup] {
        let candidates = assets.filter {
            !claimed.contains($0.id) && comparison.comparable.contains($0.id)
        }
        let buckets = Dictionary(grouping: candidates.compactMap { asset -> (String, PhotoAsset)? in
            guard let signature = asset.exactSignature else { return nil }
            return (signature, asset)
        }, by: \.0).mapValues { $0.map(\.1) }

        var groups: [DuplicateGroup] = []
        for (signature, members) in buckets.sorted(by: { $0.key < $1.key }) {
            if Task.isCancelled { break }
            guard members.count > 1 else { continue }
            for cluster in cluster(members, comparing: comparison, threshold: options.exactThreshold)
            where cluster.count > 1 {
                if let group = makeGroup(
                    id: "exact:\(signature):\(cluster.map(\.id).min() ?? "")",
                    kind: .exact,
                    members: cluster,
                    claiming: &claimed
                ) {
                    groups.append(group)
                }
            }
        }
        return groups
    }

    private func similarGroups(
        _ assets: [PhotoAsset],
        comparing comparison: Comparison,
        claiming claimed: inout Set<String>,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> [DuplicateGroup] {
        guard options.comparesAppearance, !comparison.comparable.isEmpty else { return [] }

        // Only stills. Two frames of different videos routinely fingerprint alike,
        // and a video is never a "duplicate" of another on one frame's evidence.
        let candidates = assets.filter {
            !claimed.contains($0.id) && $0.mediaType == .image
                && comparison.comparable.contains($0.id)
        }

        var groups: [DuplicateGroup] = []
        // Weighted by n², because that is what a bucket actually costs. Counting
        // buckets instead would sit at 99% through the one that takes all the time.
        let buckets = timeBuckets(candidates)
        let totalCost = buckets.reduce(0.0) { $0 + pow(Double($1.1.count), 2) }
        var doneCost = 0.0

        for (bucket, members) in buckets {
            if Task.isCancelled { break }
            defer {
                doneCost += pow(Double(members.count), 2)
                onProgress?(totalCost > 0 ? doneCost / totalCost : 1)
            }
            guard members.count > 1 else { continue }
            // Progress inside the bucket, weighted the same way: after `done`
            // photos the pairs compared grow with done squared, matching the n
            // squared the bucket was costed at. Without this, a bulk-imported
            // library — which lands almost whole in one bucket — froze the bar
            // for the entire grind.
            let bucketBase = doneCost
            let bucketCost = pow(Double(members.count), 2)
            for cluster in cluster(
                members, comparing: comparison, threshold: options.similarityThreshold,
                onProgress: { done, count in
                    guard totalCost > 0, count > 0 else { return }
                    let within = pow(Double(done), 2) / pow(Double(count), 2)
                    onProgress?(min(1, (bucketBase + within * bucketCost) / totalCost))
                }
            )
            where cluster.count > 1 {
                if let group = makeGroup(
                    id: "similar:\(bucket):\(cluster.map(\.id).min() ?? "")",
                    kind: .similar,
                    members: cluster,
                    claiming: &claimed,
                    // Measured over the cluster alone, which is a handful of photos
                    // against the bucket's thousands — the quadratic cost that made
                    // `isWithin` early-exit does not apply at this size.
                    distance: diameter(of: cluster, comparing: comparison)
                ) {
                    groups.append(group)
                }
            }
        }
        return groups
    }

    /// Buckets by capture time so similarity is only ever computed within a window.
    /// Assets with no creation date get their own bucket and so never match — there
    /// is no evidence they were taken near anything.
    private func timeBuckets(_ assets: [PhotoAsset]) -> [(Int, [PhotoAsset])] {
        var buckets: [Int: [PhotoAsset]] = [:]
        var orphanKey = -1
        for asset in assets {
            guard let date = asset.creationDate else {
                buckets[orphanKey, default: []].append(asset)
                orphanKey -= 1
                continue
            }
            let key = Int(date.timeIntervalSince1970 / options.bucketInterval)
            buckets[key, default: []].append(asset)
        }
        return buckets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Complete-linkage clustering: a photo joins a cluster only when it is within
    /// the threshold of **every** member already in it.
    ///
    /// Single linkage — joining on one close neighbour — was tried first and is
    /// wrong for this. It chains: A resembles B and B resembles C, so A and C land in
    /// one group however little they have in common. Measured on a real library, 162
    /// of 976 groups contained pairs up to twice the threshold apart, and one
    /// 16-photo "duplicate" group of a road at sunset had a close-up portrait of a
    /// different person chained into it.
    ///
    /// Complete linkage bounds a group's diameter by the threshold, so every photo in
    /// a group really does resemble every other one — which is the claim the grid
    /// makes to the user when it offers to delete all but one of them.
    private func cluster(
        _ assets: [PhotoAsset],
        comparing comparison: Comparison,
        threshold: Float,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> [[PhotoAsset]] {
        // Deterministic input order, so a rerun produces identical clusters.
        let ordered = assets.sorted { $0.id < $1.id }
        let ids = ordered.map(\.id)

        var clusters: [[Int]] = []
        // Which cluster each id ended up in, so a candidate's neighbours can be
        // turned into the short list of clusters worth asking about.
        var clusterOfID: [String: Int] = [:]

        for index in ordered.indices {
            // Every 128 assets: cheap enough to be free against the quadratic
            // work, frequent enough that Stop lands within a beat and the bar
            // moves through even a bucket holding the whole library.
            if index.isMultiple(of: 128) {
                if Task.isCancelled { break }
                onProgress?(index, ordered.count)
            }
            guard comparison.comparable.contains(ids[index]) else { continue }

            // Only clusters holding something this photograph is already known to
            // resemble. Complete linkage needs every member within the threshold,
            // so a cluster with no neighbour in it cannot possibly accept it — and
            // the candidates are taken in cluster order, which is the order the
            // exhaustive scan would have found them in. Same answer, asked of a
            // handful of clusters instead of all of them.
            let searchable: [Int]
            if let neighbours = comparison.neighbours {
                searchable = Set(neighbours(threshold, ids[index]).compactMap { clusterOfID[$0] })
                    .sorted()
            } else {
                searchable = Array(clusters.indices)
            }

            let match = searchable.first { candidate in
                clusters[candidate].allSatisfy {
                    comparison.isWithin(threshold, ids[index], ids[$0])
                }
            }
            if let match {
                clusters[match].append(index)
                clusterOfID[ids[index]] = match
            } else {
                clusters.append([index])
                clusterOfID[ids[index]] = clusters.count - 1
            }
        }
        return clusters.map { $0.map { ordered[$0] } }
    }

    // MARK: - Group construction

    /// Builds a group, or returns nil when there is nothing safe to remove from it.
    ///
    /// Marks members claimed only when a group is actually produced, so assets
    /// rejected here stay available to weaker tiers.
    /// The distance between the two least alike members — the group's diameter.
    ///
    /// Every member of a similar cluster has a fingerprint, because `cluster` skips
    /// any asset without one, so the refusals below do not fire on the path that
    /// calls this. They are here because a diameter measured over *some* of a group
    /// is not that group's diameter: it would read as a tighter match than was
    /// actually made, which is the one thing this figure must never do.
    private func diameter(of members: [PhotoAsset], comparing comparison: Comparison) -> Float? {
        var worst: Float = 0
        for i in members.indices {
            for j in members.indices where j > i {
                guard let distance = comparison.distance(members[i].id, members[j].id) else {
                    return nil
                }
                worst = max(worst, distance)
            }
        }
        return worst
    }

    private func makeGroup(
        id: String,
        kind: DuplicateGroup.Kind,
        members: [PhotoAsset],
        claiming claimed: inout Set<String>,
        distance: Float? = nil
    ) -> DuplicateGroup? {
        let available = members.filter { !claimed.contains($0.id) }
        guard available.count > 1 else { return nil }

        let keeper = chooseKeeper(from: available, kind: kind)
        var removable = available.filter { $0.id != keeper.id }

        // A favourite is an explicit statement that the user wants this picture. It
        // can be the keeper, never a casualty.
        if options.protectFavorites {
            removable = removable.filter { !$0.isFavorite }
        }
        guard !removable.isEmpty else { return nil }

        claimed.insert(keeper.id)
        claimed.formUnion(removable.map(\.id))
        let reason = keeperReason(keeper, over: removable, kind: kind)

        // Protected favourites are dropped from the group entirely rather than shown
        // as undeletable members: the grid's contract is that everything beside the
        // keeper is going, and an exception inside it invites a mis-click.
        return DuplicateGroup(
            id: id, kind: kind, keeper: keeper, keeperReason: reason,
            removable: removable, maximumDistance: distance
        )
    }

    /// Picks the survivor.
    ///
    /// Ordered so that every rule is a statement about what the *user* valued, not
    /// about what is technically largest — except as a last resort, where more pixels
    /// is the only non-arbitrary tie-break left.
    ///
    /// Members are ordered by id before ranking so that a tie resolves the same way
    /// on every run. A keeper that moves between sweeps would silently change which
    /// photo a pre-made selection deletes.
    func chooseKeeper(from members: [PhotoAsset], kind: DuplicateGroup.Kind) -> PhotoAsset {
        let ordered = members.sorted { $0.id < $1.id }
        var best = ordered[0]
        for candidate in ordered.dropFirst()
        where isBetterKeeper(candidate, than: best, kind: kind) {
            best = candidate
        }
        return best
    }

    private func isBetterKeeper(_ a: PhotoAsset, than b: PhotoAsset, kind: DuplicateGroup.Kind) -> Bool {
        let left = rank(a, kind: kind)
        let right = rank(b, kind: kind)
        for (l, r) in zip(left, right) where l != r { return l > r }
        return false
    }

    /// Which rule actually decided it, for the grid to show.
    ///
    /// Mirrors the order in `rank`, and reports the first rule that genuinely
    /// separated the keeper from the field rather than the first that merely applied
    /// to it — "highest resolution" is a lie when every copy has the same dimensions.
    func keeperReason(
        _ keeper: PhotoAsset,
        over others: [PhotoAsset],
        kind: DuplicateGroup.Kind
    ) -> DuplicateGroup.KeeperReason {
        if keeper.isFavorite, !others.contains(where: \.isFavorite) { return .favorite }
        if kind == .burst, keeper.representsBurst { return .burstPick }
        if keeper.hasAdjustments, !others.contains(where: \.hasAdjustments) { return .edited }
        if let best = others.map(\.pixelCount).max(), keeper.pixelCount > best { return .resolution }
        return .earliest
    }

    private func rank(_ asset: PhotoAsset, kind: DuplicateGroup.Kind) -> [Int] {
        [
            asset.isFavorite ? 1 : 0,
            // Only meaningful inside a burst, where Photos records which frame the
            // user picked. Elsewhere it is always false and costs nothing.
            (kind == .burst && asset.representsBurst) ? 1 : 0,
            asset.hasAdjustments ? 1 : 0,
            asset.pixelCount,
            // Earlier wins: the first copy is the original, later ones are re-imports.
            // Negated so that "larger rank is better" holds throughout.
            -Int(asset.creationDate?.timeIntervalSince1970 ?? 0)
        ]
    }
}
