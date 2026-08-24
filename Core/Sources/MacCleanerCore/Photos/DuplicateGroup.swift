import Foundation

/// A set of assets judged to be the same picture, with one nominated to survive.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {

    /// How the group was formed. Surfaced in the UI because the tiers carry very
    /// different confidence, and a user deleting in bulk deserves to know which
    /// they are looking at.
    public enum Kind: String, Sendable, Equatable {
        /// Same `burstIdentifier` — Apple's own grouping. Certain.
        case burst
        /// Identical capture second, dimensions, media type and duration. Certain
        /// in practice: re-imports, AirDrop round-trips, "duplicate" in Photos.
        case exact
        /// Vision feature prints within the similarity threshold. A judgement call,
        /// which is why these are never pre-selected.
        case similar
    }

    /// Why `keeper` is the one being kept.
    ///
    /// Shown beside it in the grid. A bulk delete that cannot explain which copy it
    /// chose is asking for trust it has not earned — and the answer is rarely
    /// obvious from two thumbnails that look the same.
    public enum KeeperReason: String, Sendable, Equatable {
        case favorite, burstPick, edited, resolution, earliest, chosenByYou

        public var label: String {
            switch self {
            case .favorite:    "favourite"
            case .burstPick:   "your pick from the burst"
            case .edited:      "edited"
            case .resolution:  "highest resolution"
            case .earliest:    "the original"
            case .chosenByYou: "you chose this"
            }
        }
    }

    public let id: String
    public let kind: Kind
    /// The asset to keep. Always a member of `assets`.
    public let keeper: PhotoAsset
    public let keeperReason: KeeperReason
    /// Everything proposed for deletion. Never contains `keeper`, and never contains
    /// a favourite.
    public let removable: [PhotoAsset]

    public init(
        id: String,
        kind: Kind,
        keeper: PhotoAsset,
        keeperReason: KeeperReason = .earliest,
        removable: [PhotoAsset]
    ) {
        self.id = id
        self.kind = kind
        self.keeper = keeper
        self.keeperReason = keeperReason
        self.removable = removable
    }

    /// Re-nominates `assetID` as the one to keep, demoting the current keeper.
    ///
    /// The automatic choice is a heuristic, and the person looking at the photographs
    /// is a better judge than a pixel count — so nothing about the original nomination
    /// is privileged. The demoted keeper becomes removable like any other copy.
    ///
    /// Returns nil when `assetID` is not in this group, or is already the keeper.
    public func promoting(_ assetID: String) -> DuplicateGroup? {
        guard assetID != keeper.id,
              let promoted = removable.first(where: { $0.id == assetID })
        else { return nil }

        // Keeps the grid's order stable: the demoted keeper takes the promoted
        // photo's slot rather than jumping to the front.
        let demoted = removable.map { $0.id == assetID ? keeper : $0 }

        return DuplicateGroup(
            id: id, kind: kind, keeper: promoted, keeperReason: .chosenByYou, removable: demoted
        )
    }

    /// Every member, keeper first — the order the grid renders.
    public var assets: [PhotoAsset] { [keeper] + removable }

    public var count: Int { removable.count + 1 }

    /// Groups form only where something can actually be removed. A "duplicate set"
    /// with nothing to delete is a row that costs attention and returns nothing.
    public var isActionable: Bool { !removable.isEmpty }
}

/// The finished sweep.
public struct PhotoDuplicateResults: Sendable, Equatable {
    public var groups: [DuplicateGroup]
    /// Assets examined, after hidden items were dropped.
    public var examinedCount: Int
    /// Assets whose thumbnail could not be read without going to the network, so
    /// they were never fingerprinted. Reported rather than swallowed — the same rule
    /// the scanners follow with `unreadableCount`.
    public var skippedCount: Int
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        groups: [DuplicateGroup] = [],
        examinedCount: Int = 0,
        skippedCount: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.groups = groups
        self.examinedCount = examinedCount
        self.skippedCount = skippedCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Total assets proposed for deletion across every group.
    public var removableCount: Int { groups.reduce(0) { $0 + $1.removable.count } }

    public func groups(ofKind kind: DuplicateGroup.Kind) -> [DuplicateGroup] {
        groups.filter { $0.kind == kind }
    }
}
