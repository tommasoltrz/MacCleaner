import Foundation
import Testing
@testable import ScoloCore

/// The graph and the arithmetic must produce the same groups.
///
/// The graph exists so that changing the similarity setting costs nothing: every
/// pair close enough to matter at any setting is found once, and each setting is a
/// filter over that list. The whole idea rests on the two being the same answer —
/// and the moment they are not, the fast path is proposing to delete photographs
/// the slow path would have kept. So this compares them directly, over a library
/// built to contain every case the tiers care about, at every threshold the picker
/// offers.
@Suite("Grouping from the graph equals grouping from the prints")
struct PhotoGraphGroupingTests {

    private func asset(
        _ id: String,
        seconds: TimeInterval,
        width: Int = 4032,
        media: PhotoAsset.MediaType = .image,
        burst: String? = nil,
        favorite: Bool = false,
        hidden: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            filename: "\(id).heic",
            creationDate: Date(timeIntervalSince1970: seconds),
            pixelWidth: width,
            pixelHeight: 3024,
            mediaType: media,
            duration: media == .video ? 12 : 0,
            burstIdentifier: burst,
            representsBurst: burst != nil && id.hasSuffix("0"),
            isFavorite: favorite,
            isHidden: hidden,
            hasAdjustments: false
        )
    }

    /// A library holding every case the tiers care about, built case by case.
    ///
    /// Deterministic, so a failure is reproducible rather than something that
    /// happened once on a Tuesday. Built explicitly rather than by scattering
    /// modulo rules over one loop: the first attempt did that, and produced a
    /// library with no similar families in a shared bucket, no burst with two
    /// frames in it, and no exact match at all — three of the tiers this suite
    /// claims to compare were never running. The assertions at the end of each
    /// test are what caught it, and they stay for the next person.
    private func library(families: Int = 40) -> ([PhotoAsset], [String: PhotoFingerprint]) {
        var state: UInt64 = 0x5E12
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        func vector(_ dimensions: Int = 24) -> [Float] {
            (0..<dimensions).map { _ in next() * 0.4 }
        }

        var assets: [PhotoAsset] = []
        var prints: [String: PhotoFingerprint] = [:]
        var index = 0
        func add(_ asset: PhotoAsset, _ print: [Float]?) {
            assets.append(asset)
            if let print { prints[asset.id] = PhotoFingerprint(vector: print) }
        }
        func id() -> String { defer { index += 1 }; return String(format: "asset-%04d", index) }

        for family in 0..<families {
            // Every family shares a capture day. Members on different days are in
            // different buckets and are never compared, whatever the threshold.
            let day = TimeInterval(family % 5) * 86_400
            let base = day + TimeInterval(family)

            // Three pictures of the same thing, moments apart: the similar tier.
            let seed = vector()
            add(asset(id(), seconds: base), seed)
            add(asset(id(), seconds: base + 30, width: 3000), seed.map { $0 + next() * 0.06 })
            add(asset(id(), seconds: base + 60), seed.map { $0 + next() * 0.06 })

            // Something unrelated, so the clustering has to reject as well as accept.
            add(asset(id(), seconds: base + 90), vector())

            switch family % 5 {
            case 0:
                // Two frames of one burst, which needs no pixels at all.
                let burst = "burst-\(family)"
                add(asset(id() + "0", seconds: base + 120, burst: burst), vector())
                add(asset(id(), seconds: base + 121, burst: burst), vector())
            case 1:
                // A re-import: same capture second, same dimensions, and prints that
                // agree well inside the exact tier's 0.05.
                let original = vector()
                let second = base + 150
                add(asset(id(), seconds: second), original)
                add(asset(id(), seconds: second), original.map { $0 + next() * 0.0004 })
            case 2:
                // A favourite among near-identical copies: never a casualty.
                let seed = vector()
                add(asset(id(), seconds: base + 180, favorite: true), seed)
                add(asset(id(), seconds: base + 200), seed.map { $0 + next() * 0.06 })
            case 3:
                // Hidden, and a photograph that was never fingerprinted.
                add(asset(id(), seconds: base + 220, hidden: true), vector())
                add(asset(id(), seconds: base + 240), nil)
            default:
                // Two videos that fingerprint alike, which must never be grouped.
                let frame = vector()
                add(asset(id(), seconds: base + 260, media: .video), frame)
                add(asset(id(), seconds: base + 280, media: .video), frame.map { $0 + next() * 0.001 })
            }
        }
        // The case the capture-time bucket exists for: two shots that look the
        // same, taken a fortnight apart. They are the same subject photographed
        // twice, not duplicates of each other, and nothing may group them.
        // Without this pair in the library, removing the bucketing rule altogether
        // changed no result — every other alike pair already shared a day.
        let sameSubject = vector()
        add(asset(id(), seconds: 0), sameSubject)
        add(asset(id(), seconds: 14 * 86_400), sameSubject.map { $0 + next() * 0.002 })

        return (assets, prints)
    }

    private func describe(_ groups: [DuplicateGroup]) -> [String] {
        groups.map { group in
            let members = group.assets.map(\.id).sorted().joined(separator: ",")
            let distance = group.maximumDistance.map { String(format: "%.6f", $0) } ?? "-"
            return "\(group.kind.rawValue)|\(group.keeper.id)|\(group.keeperReason.rawValue)"
                + "|\(members)|\(distance)"
        }
    }

    @Test("Every setting produces the same groups from the graph as from the prints")
    func graphMatchesPrintsAtEverySetting() throws {
        let (assets, prints) = library(families: 40)
        let ceiling = PhotoSimilarity.allCases.map(\.threshold).max()!
        let graph = PhotoNeighbourGraph.build(
            assets: assets, fingerprints: prints, bucketInterval: 86_400, ceiling: ceiling
        )

        var sawSimilar = false
        var sawCertain = false
        for similarity in PhotoSimilarity.allCases {
            let options = DuplicateGrouper.Options(similarityThreshold: similarity.threshold)
            let grouper = DuplicateGrouper(options: options)

            let fromPrints = grouper.group(assets: assets, fingerprints: prints)
            let fromGraph = try #require(
                grouper.group(assets: assets, graph: graph),
                "the graph's ceiling covers every setting the picker offers"
            )

            #expect(describe(fromGraph) == describe(fromPrints),
                    "\(similarity.title) disagrees: the graph would delete a different set")
            if fromPrints.contains(where: { $0.kind == .similar }) { sawSimilar = true }
            if fromPrints.contains(where: { $0.kind != .similar }) { sawCertain = true }
        }
        // Without these the suite would pass over a library that groups nothing by
        // the very tier the graph exists for.
        #expect(sawSimilar, "no similar group formed: the tier the graph serves was never run")
        #expect(sawCertain, "no burst or exact group formed: those tiers read the graph too")
    }

    /// The graph holds every pair within its ceiling and nothing beyond it. Asked
    /// about a looser threshold it would answer "no" for pairs it never examined,
    /// which is not "no" — it is "not asked" — and real duplicates would silently
    /// vanish from the grid.
    @Test("A threshold beyond the graph's ceiling is refused, not answered")
    func aThresholdBeyondTheCeilingIsRefused() {
        let (assets, prints) = library(families: 6)
        let graph = PhotoNeighbourGraph.build(
            assets: assets, fingerprints: prints, bucketInterval: 86_400, ceiling: 0.3
        )

        #expect(DuplicateGrouper(options: .init(similarityThreshold: 0.3))
            .group(assets: assets, graph: graph) != nil)
        #expect(DuplicateGrouper(options: .init(similarityThreshold: 0.31))
            .group(assets: assets, graph: graph) == nil)
        // The exact tier reads the same graph, so its threshold is bound by the
        // ceiling too — and it is the tier that claims certainty.
        #expect(DuplicateGrouper(options: .init(similarityThreshold: 0.1, exactThreshold: 0.9))
            .group(assets: assets, graph: graph) == nil)
    }

    @Test("The graph holds exactly the pairs within its ceiling, and their distances")
    func theGraphIsExact() {
        let (assets, prints) = library(families: 15)
        let ceiling: Float = 0.35
        let graph = PhotoNeighbourGraph.build(
            assets: assets, fingerprints: prints, bucketInterval: 86_400, ceiling: ceiling
        )

        var expected = 0
        let visible = assets.filter { !$0.isHidden && $0.mediaType == .image }
        for i in visible.indices {
            for j in visible.indices where j > i {
                let (a, b) = (visible[i], visible[j])
                // Same bucket only: the graph compares within a capture day, as the
                // grouping always has.
                let bucket: (PhotoAsset) -> Int64 = {
                    Int64(($0.creationDate?.timeIntervalSince1970 ?? 0) / 86_400)
                }
                guard bucket(a) == bucket(b),
                      let left = prints[a.id], let right = prints[b.id] else { continue }
                guard let distance = left.distance(to: right), distance <= ceiling else {
                    #expect(graph.distance(a.id, b.id) == nil,
                            "\(a.id)–\(b.id) is beyond the ceiling and should not be an edge")
                    continue
                }
                expected += 1
                #expect(graph.distance(a.id, b.id) == distance)
                #expect(graph.isWithin(ceiling, a.id, b.id))
            }
        }
        #expect(graph.edgeCount == expected)
        #expect(expected > 0, "a graph with no edges would prove nothing")
    }

    /// An asset with no fingerprint was never compared with anything. That is not
    /// the same as an asset compared and found to match nothing, and the graph has
    /// to carry the distinction or the tiers that need pixels would group it.
    @Test("An unfingerprinted photo is absent from the graph's comparable set")
    func unfingerprintedPhotosAreNotComparable() {
        let (assets, prints) = library(families: 10)
        let graph = PhotoNeighbourGraph.build(
            assets: assets, fingerprints: prints, bucketInterval: 86_400, ceiling: 0.55
        )
        let missing = assets.filter { prints[$0.id] == nil }
        #expect(!missing.isEmpty, "the fixture must contain the case")
        for asset in missing {
            #expect(!graph.fingerprinted.contains(asset.id))
            #expect(graph.distance(asset.id, assets[0].id) == nil)
        }
    }
}
