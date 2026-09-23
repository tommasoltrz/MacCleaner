import Foundation

/// The Scanner categories, in their display order.
public enum CategoryID: String, Sendable, CaseIterable, Identifiable {
    case documentsAndFiles
    case applications
    case applicationLeftovers
    case aiTools
    case sharedData
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
        case .aiTools: "AI Tools"
        case .sharedData: "Shared Data"
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
        case .aiTools:
            "Verified caches and protected session and worktree storage"
        case .sharedData:
            "Files in /Users/Shared. Review their contents and application owners."
        case .hiddenSystemData:
            "iOS backups, Mail downloads, hidden folders, large disk images"
        case .systemCaches:
            "~/Library/Caches, ~/Library/Logs, ~/.cache, Apple's own apps"
        case .packageManagers:
            "npm, pnpm, pip, Homebrew, Cargo, CocoaPods, Gradle and more"
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
        case .aiTools: .teal
        case .sharedData: .gray
        case .hiddenSystemData:  .purple
        case .systemCaches:      .accent
        case .packageManagers:   .green
        case .xcode:             .yellow
        case .docker:            .gray
        }
    }

    /// Identifies categories that can contribute rows to Safe to Remove.
    /// Verified leftovers qualify through their removal action. Ordinary rows must regenerate safely.
    public var isSafe: Bool {
        switch self {
        case .systemCaches, .packageManagers, .xcode, .aiTools, .applicationLeftovers: true
        case .documentsAndFiles, .applications,
             .hiddenSystemData, .docker, .sharedData: false
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
    /// rows, verified application-leftover groups, and the regenerable children of
    /// rows that are not themselves safe. A safe cache category can hold data that
    /// does not regenerate, such as an `.xcarchive`. Therefore, each ordinary row
    /// must pass the regenerable check.
    ///
    /// The children matter because of applications. Chrome's caches are children of
    /// the Chrome row, the Applications category is not safe, and every row in it is
    /// an app bundle — so before this the tile could not see a single one of them,
    /// though the Scanner badged them `regenerable` one screen away. On the author's
    /// Mac that was 1.37 GB in Chrome alone.
    public var safeToRemoveBytes: Int64 {
        tileRows(safeToRemove: true).reduce(0) { $0 + $1.displayBytes }
    }

    /// The rows behind one tile — and the definition of what that tile counts, since
    /// both totals are sums over exactly these.
    ///
    /// It lives here, beside the figures, because it used to live in the app while
    /// the figures lived in Core. The two were written to agree and did, until a
    /// build took one of them and not the other: the tile then read 10.24 GB over a
    /// list of 13 rows worth 1.61 GB. Neither number was wrong for the code that
    /// produced it, which is the whole problem with keeping one claim in two places.
    ///
    /// A row that is not safe can still carry children that are. An application is
    /// the case this exists for: Chrome is not safe to remove and its caches are, so
    /// the caches come back as rows of their own and the row this returns for "needs
    /// review" is Chrome *without* them. Trimming rather than repeating is what keeps
    /// the two lists from claiming the same bytes twice.
    ///
    /// The Scanner does not use this. There an application keeps every child it has,
    /// because that view is about one application rather than about a total.
    public func tileRows(safeToRemove wantSafe: Bool) -> [FileEntry] {
        entries.flatMap { entry -> [FileEntry] in
            if countsAsSafe(entry) { return wantSafe ? [entry] : [] }
            // A leftover group or a model is one thing, removed through its own row —
            // a leftover's route checks the owner and each file's identity again.
            // A cache lifted out of it would be removed the ordinary way, unchecked.
            if entry.removalAction != nil || entry.removesAsUnit { return wantSafe ? [] : [entry] }

            let safeChildren = entry.children.filter(Self.isSafeChild)
            if wantSafe { return safeChildren }
            guard !safeChildren.isEmpty else { return [entry] }

            var remainder = entry
            remainder.children = entry.children.filter { !Self.isSafeChild($0) }
            // A locked row whose only removable content was those children is worth
            // nothing here. It counts zero towards the tile, so the list the tile
            // opens should not show it either.
            return remainder.displayBytes > 0 ? [remainder] : []
        }
    }

    /// This category as one of the Scanner's tabs shows it: the same category, holding
    /// only the rows that tab counts.
    ///
    /// The Scanner's three tabs are one outline. "Safe to Remove" and "Needs Review"
    /// used to be a flat list with the categories thrown away, which answered "what
    /// can I act on" and lost "where is it" — the first thing anybody asks of a row
    /// called `com.apple.helpd`. The rows are `tileRows`, so a category's figure
    /// under a tab is exactly that tab's share of the tile, and the two filtered
    /// copies of a category are the category, once.
    public func filtered(safeToRemove wantSafe: Bool) -> ScanCategoryResult {
        var copy = self
        copy.entries = tileRows(safeToRemove: wantSafe)
        copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
        copy.holdsOnlySafeRows = wantSafe
        if copy.entries.isEmpty, availability == .available { copy.availability = .empty }
        return copy
    }

    /// Set on the copy `filtered(safeToRemove: true)` returns. Its rows are safe by
    /// construction, and one of them can be a cache lifted out of an application,
    /// whose category is not a safe one — so the category cannot answer for it.
    public private(set) var holdsOnlySafeRows = false

    /// Whether a top-level row of this category is counted under Safe to remove,
    /// which is what its green badge says. A child's badge asks
    /// `FileEntry.regeneratesSafely`.
    public func isCountedSafe(_ entry: FileEntry) -> Bool {
        holdsOnlySafeRows || countsAsSafe(entry)
    }

    /// A child the parent's own row does not speak for — see
    /// `FileEntry.regeneratesSafely`, which the Scanner's badge reads too.
    private static func isSafeChild(_ child: FileEntry) -> Bool {
        child.regeneratesSafely
    }

    /// Whether the row itself — not merely something inside it — is safe to remove.
    ///
    /// A row held open by a running application is not: it lands in Needs Review,
    /// which is also what keeps it out of the pre-ticked selection, since that is
    /// seeded from the safe list. See `FileEntry.inUseBy`.
    private func countsAsSafe(_ entry: FileEntry) -> Bool {
        guard entry.inUseBy == nil, !entry.isRemovalLocked else { return false }
        if categoryID == .applicationLeftovers {
            return entry.orphanedApplicationBundleIdentifier != nil
        }
        return categoryID.isSafe && entry.regeneratesSafely
    }

    /// Everything else: each category without a safe badge, plus each
    /// non-regenerable entry in a safe category.
    /// Summed from the rows the list will show, never from `totalBytes`: the tile
    /// and the list it opens must state the same figure. A category with no entries
    /// keeps its own total — that is a scanner reporting an aggregate it did not
    /// break into rows.
    /// The two tiles are a partition, so whatever `safeToRemoveBytes` claims from a
    /// row is subtracted here. An application keeps its bundle and its user data in
    /// this figure and loses its caches to the other one; before, it kept both and
    /// the caches were counted nowhere else.
    public var needsReviewBytes: Int64 {
        // A category with no rows keeps its own total: that is a scanner reporting an
        // aggregate it never broke into rows, Docker being the one that does it.
        guard !entries.isEmpty else { return categoryID.isSafe ? 0 : totalBytes }
        return tileRows(safeToRemove: false).reduce(0) { $0 + $1.displayBytes }
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
