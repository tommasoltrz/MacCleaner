import Foundation

/// The seven Scanner categories, in the order the design lists them.
public enum CategoryID: String, Sendable, CaseIterable, Identifiable {
    case documentsAndFiles
    case applications
    case hiddenSystemData
    case systemCaches
    case packageManagers
    case xcode
    case docker

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .documentsAndFiles: "Documents & Files"
        case .applications:      "Applications"
        case .hiddenSystemData:  "Hidden & System Data"
        case .systemCaches:      "System Caches & Logs"
        case .packageManagers:   "Package Manager Caches"
        case .xcode:             "Xcode & iOS Dev"
        case .docker:            "Docker"
        }
    }

    public var subtitle: String {
        switch self {
        case .documentsAndFiles:
            "Largest folders in Documents, Downloads, Desktop, Movies, Pictures, Music"
        case .applications:
            "Least recently used first. Includes leftover support files."
        case .hiddenSystemData:
            "Trash, iOS backups, Mail downloads, dot-caches, snapshots"
        case .systemCaches:
            "~/Library/Caches, ~/Library/Logs"
        case .packageManagers:
            "npm, Yarn, pip, Homebrew, CocoaPods, Gradle"
        case .xcode:
            "DerivedData, Device Support, Simulator caches"
        case .docker:
            "Docker images, containers and volumes"
        }
    }

    /// Rendered in monospace when the subtitle is a path list.
    public var subtitleIsPath: Bool { self == .systemCaches }

    public var color: ColorToken {
        switch self {
        case .documentsAndFiles: .orange
        case .applications:      .pink
        case .hiddenSystemData:  .purple
        case .systemCaches:      .accent
        case .packageManagers:   .green
        case .xcode:             .yellow
        case .docker:            .gray
        }
    }

    /// Contents regenerate on demand, so removal needs no human judgement. Drives
    /// the Dashboard's "Safe to remove" total and the green `safe` badge.
    public var isSafe: Bool {
        switch self {
        case .systemCaches, .packageManagers, .xcode: true
        case .documentsAndFiles, .applications, .hiddenSystemData, .docker: false
        }
    }

    /// Removal moves to the Trash rather than unlinking. Applications always do,
    /// regardless of the global "Always move to Trash" setting.
    public var alwaysMovesToTrash: Bool { self == .applications }
}

/// Why a category has nothing to offer. The reason is user-facing copy: the design
/// requires Docker's row to say how to fix it, which the predecessor's bare
/// "Docker is not running" did not.
public enum CategoryAvailability: Sendable, Equatable {
    case available
    /// Measured successfully and found nothing.
    case empty
    case unavailable(reason: String)

    public var isActionable: Bool { self == .available }
}

public struct ScanCategoryResult: Sendable, Equatable, Identifiable {
    public let categoryID: CategoryID
    public var totalBytes: Int64
    public var entries: [FileEntry]
    public var availability: CategoryAvailability
    /// Entries this scanner could not read, surfaced rather than swallowed.
    public var unreadableCount: Int

    public var id: String { categoryID.rawValue }

    public init(
        categoryID: CategoryID,
        totalBytes: Int64 = 0,
        entries: [FileEntry] = [],
        availability: CategoryAvailability = .available,
        unreadableCount: Int = 0
    ) {
        self.categoryID = categoryID
        self.totalBytes = totalBytes
        self.entries = entries
        self.availability = availability
        self.unreadableCount = unreadableCount
    }

    /// Drops entries too small to be worth a row, and recomputes the total.
    ///
    /// A cleaner offering to reclaim 200 KB wastes a line of the user's attention on
    /// something that will never matter. Removing them also keeps the byte formatter
    /// away from its degenerate case.
    ///
    /// Only entry-backed categories are filtered: Docker reports totals from its own
    /// accounting rather than from files on disk, so its rows are left alone.
    public func filteringNoise(below floor: Int64) -> Self {
        guard !entries.isEmpty else { return self }
        var copy = self
        copy.entries = entries.filter { $0.totalBytesIncludingChildren >= floor }
        copy.totalBytes = copy.entries.reduce(0) { $0 + $1.reclaimableBytes }
        // Everything it found was noise — that is "nothing worth cleaning", not a
        // category with an empty table.
        if copy.entries.isEmpty, availability == .available {
            copy.availability = .empty
        }
        return copy
    }

    /// A category that measured zero renders disabled, with no disclosure triangle.
    public static func empty(_ id: CategoryID) -> Self {
        ScanCategoryResult(categoryID: id, availability: .empty)
    }

    public static func unavailable(_ id: CategoryID, reason: String) -> Self {
        ScanCategoryResult(categoryID: id, availability: .unavailable(reason: reason))
    }
}
