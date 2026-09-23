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
    /// Bundle paths of applications currently running, supplied by the app layer
    /// (NSWorkspace is AppKit, which Core deliberately does not import). Unlike any
    /// date heuristic this is ground truth: a running app is in use, full stop.
    public var runningApplicationPaths: Set<String>
    /// The same ground truth with names attached, so a cache can say *whose* it is.
    /// Every bundle path here is also in `runningApplicationPaths`.
    public var runningApplications: [FileEntry.RunningOwner]
    /// Application owners that Launch Services currently resolves.
    public var registeredApplicationBundleIdentifiers: Set<String>
    /// The candidate scan those owners were resolved from. Handed through so the
    /// leftover planner examines exactly the identifiers that were resolved,
    /// rather than scanning again and possibly meeting a new one the resolution
    /// never saw.
    public var applicationLeftoverCandidates: OrphanedAppLeftoverPlanner.CandidateScan?

    public init(
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer(),
        excludedPaths: [String] = [],
        excludedPatterns: [String] = [],
        runningApplicationPaths: Set<String> = [],
        runningApplications: [FileEntry.RunningOwner] = [],
        registeredApplicationBundleIdentifiers: Set<String> = [],
        applicationLeftoverCandidates: OrphanedAppLeftoverPlanner.CandidateScan? = nil
    ) {
        // The measurer must know the globs or nothing detects a protected tree.
        // Taking them from the same argument keeps the two halves of the rule from
        // drifting apart.
        var measurer = measurer
        if measurer.protectedPatterns.isEmpty { measurer.protectedPatterns = excludedPatterns }
        self.measurer = measurer
        self.excludedPaths = excludedPaths
        self.excludedPatterns = excludedPatterns
        self.runningApplicationPaths = runningApplicationPaths
            .union(runningApplications.map(\.bundlePath))
        self.runningApplications = runningApplications
        self.registeredApplicationBundleIdentifiers = registeredApplicationBundleIdentifiers
        self.applicationLeftoverCandidates = applicationLeftoverCandidates
    }

    /// The running application at this bundle path, if there is one.
    public func runningOwner(atBundlePath path: String) -> FileEntry.RunningOwner? {
        runningApplications.first { $0.bundlePath == path }
    }

    /// The running application with this bundle identifier, if there is one.
    public func runningOwner(bundleIdentifier: String) -> FileEntry.RunningOwner? {
        runningApplications.first {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    /// The first running application whose identifier begins with `prefix`, for a
    /// vendor that puts the year in it: `com.adobe.PremierePro.24`.
    public func runningOwner(bundleIdentifierPrefix prefix: String) -> FileEntry.RunningOwner? {
        let prefix = prefix.lowercased()
        return runningApplications.first { $0.bundleIdentifier?.lowercased().hasPrefix(prefix) == true }
    }

    /// The running application a folder in `~/Library/Caches` or `~/Library/Logs`
    /// belongs to, judged by the folder's name.
    ///
    /// Three shapes were seen on this Mac: the bundle identifier
    /// (`com.apple.dt.Xcode`), the identifier with a helper suffix
    /// (`com.spotify.client.helper`), and the app's own name (`Firefox`). Vendor
    /// folders (`Google`, which holds Chrome's) match nothing by name, so the
    /// identifier's vendor component is tried last: `com.google.Chrome` owns
    /// `Google`. That last rule can over-claim — a second Google app would be blamed
    /// on a running Chrome — and the cost of over-claiming is a row in Needs Review
    /// instead of Safe to Remove, which is the direction to be wrong in.
    public func runningOwner(ofCacheNamed folderName: String) -> FileEntry.RunningOwner? {
        let name = folderName.lowercased()
        return runningApplications.first { owner in
            if owner.name.lowercased() == name { return true }
            guard let identifier = owner.bundleIdentifier?.lowercased() else { return false }
            if name == identifier || name.hasPrefix(identifier + ".") { return true }
            let parts = identifier.split(separator: ".")
            // Never for Apple: a dozen `com.apple.*` processes are always running
            // and none of them is the owner of a folder called `Apple`.
            return parts.count >= 3 && parts[1] != "apple" && String(parts[1]) == name
        }
    }

    /// Resolves saved ownership against this process snapshot, including owners that started after the scan.
    public func runningOwner(for entry: FileEntry) -> FileEntry.RunningOwner? {
        for rule in entry.ownerRules + (entry.storageRule?.ownerRules ?? []) {
            let owner: FileEntry.RunningOwner?
            switch rule {
            case .bundleIdentifier(let identifier): owner = runningOwner(bundleIdentifier: identifier)
            case .bundlePath(let path): owner = runningOwner(atBundlePath: path)
            case .bundleIdentifierPrefix(let prefix): owner = runningOwner(bundleIdentifierPrefix: prefix)
            case .cacheName(let name): owner = runningOwner(ofCacheNamed: name)
            }
            if let owner { return owner }
        }
        if let previous = entry.inUseBy {
            if let identifier = previous.bundleIdentifier,
               let owner = runningOwner(bundleIdentifier: identifier) { return owner }
            if let owner = runningOwner(atBundlePath: previous.bundlePath) { return owner }
        }
        // Removing a parent also removes its contents.
        for child in entry.children {
            if let owner = runningOwner(for: child) { return owner }
        }
        return nil
    }

    /// True when a path is excluded, inside an excluded folder — **or contains
    /// one**. Every scanner must consult this before emitting an entry. A date is
    /// no part of this answer: nothing here hides, locks or badges a row for having
    /// been used lately — see `FileEntry.ProtectionReason`.
    ///
    /// The ancestor rule matters as much as the descendant one: with
    /// `~/Documents/Project/Secrets` excluded, a row for `~/Documents/Project` would
    /// remove the secrets along with everything else. An exclusion protects its
    /// subtree from whichever row reaches it. Category roots are gated with
    /// ``isWithinExclusion(_:)`` instead, or one deep exclusion would switch off the
    /// whole category above it.
    public func isExcluded(_ url: URL) -> Bool {
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
/// * consult `context.isExcluded(_:)` before emitting an entry;
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
        Self.lastOpenedDate(for: url)
    }

    /// The same answer for code with no scanner instance to ask — the static
    /// helpers that split an application's folders into rows.
    static func lastOpenedDate(for url: URL) -> Date? {
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
        guard !context.isExcluded(url) else { return nil }

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
