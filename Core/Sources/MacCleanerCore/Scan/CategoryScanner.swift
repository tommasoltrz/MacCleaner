import Foundation

/// Rules a scan must respect, supplied by settings and the exclusion list.
public struct ScanContext: Sendable {
    /// Measures every tree this scan sizes. Carries the protected globs, so a
    /// candidate holding one comes back flagged — see `isExcluded`.
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
        // The measurer must know the globs or nothing detects a protected tree.
        // Taking them from the same argument keeps the two halves of the rule from
        // drifting apart.
        var measurer = measurer
        if measurer.protectedPatterns.isEmpty { measurer.protectedPatterns = excludedPatterns }
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

    /// True when a path is excluded, protected by recency, inside an excluded
    /// folder — **or contains one**. Every scanner must consult this before emitting
    /// an entry.
    ///
    /// The ancestor rule matters as much as the descendant one: with
    /// `~/Documents/Project/Secrets` excluded, a row for `~/Documents/Project` would
    /// remove the secrets along with everything else. An exclusion protects its
    /// subtree from whichever row reaches it. Category roots are gated with
    /// ``isWithinExclusion(_:)`` instead, or one deep exclusion would switch off the
    /// whole category above it.
    public func isExcluded(_ url: URL, lastOpened: Date? = nil) -> Bool {
        let path = url.standardizedFileURL.path

        if isWithinExclusion(url) { return true }
        for excluded in excludedPaths where excluded.hasPrefix(path + "/") {
            return true
        }
        // Patterns protect the match itself and everything inside it — a path
        // component test, no attributes read, no walk.
        //
        // The other half of the rule, "a folder *containing* a match is not
        // removable", is not decided here: it needs to know what is inside, and a
        // recursive enumeration per candidate would double the cost of every scan.
        // `AllocatedSizeMeasurer` detects it during the walk the caller already
        // pays for and returns `SizeMeasurement.containsProtectedPattern`; every
        // scanner refuses to emit a flagged tree. That walk is also the one that
        // polls cancellation, which an enumeration here would not.
        if !excludedPatterns.isEmpty {
            for component in url.pathComponents {
                for pattern in excludedPatterns where fnmatch(pattern, component, 0) == 0 {
                    return true
                }
            }
        }
        if let lastOpened, protectRecentDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(protectRecentDays) * 86_400)
            if lastOpened > cutoff { return true }
        }
        return false
    }

    /// True when the path is an excluded folder or lies inside one. The narrow
    /// check for category roots: a root that merely *contains* an exclusion is
    /// still walked, and the exclusion is honoured row by row.
    public func isWithinExclusion(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
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
