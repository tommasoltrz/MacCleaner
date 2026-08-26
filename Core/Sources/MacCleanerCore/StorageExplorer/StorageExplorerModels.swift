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

    public enum ProtectionReason: String, Sendable, Equatable {
        case excluded
        case protectedContents
        case unreadableContents
        case system
        case application
        case package
        case volume
        case unavailable
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
        self.protectionReason = protectionReason
    }

    public var opensAsDirectory: Bool {
        kind == .folder || kind == .volume
    }

    public var isRemovable: Bool {
        identity != nil && protectionReason == nil
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
