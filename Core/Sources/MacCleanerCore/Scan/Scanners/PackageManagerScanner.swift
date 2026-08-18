import Foundation

/// Scanner category 5 — **Package Manager Caches**, the green `safe` badge.
///
/// Everything this category emits is a download or build cache that the tool which
/// created it will rebuild on demand, so all entries are `.cache` / `isRegenerable`
/// and the whole total feeds the Dashboard's "Safe to remove" figure. Nothing here
/// requires human judgement, which is exactly why the roots below are a fixed,
/// audited list rather than a heuristic sweep: one wrong path and an unattended
/// clean deletes a project.
///
/// Ports `electron/cleaners/packageManagers.ts`, dropping two of its behaviours:
///
/// * **`du -sk` sizing.** `du` exits non-zero on the first unreadable directory and
///   the old `catch` turned that into `0`, so one permission-denied folder reported
///   an entire multi-gigabyte cache as empty. All sizing goes through
///   `context.measurer`, whose enumerator counts an unreadable entry and keeps
///   walking; the count is surfaced in `unreadableCount` instead of being swallowed.
/// * **`which npm` gating.** The old scanner hid a cache whenever the tool was not
///   on `PATH`. That is backwards twice over: a GUI app inherits a login `PATH`
///   without the user's shell rc, so an nvm-managed `npm` is routinely invisible and
///   its cache was never offered; and the cache of a tool the user has *uninstalled*
///   is the single best thing to reclaim. The directory existing, with bytes in it,
///   is the whole condition now.
///
/// ### Reported size is an upper bound
///
/// A pnpm store is content-addressable: its files are hard-linked (or APFS-cloned)
/// into every project `node_modules` that needs them. Deleting store entries
/// therefore frees **less** than their apparent sum, because the blocks stay alive
/// behind the other references. `AllocatedSizeMeasurer` deduplicates hard links
/// within a single measurement, but no per-file API can see clone sharing between
/// distinct files, so the number reported here remains an upper bound on what
/// removal actually reclaims.
///
/// Do not "fix" this by scaling the total down. Any correction factor would be a
/// guess, and turning an honest upper bound into a fabricated precise figure would
/// make the app promise space it cannot deliver.
public struct PackageManagerScanner: CategoryScanner {

    public let id: CategoryID = .packageManagers

    public init() {}

    // MARK: - Cache roots

    /// One audited cache location, addressed relative to `$HOME`.
    struct CacheRoot: Sendable {
        /// Shown as the row's name. The row also prints the real parent path
        /// underneath, so several roots may share a tool name without ambiguity.
        let label: String
        let components: [String]

        func url(relativeTo home: URL) -> URL {
            components.reduce(home) { $0.appendingPathComponent($1) }
        }
    }

    /// The roots must stay **pairwise disjoint** — no entry may be an ancestor of
    /// another — or the category total double-counts and the "Safe to remove" figure
    /// overstates. Check this when adding a path.
    static let roots: [CacheRoot] = [
        // npm's content-addressable cache. `~/.npm/_logs` is deliberately left
        // alone: it is kilobytes, and it is what `npm` asks users to attach to bug
        // reports.
        CacheRoot(label: "npm cache", components: [".npm", "_cacache"]),

        // ADDED: Yarn 1 on macOS defaults to `~/Library/Caches/Yarn`, not the two
        // paths the Electron version listed — those are the Linux/XDG layouts. The
        // original therefore missed the Yarn cache on the platform this app ships
        // for. All four are kept, since a machine can carry any of them.
        CacheRoot(label: "Yarn cache", components: ["Library", "Caches", "Yarn"]),
        CacheRoot(label: "Yarn cache (classic)", components: [".yarn", "cache"]),
        // REMOVED at integration: `~/.cache/yarn`. HiddenDataScanner claims the whole
        // of `~/.cache` as a single entry, so claiming a child here would offer the
        // same bytes in two categories. Yarn's real macOS default is the
        // `~/Library/Caches/Yarn` root above; the XDG layout is the Linux one.
        // See DisjointCategoriesTests.
        // ADDED: Yarn Berry's global cache, used by every non-zero-install repo.
        CacheRoot(label: "Yarn Berry cache", components: [".yarn", "berry", "cache"]),

        // ADDED: pnpm, absent from the original entirely despite usually being the
        // largest single item in this category. See the note on upper bounds above —
        // these entries are hard-linked into project `node_modules`.
        CacheRoot(label: "pnpm store", components: ["Library", "pnpm", "store"]),
        CacheRoot(label: "pnpm store (legacy)", components: [".pnpm-store"]),
        CacheRoot(label: "pnpm metadata cache", components: ["Library", "Caches", "pnpm"]),

        CacheRoot(label: "pip cache", components: ["Library", "Caches", "pip"]),

        // `~/Library/Caches/Homebrew` belongs to *this* category, not System Caches.
        // It sits inside `~/Library/Caches`, which the System Caches scanner
        // enumerates, so that scanner carves this path out and the two categories
        // stay disjoint. Without the carve-out the same bytes appear twice and the
        // Dashboard's "Safe to remove" total is inflated — the exact double count the
        // storage breakdown had to correct for. The same argument applies to the
        // other `~/Library/Caches` roots listed here (Yarn, pnpm, pip, CocoaPods,
        // Playwright): disjointness is enforced on the System Caches side, since only
        // that scanner can decide what to skip while walking the directory.
        CacheRoot(label: "Homebrew cache", components: ["Library", "Caches", "Homebrew"]),

        // `~/.cocoapods/repos` is deliberately excluded: it is a git clone of the
        // spec index, and while technically regenerable, re-cloning it costs a
        // multi-gigabyte download. "Safe to remove" here means removable without
        // consequence, not merely reproducible.
        CacheRoot(label: "CocoaPods cache", components: ["Library", "Caches", "CocoaPods"]),

        CacheRoot(label: "Gradle cache", components: [".gradle", "caches"]),
        // ADDED: the Gradle wrapper keeps a full distribution per project-pinned
        // version under `dists`, which routinely outgrows `caches` itself.
        CacheRoot(label: "Gradle distributions", components: [".gradle", "wrapper", "dists"]),

        // ADDED: Playwright's macOS default is `~/Library/Caches/ms-playwright`; the
        // original listed only the Linux path, so it never found the browsers.
        CacheRoot(label: "Playwright browsers", components: ["Library", "Caches", "ms-playwright"])
        // REMOVED at integration: `~/.cache/ms-playwright`, for the same reason as
        // `~/.cache/yarn` above — HiddenDataScanner owns all of `~/.cache`.

        // Not listed here: `~/.cargo`, `~/.m2`, `~/.rustup`, `~/.nvm`, `~/.bun`,
        // `~/.deno`. The category subtitle names the tools it covers, and those roots
        // mix caches with installed toolchains that removal would break. The
        // Dashboard's "Package & Build Caches" segment measures them separately, so
        // they are not unaccounted for — only out of scope for unattended cleanup.
    ]

    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let home = URL(fileURLWithPath: NSHomeDirectory())

        var entries: [FileEntry] = []
        var totalBytes: Int64 = 0
        var unreadableCount = 0

        for root in Self.roots {
            try Task.checkCancellation()

            let url = root.url(relativeTo: home)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let lastOpened = lastOpenedDate(for: url)
            // Folder and pattern exclusions apply; the recency shield deliberately
                // does not. A cache is written every time its app runs, so "touched
                // in the last 30 days" describes every cache worth showing — the
                // shield would hide exactly the largest ones (Chrome's, an active
                // IDE's) and leave only the stale caches of abandoned apps. The cost
                // of removal here is regeneration, not loss, which is what the
                // category's `safe` badge already tells the user.
                guard !context.isExcluded(url) else { continue }

            let measured: SizeMeasurement
            do {
                measured = try await context.measurer.measure(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A root that cannot be measured is reported as unreadable, never
                // reported as zero. Silently zeroing on failure is the predecessor's
                // bug this port exists to kill.
                unreadableCount += 1
                continue
            }

            unreadableCount += measured.unreadableCount

            // The original's only threshold: an empty cache is not a cleanup
            // candidate, it is noise in a list the user has to read.
            guard measured.allocatedBytes > 0 else { continue }

            entries.append(FileEntry(
                url: url,
                displayName: root.label,
                kind: .cache,
                allocatedBytes: measured.allocatedBytes,
                lastOpened: lastOpened,
                isRegenerable: true,
                childCount: (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
            ))
            totalBytes += measured.allocatedBytes
        }

        entries.sort { $0.allocatedBytes > $1.allocatedBytes }

        // `.empty`, never `.unavailable`: a machine with no package-manager caches is
        // a successful measurement of nothing, not a scanner that failed. There is no
        // daemon to be missing here and so no fix to tell the user about.
        return ScanCategoryResult(
            categoryID: id,
            totalBytes: totalBytes,
            entries: entries,
            availability: entries.isEmpty ? .empty : .available,
            unreadableCount: unreadableCount
        )
    }
}
