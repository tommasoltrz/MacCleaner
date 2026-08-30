import Foundation

/// One measured child in the current Storage Explorer folder.
public struct StorageExplorerItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case file
        case folder
        case symbolicLink
        case package
        case application
        case volume
    }

    /// Why a row cannot be removed from here. Each names a different place to go:
    /// `library` is the Scanner's territory, `trash` the Trash view's, `application`
    /// the uninstaller's, `mediaLibrary` the owning app's. Ordinary document
    /// packages (Pages, Keynote, `.rtfd`) carry no reason — they are files.
    public enum ProtectionReason: String, Sendable, Equatable {
        case excluded
        case protectedContents
        case unreadableContents
        case system
        case library
        case trash
        case application
        case mediaLibrary
        case volume
        case cloudOnly
        case unavailable
    }

    public enum CloudState: String, Sendable, Equatable {
        case none
        case downloaded
        case cloudOnly
        case containsCloudOnlyItems
    }

    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var kind: Kind
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var unreadableCount: Int
    public var modificationDate: Date?
    public var identity: String?
    public var isHidden: Bool
    public var cloudState: CloudState
    public var protectionReason: ProtectionReason?

    public init(
        url: URL,
        name: String? = nil,
        kind: Kind,
        allocatedBytes: Int64,
        fileCount: Int = 0,
        unreadableCount: Int = 0,
        modificationDate: Date? = nil,
        identity: String? = nil,
        isHidden: Bool = false,
        cloudState: CloudState = .none,
        protectionReason: ProtectionReason? = nil
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
        self.modificationDate = modificationDate
        self.identity = identity
        self.isHidden = isHidden
        self.cloudState = cloudState
        self.protectionReason = protectionReason
    }

    public var opensAsDirectory: Bool {
        kind == .folder || kind == .volume
    }

    public var isRemovable: Bool {
        identity != nil && protectionReason == nil
    }
}

/// A fresh review of the rows selected for one Storage Explorer removal.
public struct StorageExplorerSelectionReview: Sendable, Equatable {
    public var snapshot: StorageExplorerSnapshot
    public var items: [StorageExplorerItem]
    public var changedPaths: [String]
    public var protectedPaths: [String]

    public init(
        snapshot: StorageExplorerSnapshot,
        items: [StorageExplorerItem],
        changedPaths: [String],
        protectedPaths: [String]
    ) {
        self.snapshot = snapshot
        self.items = items
        self.changedPaths = changedPaths
        self.protectedPaths = protectedPaths
    }

    public var isReady: Bool {
        !items.isEmpty && changedPaths.isEmpty && protectedPaths.isEmpty
    }
}

/// One complete level in the Storage Explorer hierarchy.
public struct StorageExplorerSnapshot: Sendable, Equatable {
    public var directory: URL
    public var items: [StorageExplorerItem]
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var unreadableCount: Int
    public var measuredAt: Date

    public init(
        directory: URL,
        items: [StorageExplorerItem],
        allocatedBytes: Int64,
        fileCount: Int,
        unreadableCount: Int,
        measuredAt: Date = Date()
    ) {
        self.directory = directory
        self.items = items
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
        self.measuredAt = measuredAt
    }
}

public enum StorageExplorerError: Error, Sendable, Equatable {
    case unavailable(String)
    case notDirectory(String)
}
