import Foundation

/// The Scanner categories, in their display order.
public enum CategoryID: String, Sendable, CaseIterable, Identifiable {
    case documentsAndFiles
    case applications
    case applicationLeftovers
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
        case .applicationLeftovers: "Application Leftovers"
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
            "Apps in /Applications and ~/Applications. Least recently used first."
        case .applicationLeftovers:
            "Files with no installed application owner"
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
        case .applicationLeftovers: .teal
        case .hiddenSystemData:  .purple
        case .systemCaches:      .accent
        case .packageManagers:   .green
        case .xcode:             .yellow
        case .docker:            .gray
        }
    }

    /// Removal has a verified low-risk rule. Cache contents regenerate on demand.
    /// Application leftovers have no installed owner. This value drives the
    /// Dashboard's "Safe to Remove" total and the green `safe` badge.
    public var isSafe: Bool {
        switch self {
        case .applicationLeftovers, .systemCaches, .packageManagers, .xcode: true
        case .documentsAndFiles, .applications, .hiddenSystemData, .docker: false
        }
    }

    /// Removal moves to the Trash rather than unlinking. Applications always do,
    /// regardless of the global "Always move to Trash" setting.
    public var alwaysMovesToTrash: Bool {
        self == .applications || self == .applicationLeftovers
    }
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
    /// The reviewed identities behind the Application Leftovers rows.
    public var applicationLeftoverPlan: OrphanedAppLeftoverPlan?

    public var id: String { categoryID.rawValue }

    /// The space used by installed app bundles. The cleanup total can be lower when
    /// an app is running, or higher when related files are removable with the app.
    public var applicationInstalledBytes: Int64? {
        guard categoryID == .applications else { return nil }
        return entries.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// This category's contribution to "Safe to Remove". It counts regenerable
    /// rows and verified application-leftover groups. A safe cache category can
    /// hold data that does not regenerate, such as an `.xcarchive`. Therefore,
    /// each ordinary row must pass the regenerable check.
    public var safeToRemoveBytes: Int64 {
        guard categoryID.isSafe else { return 0 }
        if categoryID == .applicationLeftovers {
            return entries.reduce(0) { $0 + $1.displayBytes }
        }
        return entries.filter(\.isRegenerable).reduce(0) { $0 + $1.displayBytes }
    }

    /// Everything else: each category without a safe badge, plus each
    /// non-regenerable entry in a safe category.
    /// Summed from the rows the list will show, never from `totalBytes`: the tile
    /// and the list it opens must state the same figure. A category with no entries
    /// keeps its own total — that is a scanner reporting an aggregate it did not
    /// break into rows.
    public var needsReviewBytes: Int64 {
        if categoryID == .applicationLeftovers { return 0 }
        guard !entries.isEmpty else { return categoryID.isSafe ? 0 : totalBytes }
        guard categoryID.isSafe else { return entries.reduce(0) { $0 + $1.displayBytes } }
        return entries.filter { !$0.isRegenerable }.reduce(0) { $0 + $1.displayBytes }
    }

    public init(
        categoryID: CategoryID,
        totalBytes: Int64 = 0,
        entries: [FileEntry] = [],
        availability: CategoryAvailability = .available,
        unreadableCount: Int = 0,
        applicationLeftoverPlan: OrphanedAppLeftoverPlan? = nil
    ) {
        self.categoryID = categoryID
        self.totalBytes = totalBytes
        self.entries = entries
        self.availability = availability
        self.unreadableCount = unreadableCount
        self.applicationLeftoverPlan = applicationLeftoverPlan
    }

    /// Drops entries too small to be worth a row, and recomputes the total.
    ///
    /// A cleaner offering to reclaim 200 KB wastes a line of the user's attention on
    /// something that will never matter. Removing them also keeps the byte formatter
    /// away from its degenerate case.
    ///
    /// This filter applies only to entry-backed categories. Docker reports totals
    /// from its own accounting, so the filter leaves Docker rows intact.
    public func filteringNoise(below floor: Int64) -> Self {
        // Docker's rows are manual-removal aggregates: `reclaimableBytes` is zero
        // by definition, so recomputing the total from it would erase the `system
        // df` figure the category exists to show.
        guard categoryID != .docker,
              categoryID != .applicationLeftovers,
              !entries.isEmpty
        else { return self }
        var copy = self
        copy.entries = entries.filter { $0.totalBytesIncludingChildren >= floor }
        copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
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
