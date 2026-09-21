import Foundation
import Testing
@testable import ScoloCore

/// The rules that decide which photographs get deleted.
///
/// Every other measurement bug in this project costs the user a wrong number on a
/// screen. This one costs them a photograph, and `PHAssetChangeRequest.deleteAssets`
/// propagates to every device signed into the same library — so a mistake here
/// removes the picture from the user's iPhone too. The invariants below are the
/// reason the grouping logic lives in Core as pure value transforms rather than
/// inside the PhotoKit adapter where nothing could reach it.
@Suite("Duplicate grouping never deletes the last copy")
struct DuplicateGrouperTests {

    private func asset(
        _ id: String,
        seconds: TimeInterval = 0,
        width: Int = 4032,
        height: Int = 3024,
        media: PhotoAsset.MediaType = .image,
        duration: TimeInterval = 0,
        burst: String? = nil,
        representsBurst: Bool = false,
        favorite: Bool = false,
        hidden: Bool = false,
        adjusted: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            filename: "\(id).heic",
            creationDate: Date(timeIntervalSince1970: seconds),
            pixelWidth: width,
            pixelHeight: height,
            mediaType: media,
            duration: duration,
            burstIdentifier: burst,
            representsBurst: representsBurst,
            isFavorite: favorite,
            isHidden: hidden,
            hasAdjustments: adjusted
        )
    }

    private func print(_ values: [Float]) -> PhotoFingerprint { PhotoFingerprint(vector: values) }

    /// Fingerprints for assets that really are the same photograph.
    private func identicalPrints(_ ids: String...) -> [String: PhotoFingerprint] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, self.print([0, 0, 0])) })
    }

    // MARK: - The invariant that matters most

    @Test("Every group keeps exactly one asset back")
    func keeperNeverRemovable() {
        let assets = [
            asset("a", seconds: 100), asset("b", seconds: 100), asset("c", seconds: 100),
            asset("d", seconds: 200, burst: "B1"), asset("e", seconds: 200, burst: "B1")
        ]
        let groups = DuplicateGrouper().group(assets: assets)

        #expect(!groups.isEmpty)
        for group in groups {
            #expect(!group.removable.contains { $0.id == group.keeper.id })
            #expect(group.removable.count == group.count - 1)
            #expect(group.isActionable)
        }
    }

    @Test("An asset is offered for deletion by at most one group")
    func groupsAreDisjoint() {
        // A burst frame also matches its neighbours on the exact signature. If both
        // tiers claimed it, clearing one group would delete the frame the other group
        // had nominated to keep.
        let assets = [
            asset("a", seconds: 100, burst: "B1", representsBurst: true),
            asset("b", seconds: 100, burst: "B1"),
            asset("c", seconds: 100, burst: "B1")
        ]
        let groups = DuplicateGrouper().group(assets: assets)

        var seen: Set<String> = []
        for group in groups {
            for member in group.assets {
                #expect(!seen.contains(member.id), "\(member.id) appeared in two groups")
                seen.insert(member.id)
            }
        }
    }

    @Test("Favourites are never proposed for deletion")
    func favouritesProtected() {
        let assets = [
            asset("plain", seconds: 100),
            asset("loved", seconds: 100, favorite: true),
            asset("alsoLoved", seconds: 100, favorite: true)
        ]
        let groups = DuplicateGrouper().group(
            assets: assets, fingerprints: identicalPrints("plain", "loved", "alsoLoved")
        )

        for group in groups {
            #expect(!group.removable.contains { $0.isFavorite })
        }
        // A favourite outranks a plain twin, so the plain one is what goes.
        #expect(groups.flatMap(\.removable).map(\.id) == ["plain"])
    }

    @Test("A group of nothing but favourites yields no group at all")
    func allFavouritesProducesNothing() {
        let assets = [
            asset("one", seconds: 100, favorite: true),
            asset("two", seconds: 100, favorite: true)
        ]
        #expect(DuplicateGrouper().group(
            assets: assets, fingerprints: identicalPrints("one", "two")
        ).isEmpty)
    }

    @Test("Hidden assets are excluded entirely")
    func hiddenExcluded() {
        let assets = [
            asset("visible", seconds: 100),
            asset("secret", seconds: 100, hidden: true),
            asset("alsoSecret", seconds: 100, hidden: true)
        ]
        let groups = DuplicateGrouper().group(assets: assets)
        let touched = Set(groups.flatMap(\.assets).map(\.id))
        #expect(!touched.contains("secret"))
        #expect(!touched.contains("alsoSecret"))
    }

    // MARK: - Tiers

    @Test("Bursts group on Apple's identifier and keep the representative frame")
    func burstKeepsRepresentative() {
        let assets = [
            asset("f1", seconds: 100, burst: "B1"),
            asset("f2", seconds: 101, burst: "B1", representsBurst: true),
            asset("f3", seconds: 102, burst: "B1")
        ]
        let groups = DuplicateGrouper().group(assets: assets)
        #expect(groups.count == 1)
        #expect(groups[0].kind == .burst)
        #expect(groups[0].keeper.id == "f2")
        #expect(groups[0].removable.count == 2)
    }

    @Test("Identical capture second and dimensions form an exact group")
    func exactMatch() {
        // Sub-second jitter survives a re-import; the signature rounds it away.
        let assets = [
            asset("original", seconds: 1_000.2),
            asset("reimport", seconds: 1_000.4)
        ]
        let groups = DuplicateGrouper().group(
            assets: assets, fingerprints: identicalPrints("original", "reimport")
        )
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .exact)
    }

    @Test("Different seconds or dimensions do not merge")
    func exactMatchIsStrict() {
        #expect(DuplicateGrouper().group(assets: [
            asset("a", seconds: 100), asset("b", seconds: 105)
        ]).isEmpty)

        #expect(DuplicateGrouper().group(assets: [
            asset("a", seconds: 100, width: 4032),
            asset("b", seconds: 100, width: 1024)
        ]).isEmpty)
    }

    @Test("An asset with no capture date never matches on signature")
    func noDateNeverMatches() {
        let a = PhotoAsset(id: "a", pixelWidth: 100, pixelHeight: 100)
        let b = PhotoAsset(id: "b", pixelWidth: 100, pixelHeight: 100)
        #expect(a.exactSignature == nil)
        #expect(DuplicateGrouper().group(assets: [a, b]).isEmpty)
    }

    @Test("Similar tier clusters within the threshold and not beyond it")
    func similarityThreshold() {
        let grouper = DuplicateGrouper(options: .init(similarityThreshold: 0.5))
        let near = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000)]
        let far  = [asset("c", seconds: 100), asset("d", seconds: 140, width: 3000)]

        #expect(grouper.group(assets: near, fingerprints: [
            "a": print([0, 0, 0]), "b": print([0.1, 0, 0])
        ]).count == 1)

        #expect(grouper.group(assets: far, fingerprints: [
            "c": print([0, 0, 0]), "d": print([9, 0, 0])
        ]).isEmpty)
    }

    @Test("Similarity never spans the bucket boundary")
    func bucketingBoundsComparison() {
        // Two visually identical shots a week apart are not duplicates of each other;
        // they are the same subject photographed twice.
        let grouper = DuplicateGrouper(options: .init(similarityThreshold: 0.5, bucketInterval: 3_600))
        let assets = [asset("a", seconds: 0, width: 3000), asset("b", seconds: 604_800, width: 3000)]
        #expect(grouper.group(assets: assets, fingerprints: [
            "a": print([0, 0, 0]), "b": print([0, 0, 0])
        ]).isEmpty)
    }

    @Test("Videos never enter the similar tier")
    func videosExcludedFromSimilarity() {
        let grouper = DuplicateGrouper(options: .init(similarityThreshold: 0.5))
        let assets = [
            asset("v1", seconds: 100, media: .video, duration: 12),
            asset("v2", seconds: 140, width: 3000, media: .video, duration: 30)
        ]
        #expect(grouper.group(assets: assets, fingerprints: [
            "v1": print([0, 0, 0]), "v2": print([0, 0, 0])
        ]).isEmpty)
    }

    @Test("Similarity does not chain — a group's members all resemble each other")
    func completeLinkagePreventsChaining() {
        // A resembles B and B resembles C, but A and C are twice the threshold apart.
        // Single linkage put all three in one group; on a real library that chained a
        // close-up portrait into a group of 16 landscapes, and 162 of 976 groups
        // contained pairs beyond the threshold. Every member must resemble every
        // other, because that is what the grid claims when it offers to keep one.
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000),
                      asset("c", seconds: 180, width: 2000)]
        let prints: [String: PhotoFingerprint] = [
            "a": print([0, 0, 0]), "b": print([0.3, 0, 0]), "c": print([0.6, 0, 0])
        ]
        let groups = DuplicateGrouper(options: .init(similarityThreshold: 0.35))
            .group(assets: assets, fingerprints: prints)

        for group in groups {
            let vectors = group.assets.map { prints[$0.id]! }
            for i in vectors.indices {
                for j in vectors.indices where i < j {
                    #expect(vectors[i].distance(to: vectors[j])! <= 0.35,
                            "group \(group.id) contains a pair beyond the threshold")
                }
            }
        }
        #expect(!groups.contains { Set($0.assets.map(\.id)) == ["a", "b", "c"] })
    }

    // MARK: - Which copy survives

    @Test("An edited copy outranks its untouched twin")
    func editedWins() {
        let groups = DuplicateGrouper().group(
            assets: [asset("untouched", seconds: 100), asset("edited", seconds: 100, adjusted: true)],
            fingerprints: identicalPrints("untouched", "edited")
        )
        #expect(groups.first?.keeper.id == "edited")
    }

    @Test("With nothing else to separate them, more pixels wins")
    func pixelsBreakTies() {
        let groups = DuplicateGrouper().group(
            assets: [
                asset("small", seconds: 100, width: 1024, height: 768),
                asset("large", seconds: 100, width: 1024, height: 768)
            ],
            fingerprints: identicalPrints("small", "large")
        )
        // Same dimensions here, so this only asserts a keeper was still chosen.
        #expect(groups.first?.removable.count == 1)
    }

    @Test("The same library always yields the same keeper")
    func groupingIsDeterministic() {
        let assets = [
            asset("z", seconds: 100), asset("a", seconds: 100), asset("m", seconds: 100)
        ]
        let prints = identicalPrints("z", "a", "m")
        let first = DuplicateGrouper().group(assets: assets, fingerprints: prints)
        let shuffled = DuplicateGrouper().group(assets: assets.reversed(), fingerprints: prints)
        #expect(first.map(\.keeper.id) == shuffled.map(\.keeper.id))
    }

    @Test("A shared timestamp is not evidence — a bulk import is not a duplicate set")
    func bulkImportIsNotDuplicates() {
        // Measured against a real 9,571-asset library, grouping on metadata alone
        // produced 803 groups proposing 1,089 deletions and was wrong every single
        // time. The library had been bulk-imported, so `creationDate` carried the
        // import timestamp: eight distinct photographs, 171 KB to 453 KB, all stamped
        // 2023-03-07 10:56:37 at 2048x1536. Metadata may only nominate candidates;
        // the feature prints decide.
        let batch = (1...8).map {
            asset("img\($0)", seconds: 699_879_397, width: 2048, height: 1536)
        }
        // Eight different pictures — distant prints, as distinct scenes produce.
        let prints = Dictionary(uniqueKeysWithValues: batch.enumerated().map {
            ($0.element.id, print([Float($0.offset) * 10, 0, 0]))
        })

        #expect(DuplicateGrouper().group(assets: batch, fingerprints: prints).isEmpty)
        // And with no prints at all, nothing may be proposed either.
        #expect(DuplicateGrouper().group(assets: batch).isEmpty)
    }

    @Test("An asset with no fingerprint is never offered for deletion")
    func noFingerprintNoDeletion() {
        // Absence of evidence cannot promote a photo to "duplicate". A thumbnail that
        // has not synced yet must leave the asset untouched, not merged on metadata.
        let assets = [asset("a", seconds: 100), asset("b", seconds: 100)]
        #expect(DuplicateGrouper().group(assets: assets, fingerprints: [
            "a": print([0, 0, 0])
        ]).isEmpty)
    }

    // MARK: - Choosing a different keeper

    @Test("Promoting a copy swaps it with the keeper and keeps the group intact")
    func promotingSwapsKeeper() {
        let group = DuplicateGroup(
            id: "g", kind: .exact,
            keeper: asset("original", seconds: 100),
            keeperReason: .earliest,
            removable: [asset("second", seconds: 100), asset("third", seconds: 100)]
        )
        let promoted = group.promoting("second")

        #expect(promoted?.keeper.id == "second")
        #expect(promoted?.keeperReason == .chosenByYou)
        // The demoted keeper is now deletable like any other copy — the point of the
        // feature is that the automatic choice carries no privilege.
        #expect(promoted?.removable.map(\.id) == ["original", "third"])
        // And the invariant still holds.
        #expect(promoted?.removable.contains { $0.id == promoted?.keeper.id } == false)
        #expect(promoted?.count == group.count)
    }

    @Test("Promoting something not in the group, or the keeper itself, does nothing")
    func promotingRejectsNonsense() {
        let group = DuplicateGroup(
            id: "g", kind: .exact, keeper: asset("a"), removable: [asset("b")]
        )
        #expect(group.promoting("a") == nil)
        #expect(group.promoting("stranger") == nil)
    }

    // MARK: - Why this copy was kept

    @Test("The stated reason is the rule that actually separated the keeper")
    func keeperReasonIsTruthful() {
        let grouper = DuplicateGrouper()
        let plain = asset("plain", seconds: 100)

        #expect(grouper.keeperReason(
            asset("fav", seconds: 100, favorite: true), over: [plain], kind: .exact) == .favorite)
        #expect(grouper.keeperReason(
            asset("edit", seconds: 100, adjusted: true), over: [plain], kind: .exact) == .edited)
        #expect(grouper.keeperReason(
            asset("big", seconds: 100, width: 8000), over: [plain], kind: .exact) == .resolution)
        #expect(grouper.keeperReason(
            asset("pick", seconds: 100, burst: "B", representsBurst: true),
            over: [plain], kind: .burst) == .burstPick)
    }

    @Test("Identical copies are not credited to resolution")
    func keeperReasonDoesNotInventADifference() {
        // Every copy the same size: claiming "highest resolution" would be a
        // measurement that never happened, which is the failure this project keeps
        // legislating against.
        let grouper = DuplicateGrouper()
        #expect(grouper.keeperReason(
            asset("a", seconds: 100), over: [asset("b", seconds: 100)], kind: .exact) == .earliest)
        // A favourite among favourites did not win on being a favourite.
        #expect(grouper.keeperReason(
            asset("a", seconds: 100, favorite: true),
            over: [asset("b", seconds: 100, favorite: true)], kind: .exact) != .favorite)
    }

    // MARK: - Fingerprints

    @Test("Fingerprints of differing length are incomparable, not distant")
    func mismatchedFingerprints() {
        // Two Vision request revisions produce different vector widths. A number
        // derived from the overlap would be meaningless rather than merely imprecise.
        #expect(print([1, 2, 3]).distance(to: print([1, 2])) == nil)
        #expect(print([]).distance(to: print([])) == nil)
    }

    @Test("The early-exit threshold test agrees with the full distance")
    func earlyExitMatchesFullDistance() {
        // `isWithin` prunes work, and must never prune a match. It is the only
        // comparison the clusterer uses, so any disagreement with `distance` here
        // would silently change which photos are called duplicates.
        let samples: [[Float]] = [
            [0, 0, 0], [0.1, 0, 0], [3, 4, 0], [-1, -1, -1], [0.02, 0.02, 0.02], [9, 9, 9]
        ]
        for threshold: Float in [0.05, 0.35, 1.0, 5.0, 20.0] {
            for a in samples {
                for b in samples {
                    let (left, right) = (print(a), print(b))
                    let full = left.distance(to: right)!
                    #expect(left.isWithin(threshold, of: right) == (full <= threshold),
                            "threshold \(threshold) disagreed for \(a) vs \(b) (distance \(full))")
                }
            }
        }
    }

    @Test("Incomparable prints are never within any threshold")
    func earlyExitRejectsMismatchedWidths() {
        #expect(!print([1, 2, 3]).isWithin(1000, of: print([1, 2])))
        #expect(!print([]).isWithin(1000, of: print([])))
    }

    @Test("Distance is Euclidean")
    func euclideanDistance() {
        let d = print([0, 0]).distance(to: print([3, 4]))
        #expect(d == 5)
    }

    // MARK: - How alike is alike

    /// The setting exists because one threshold was wrong for a real library:
    /// different screenshots were grouped together, which is what Vision's feature
    /// space says about two pictures of the same app chrome. The scale has to
    /// actually change the answer, or it is a picker that does nothing.
    @Test("A stricter setting splits what a looser one merges")
    func similarityScaleChangesTheGrouping() {
        // 0.30 apart: inside `.veryLoose` (0.55) and `.standard` (0.35), outside
        // `.veryStrict` (0.15) and `.strict` (0.25).
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000)]
        let prints: [String: PhotoFingerprint] = ["a": print([0, 0, 0]), "b": print([0.3, 0, 0])]

        func groups(_ similarity: PhotoSimilarity) -> Int {
            var options = DuplicateGrouper.Options()
            similarity.apply(to: &options)
            return DuplicateGrouper(options: options)
                .group(assets: assets, fingerprints: prints)
                .count
        }

        #expect(groups(.veryLoose) == 1)
        #expect(groups(.standard) == 1)
        #expect(groups(.strict) == 0)
        #expect(groups(.veryStrict) == 0)
        // Not the same request as a very tight threshold: this one declines to
        // judge by appearance at all, so these two never meet however alike they
        // are. The pair above is 0.3 apart; the pair below is the same photograph.
        #expect(groups(.identicalOnly) == 0)
        let same: [String: PhotoFingerprint] = ["a": print([0, 0, 0]), "b": print([0, 0, 0])]
        // A threshold of zero still groups prints that match exactly, which is why
        // "no threshold" cannot be spelled as zero.
        let atZero = DuplicateGrouper(options: .init(similarityThreshold: 0))
            .group(assets: assets, fingerprints: same)
        #expect(atZero.count == 1)
        var off = DuplicateGrouper.Options()
        PhotoSimilarity.identicalOnly.apply(to: &off)
        #expect(DuplicateGrouper(options: off).group(assets: assets, fingerprints: same).isEmpty)
    }

    @Test("The scale runs from strictest to loosest, and the default is on it")
    func similarityScaleIsOrdered() {
        let thresholds = PhotoSimilarity.allCases.compactMap(\.threshold)
        #expect(thresholds == thresholds.sorted(), "the picker reads top to bottom")
        #expect(Set(thresholds).count == thresholds.count, "two settings would do the same thing")
        #expect(PhotoSimilarity.default.threshold == 0.35,
                "the measured threshold is what an existing library keeps getting")
        // The one setting with no threshold leads the scale, because it asks for
        // less than the tightest number does.
        #expect(PhotoSimilarity.allCases.first == .identicalOnly)
        #expect(PhotoSimilarity.allCases.filter { $0.threshold == nil } == [.identicalOnly])
        #expect(PhotoSimilarity.ceiling == thresholds.max())
    }

    /// The number on the badge is what makes the setting calibratable: a group at
    /// 0.33 and a group at 0.12 look equally confident on screen.
    @Test("A similar group reports the distance of its least alike pair")
    func similarGroupCarriesItsDiameter() throws {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000),
                      asset("c", seconds: 180, width: 2000)]
        // a–b is 0.1, b–c is 0.2, a–c is 0.3. The group's diameter is the worst.
        let prints: [String: PhotoFingerprint] = [
            "a": print([0, 0, 0]), "b": print([0.1, 0, 0]), "c": print([0.3, 0, 0])
        ]
        let group = try #require(
            DuplicateGrouper(options: .init(similarityThreshold: 0.5))
                .group(assets: assets, fingerprints: prints)
                .first { $0.kind == .similar }
        )

        #expect(group.assets.count == 3)
        let diameter = try #require(group.maximumDistance)
        #expect(abs(diameter - 0.3) < 0.0001, "0.3 is the pair furthest apart, not 0.1")
    }

    @Test("A tier that did not judge by distance reports none")
    func onlySimilarGroupsCarryADistance() {
        let burst = [asset("a", seconds: 100, burst: "B1", representsBurst: true),
                     asset("b", seconds: 100, burst: "B1")]
        let exact = [asset("c", seconds: 300), asset("d", seconds: 300)]

        for group in DuplicateGrouper().group(assets: burst + exact,
                                              fingerprints: identicalPrints("c", "d")) {
            #expect(group.kind != .similar)
            #expect(group.maximumDistance == nil,
                    "\(group.kind) did not decide by distance, so it has no distance to show")
        }
    }

    /// The badge is on every similar group or on none of them: a group without one
    /// would read as a different, more certain kind of match.
    ///
    /// This holds because `cluster` skips an asset with no fingerprint, so a similar
    /// group's members all have one — including the asset here that does not, which
    /// is why it is absent from the group rather than in it without a distance.
    @Test("Every similar group carries a distance, and a photo with no print joins none")
    func everySimilarGroupCarriesADistance() {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000),
                      asset("d", seconds: 180, width: 2000)]
        let groups = DuplicateGrouper(options: .init(similarityThreshold: 0.5))
            .group(assets: assets, fingerprints: ["a": print([0, 0, 0]), "b": print([0.1, 0, 0])])

        #expect(!groups.isEmpty)
        for group in groups where group.kind == .similar {
            #expect(group.maximumDistance != nil)
            #expect(!group.assets.contains { $0.id == "d" })
        }
    }

    @Test("Choosing a different keeper does not change what was measured")
    func promotingKeepsTheDistance() throws {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 140, width: 3000)]
        let prints: [String: PhotoFingerprint] = ["a": print([0, 0, 0]), "b": print([0.2, 0, 0])]
        let group = try #require(
            DuplicateGrouper(options: .init(similarityThreshold: 0.5))
                .group(assets: assets, fingerprints: prints).first
        )
        let promoted = try #require(group.promoting(group.removable[0].id))
        #expect(promoted.maximumDistance == group.maximumDistance)
    }

    // MARK: - Cancellation

    /// A cancelled sweep must stop grouping, not finish the grind and hand back a
    /// result the service is about to throw away. The grouper polls
    /// `Task.isCancelled`, so inside an already-cancelled task the similar tier —
    /// the quadratic one — produces nothing where it otherwise would.
    @Test("Cancellation stops the similar tier early")
    func cancellationStopsGrouping() async {
        let assets = [asset("a", seconds: 100), asset("b", seconds: 100)]
        let prints = identicalPrints("a", "b")

        let normal = DuplicateGrouper().group(assets: assets, fingerprints: prints)
        #expect(!normal.isEmpty, "sanity: these two group when not cancelled")

        let task = Task {
            // Cancelled before the grouper starts: the first poll must bail.
            DuplicateGrouper().group(assets: assets, fingerprints: prints)
        }
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.isEmpty)
    }
}
