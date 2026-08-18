import Foundation

/// Rules a scan must respect, supplied by settings and the exclusion list.
public struct ScanContext: Sendable {
    public var measurer: AllocatedSizeMeasurer
    /// Absolute paths skipped entirely, from Preferences → Exclusions.
    public var excludedPaths: [String]
    /// Glob rules such as `*.sparsebundle`.
    public var excludedPatterns: [String]
    /// "Protect files opened in the last N days" — recently used files never appear
    /// as removal candidates.
    public var protectRecentDays: Int
    /// Bundle paths of applications currently running, supplied by the app layer
    /// (NSWorkspace is AppKit, which Core deliberately does not import). Unlike any
    /// date heuristic this is ground truth: a running app is in use, full stop.
    public var runningApplicationPaths: Set<String>

    public init(
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer(),
        excludedPaths: [String] = [],
        excludedPatterns: [String] = [],
        protectRecentDays: Int = 30,
        runningApplicationPaths: Set<String> = []
    ) {
        self.measurer = measurer
        self.excludedPaths = excludedPaths
        self.excludedPatterns = excludedPatterns
        self.protectRecentDays = protectRecentDays
        self.runningApplicationPaths = runningApplicationPaths
    }

    /// The recency half of the shield on its own, for scanners that separate
    /// "protect" from "hide".
    public func isRecencyProtected(_ lastOpened: Date?) -> Bool {
        guard let lastOpened, protectRecentDays > 0 else { return false }
        return lastOpened > Date().addingTimeInterval(-Double(protectRecentDays) * 86_400)
    }

    /// True when a path is excluded, protected by recency, or inside an excluded
    /// folder. Every scanner must consult this before emitting an entry.
    public func isExcluded(_ url: URL, lastOpened: Date? = nil) -> Bool {
        let path = url.standardizedFileURL.path

        for excluded in excludedPaths {
            if path == excluded || path.hasPrefix(excluded + "/") { return true }
        }
        let name = url.lastPathComponent
        for pattern in excludedPatterns {
            if fnmatch(pattern, name, 0) == 0 { return true }
        }
        if let lastOpened, protectRecentDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(protectRecentDays) * 86_400)
            if lastOpened > cutoff { return true }
        }
        return false
    }
}

/// One Scanner category.
///
/// Implementations must:
/// * measure **only** through `context.measurer` — never shell out to `du`;
/// * consult `context.isExcluded(_:lastOpened:)` before emitting an entry;
/// * report `.unavailable(reason:)` with copy that tells the user how to fix it,
///   rather than failing silently;
/// * propagate `CancellationError` so the toolbar's stop button works.
public protocol CategoryScanner: Sendable {
    var id: CategoryID { get }
    func scan(context: ScanContext) async throws -> ScanCategoryResult
}

public extension CategoryScanner {
    /// Best-known activity date for the design's **Last opened** column.
    ///
    /// `kMDItemLastUsedDate` is the ideal answer but is unavailable in practice: on
    /// macOS 26 it reads `null` for essentially everything — folders, plain files,
    /// and even applications the user launches daily. Trusting it alone made every
    /// single row render the orange **Never opened** treatment, which the design
    /// defines as "the strongest signal that a file is safe to remove". An app that
    /// flags the user's active project as safe to delete is worse than useless, so
    /// the value falls back through progressively weaker signals.
    ///
    /// `nil` is therefore reserved for genuinely unknown, which keeps **Never
    /// opened** rare and meaningful — the property the design is relying on.
    ///
    /// Note the honest caveat: below the first branch this is *last modified*, not
    /// *last opened*. It is the closest signal macOS still exposes without Full Disk
    /// Access, and it errs toward keeping files rather than deleting them.
    func lastOpenedDate(for url: URL) -> Date? {
        if let item = MDItemCreate(nil, url.path as CFString) {
            if let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                return used
            }
            if let modified = MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date {
                return modified
            }
        }
        // Spotlight may not have indexed the volume at all.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.contentModificationDate ?? values.creationDate
    }

    /// Convenience: build an entry, measuring it through the shared measurer.
    func makeEntry(
        url: URL,
        kind: FileEntry.Kind,
        context: ScanContext,
        isRegenerable: Bool = false
    ) async throws -> FileEntry? {
        let lastOpened = lastOpenedDate(for: url)
        guard !context.isExcluded(url, lastOpened: lastOpened) else { return nil }

        let measured = try await context.measurer.measure(url)
        guard measured.allocatedBytes > 0 else { return nil }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let childCount = isDirectory
            ? (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
            : nil

        return FileEntry(
            url: url,
            kind: kind,
            allocatedBytes: measured.allocatedBytes,
            lastOpened: lastOpened,
            isRegenerable: isRegenerable,
            childCount: childCount
        )
    }
}
