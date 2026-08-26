import Foundation

/// One file in a content-verified duplicate set.
public struct DuplicateFile: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
    let plannedIdentity: String?

    public init(
        url: URL,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.url = url.standardizedFileURL
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.plannedIdentity = FileIdentity.of(url)
    }
}

/// Files that matched by size, sampled hash, full hash, and byte comparison.
public struct FileDuplicateGroup: Sendable, Equatable, Identifiable {
    public enum KeeperReason: String, Sendable, Equatable {
        case oldestCopy
        case chosenByUser

        public var label: String {
            switch self {
            case .oldestCopy:   "oldest copy"
            case .chosenByUser: "you chose this"
            }
        }
    }

    public let id: String
    public let keeper: DuplicateFile
    public let keeperReason: KeeperReason
    public let removable: [DuplicateFile]
    let contentDigest: String

    init(
        id: String,
        keeper: DuplicateFile,
        keeperReason: KeeperReason = .oldestCopy,
        removable: [DuplicateFile],
        contentDigest: String
    ) {
        self.id = id
        self.keeper = keeper
        self.keeperReason = keeperReason
        self.removable = removable
        self.contentDigest = contentDigest
    }

    public var files: [DuplicateFile] { [keeper] + removable }
    public var count: Int { removable.count + 1 }

    /// The best available upper bound on space recovered by removing every copy.
    public var reclaimableBytes: Int64 {
        removable.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// Keeps another member and makes the former keeper removable.
    public func promoting(_ fileID: DuplicateFile.ID) -> FileDuplicateGroup? {
        guard fileID != keeper.id,
              let promoted = removable.first(where: { $0.id == fileID })
        else { return nil }

        let demoted = removable.map { $0.id == fileID ? keeper : $0 }
        return FileDuplicateGroup(
            id: id,
            keeper: promoted,
            keeperReason: .chosenByUser,
            removable: demoted,
            contentDigest: contentDigest
        )
    }

    /// Removes copies that left the disk. A group with no removable copy disappears.
    public func removingFiles(withIDs fileIDs: Set<DuplicateFile.ID>) -> FileDuplicateGroup? {
        let remaining = removable.filter { !fileIDs.contains($0.id) }
        guard !remaining.isEmpty else { return nil }
        return FileDuplicateGroup(
            id: id,
            keeper: keeper,
            keeperReason: keeperReason,
            removable: remaining,
            contentDigest: contentDigest
        )
    }
}

/// The result of one selected-folder duplicate scan.
public struct FileDuplicateResults: Sendable, Equatable {
    public var groups: [FileDuplicateGroup]
    public let roots: [URL]
    public let examinedCount: Int
    public let eligibleCount: Int
    public let skippedCount: Int
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        groups: [FileDuplicateGroup] = [],
        roots: [URL] = [],
        examinedCount: Int = 0,
        eligibleCount: Int = 0,
        skippedCount: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.groups = groups
        self.roots = roots
        self.examinedCount = examinedCount
        self.eligibleCount = eligibleCount
        self.skippedCount = skippedCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var removableCount: Int {
        groups.reduce(0) { $0 + $1.removable.count }
    }

    public var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

/// The removal result and any scan data that became stale before removal.
public struct FileDuplicateRemovalOutcome: Sendable, Equatable {
    public let cleanup: CleanupOutcome
    public let staleFileIDs: Set<DuplicateFile.ID>
    public let staleGroupIDs: Set<FileDuplicateGroup.ID>

    init(
        cleanup: CleanupOutcome,
        staleFileIDs: Set<DuplicateFile.ID> = [],
        staleGroupIDs: Set<FileDuplicateGroup.ID> = []
    ) {
        self.cleanup = cleanup
        self.staleFileIDs = staleFileIDs
        self.staleGroupIDs = staleGroupIDs
    }
}
