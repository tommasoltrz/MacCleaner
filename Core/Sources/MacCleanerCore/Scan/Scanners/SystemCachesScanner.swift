import Foundation

/// **System Caches & Logs** — the immediate children of `~/Library/Caches` and
/// `~/Library/Logs`, everything the category subtitle promises and nothing else.
///
/// Ports `electron/cleaners/systemCaches.ts`. Three properties of that original are
/// deliberately not carried over:
///
/// * **`du -sk` per child.** `du` exits non-zero the moment it meets a directory it
///   cannot read, and the original's `catch` turned that exit code into `0` — a
///   single permission-denied folder erased an entire cache from the total, silently.
///   Sizing here goes only through `context.measurer`, which counts the unreadable
///   entry and keeps walking.
/// * **One subprocess per child.** `~/Library/Caches` routinely holds well over a
///   hundred entries, so the original spawned that many shells per scan.
///   `measureChildren(of:)` covers a whole root in one traversal.
/// * **Directories only.** The original's listing filter kept directories and
///   symlinks and dropped plain files, so loose logs sitting directly in
///   `~/Library/Logs` were never offered and their bytes went missing from the
///   category total. Every child counts here.
public struct SystemCachesScanner: CategoryScanner {

    public let id: CategoryID = .systemCaches

    let cachesRoot: URL
    let logsRoot: URL

    public init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.init(
            cachesRoot: home.appendingPathComponent("Library/Caches"),
            logsRoot: home.appendingPathComponent("Library/Logs")
        )
    }

    /// Exists so tests can aim the scan at a fixture tree; production always uses the
    /// two real roots above.
    init(cachesRoot: URL, logsRoot: URL) {
        self.cachesRoot = cachesRoot
        self.logsRoot = logsRoot
    }

    private var roots: [URL] { [cachesRoot, logsRoot] }

    // MARK: - Rules

    /// The original's `EXCLUDED` list, matched as a path prefix. Nothing under the two
    /// roots reaches these under normal conditions; it stays as a guard for the cases
    /// that could — a cache directory symlinked out of `~/Library/Caches`, or a third
    /// root added later.
    ///
    /// Unlike the original's bare `startsWith`, the match is component-aware, so
    /// `/etc` no longer also claims a hypothetical `/etcetera`.
    private static let protectedPrefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support",
            home + "/Library/Preferences",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc"
        ]
    }()

    /// Children of `~/Library/Caches` that the **Package Manager Caches** category
    /// already offers.
    ///
    /// They are skipped here so the two categories stay disjoint. Left in both, the
    /// same bytes would be counted twice in the Dashboard's "Safe to remove" total and
    /// offered to the user twice — cleaning one category would make the other's
    /// figure a lie. The Electron predecessor had exactly this overlap.
    ///
    /// This list must mirror every `["Library", "Caches", …]` root in
    /// `PackageManagerScanner`. `DisjointCategoriesTests` asserts that it does, so
    /// adding a cache root there fails the build here rather than silently
    /// double-counting.
    static let packageManagerOwnedCacheNames: Set<String> = [
        "Homebrew", "pip", "CocoaPods",
        // Added at integration: PackageManagerScanner claims these too, and the
        // original three-name list would have double-counted them.
        "Yarn", "pnpm", "ms-playwright"
    ]

    /// The ported threshold: the original emitted any child whose measured size was
    /// above zero. No larger floor is imposed, because this category's value is the
    /// long tail — a cutoff would hide rows whose sum is the reason the category
    /// exists. Zero-byte children are still dropped; a row reading `0 B` is noise.
    ///
    /// Symlinked children land below this line on their own: the measurer does not
    /// follow symlinks by default, so a link measures nothing and its target is
    /// counted wherever it actually lives.
    private static let minimumEntryBytes: Int64 = 1

    // MARK: - Scanning

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let fileManager = FileManager.default
        var entries: [FileEntry] = []
        var unreadableCount = 0
        var reachableRoots = 0

        for root in roots {
            try Task.checkCancellation()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            // `measureChildren` reports a listing failure as "no children". Reading the
            // directory here first is the only thing that tells an empty cache root
            // apart from one we were denied — the distinction the availability copy
            // below depends on.
            guard (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil else {
                unreadableCount += 1
                continue
            }
            reachableRoots += 1

            // One walk covers the whole root. Filtering happens after it rather than
            // before because the alternative — re-measuring the survivors one at a
            // time — is precisely the per-child pattern this port removes.
            let measured = try await context.measurer.measureChildren(of: root)

            for (url, measurement) in measured {
                try Task.checkCancellation()

                // Skipped before the tally, so a read failure inside Homebrew's cache
                // is reported by the category that owns those bytes, not by this one.
                if root == cachesRoot,
                   Self.packageManagerOwnedCacheNames.contains(url.lastPathComponent) {
                    continue
                }

                unreadableCount += measurement.unreadableCount

                guard !Self.isProtected(url) else { continue }
                guard measurement.allocatedBytes >= Self.minimumEntryBytes else { continue }

                let lastOpened = lastOpenedDate(for: url)
                // Folder and pattern exclusions apply; the recency shield deliberately
                // does not. A cache is written every time its app runs, so "touched
                // in the last 30 days" describes every cache worth showing — the
                // shield would hide exactly the largest ones (Chrome's, an active
                // IDE's) and leave only the stale caches of abandoned apps. The cost
                // of removal here is regeneration, not loss, which is what the
                // category's `safe` badge already tells the user.
                guard !context.isExcluded(url) else { continue }

                entries.append(FileEntry(
                    url: url,
                    kind: .cache,
                    allocatedBytes: measurement.allocatedBytes,
                    lastOpened: lastOpened,
                    // Both roots hold nothing but artifacts the system rebuilds on
                    // demand. This is what earns the category its green `safe` badge
                    // and puts it in the Dashboard's "Safe to remove" total.
                    isRegenerable: true,
                    childCount: Self.childCount(of: url)
                ))
            }
        }

        // Every root refused us. Say how to fix it rather than reporting an empty
        // category, which would read as "nothing to clean".
        if reachableRoots == 0, unreadableCount > 0 {
            return ScanCategoryResult(
                categoryID: id,
                availability: .unavailable(
                    reason: "The app cannot read ~/Library/Caches or ~/Library/Logs. "
                        + "Grant Full Disk Access in System Settings › Privacy & Security."
                ),
                unreadableCount: unreadableCount
            )
        }

        // Largest first, as the expanded category body lists them. It also makes the
        // result deterministic: `measureChildren` returns an unordered dictionary.
        entries.sort { $0.allocatedBytes > $1.allocatedBytes }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.allocatedBytes },
            entries: entries,
            availability: entries.isEmpty ? .empty : .available,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Support

    private static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Item count for the row's `· 1,204 items` qualifier; `nil` for anything that is
    /// not a directory.
    private static func childCount(of url: URL) -> Int? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
    }
}
