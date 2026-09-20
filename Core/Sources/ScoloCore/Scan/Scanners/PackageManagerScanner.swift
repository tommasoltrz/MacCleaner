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

    /// The home whose cache roots are scanned. Injectable so the rules above can be
    /// exercised against a fixture tree; production reads the real home.
    private let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
    }

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
        // Taken off this list at integration and put back on 20 Sep 2026.
        // `HiddenDataScanner` claimed `~/.cache` as a single row then, so a child
        // claimed here was offered twice. `SystemCachesScanner` lists the folder child
        // by child now and skips the names claimed here — see its
        // `packageManagerOwnedDotCacheNames`.
        // The XDG layout is Linux's, but a Yarn run with `XDG_CACHE_HOME` set, or one
        // carried over in a migrated home, leaves it on a Mac too.
        CacheRoot(label: "Yarn cache (XDG)", components: [".cache", "yarn"]),
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
        CacheRoot(label: "Playwright browsers", components: ["Library", "Caches", "ms-playwright"]),
        // Back for the same reason as `~/.cache/yarn` above.
        CacheRoot(label: "Playwright browsers (XDG)", components: [".cache", "ms-playwright"]),

        // uv keeps its cache at `~/.cache/uv` on macOS as on Linux — 2.0 GB on this
        // Mac, the largest thing in `~/.cache`, and until the split offered only as
        // part of that folder's single row. `uv cache clean` is the tool's own
        // instruction; environments are linked or cloned out of it, so they survive.
        CacheRoot(label: "uv cache", components: [".cache", "uv"]),

        // ADDED 20 Sep 2026, after reading Purge (github.com/jithin-sabu/purge-app),
        // which offers most of these. `~/.cargo`, `~/.bun` and the rest were left out
        // whole because each mixes a cache with an installed toolchain. That was the
        // right reason to refuse the folder and the wrong reason to refuse the cache
        // inside it: every root below is the tool's own download cache by its
        // documented default, never the folder that holds the tool.
        //
        // Inside a home dot-folder. `HiddenDataScanner.dotDirectorySkipList` names
        // each of these folders, or that scanner lists it whole and the two
        // categories offer the same bytes; `DisjointCategoriesTests` holds the two
        // lists together.
        CacheRoot(label: "Bun install cache", components: [".bun", "install", "cache"]),
        // `registry` is the index, the downloaded crates and their unpacked source;
        // `git` is the same for git dependencies. `~/.cargo/bin` — what
        // `cargo install` put there — is not touched.
        CacheRoot(label: "Cargo registry", components: [".cargo", "registry"]),
        CacheRoot(label: "Cargo git dependencies", components: [".cargo", "git"]),
        // `~/.ivy2/local` holds what the user published with `publishLocal` and is
        // not a download, so only `cache` is named.
        CacheRoot(label: "Ivy cache", components: [".ivy2", "cache"]),
        CacheRoot(label: "Bundler cache", components: [".bundle", "cache"]),
        // Projects build against this folder directly, so the next build restores
        // it; `dotnet nuget locals all --clear` is Microsoft's own instruction.
        CacheRoot(label: "NuGet packages", components: [".nuget", "packages"]),
        CacheRoot(label: "Hex packages", components: [".hex", "packages"]),
        CacheRoot(label: "Cabal packages", components: [".cabal", "packages"]),
        // `~/.pub-cache/bin` and `global_packages` are what `pub global activate`
        // installed, so the two download folders are named and the root is not.
        CacheRoot(label: "Dart pub cache", components: [".pub-cache", "hosted"]),
        CacheRoot(label: "Dart pub git dependencies", components: [".pub-cache", "git"]),

        // Under `~/Library/Caches`, where System Caches had been offering each as a
        // safe row named for its folder. Nothing becomes safe that was not; the row
        // gains a name a person can read and the category it belongs to. Mirrored in
        // `SystemCachesScanner.packageManagerOwnedCacheNames`.
        CacheRoot(label: "Deno cache", components: ["Library", "Caches", "deno"]),
        CacheRoot(label: "Go build cache", components: ["Library", "Caches", "go-build"]),
        CacheRoot(label: "Coursier cache", components: ["Library", "Caches", "Coursier"]),
        CacheRoot(label: "Composer cache", components: ["Library", "Caches", "composer"]),
        CacheRoot(label: "Pipenv cache", components: ["Library", "Caches", "pipenv"]),
        CacheRoot(label: "SwiftPM cache", components: ["Library", "Caches", "org.swift.swiftpm"]),
        CacheRoot(label: "Carthage cache", components: ["Library", "Caches", "org.carthage.CarthageKit"]),
        CacheRoot(label: "node-gyp headers", components: ["Library", "Caches", "node-gyp"]),
        CacheRoot(label: "Electron downloads", components: ["Library", "Caches", "electron"]),
        CacheRoot(label: "electron-builder cache", components: ["Library", "Caches", "electron-builder"]),
        // The same kind of thing as Playwright's browsers above: the test runner's
        // own binary, fetched again by `cypress install`.
        CacheRoot(label: "Cypress binaries", components: ["Library", "Caches", "Cypress"]),
        CacheRoot(label: "ccache", components: ["Library", "Caches", "ccache"])

        // Looked at and left out, each for a reason a name does not show:
        // * `~/.m2/repository` — also holds what the user built with `mvn install`,
        //   which no server can give back.
        // * `~/go/pkg/mod` — read-only by design, so a plain removal fails half way;
        //   `go clean -modcache` is the tool for it.
        // * `~/.gem` — installed gems, not a cache. `~/.sbt`, `~/.stack`, `~/.rustup`,
        //   `~/.nvm`, `~/.deno` — toolchains, with or without a cache beside them.
        // * `~/.vagrant.d/boxes` — a box may have been packaged on this Mac, and the
        //   rest are multi-gigabyte downloads, the CocoaPods-repos argument again.
        // * `~/.terraform.d/plugin-cache` — working directories link into it, so
        //   removal leaves them broken until the next `terraform init`.
        // * `~/Library/Caches/pypoetry` — holds Poetry's virtual environments beside
        //   its cache. System Caches still offers that folder whole, which is a
        //   fault of that scanner's and is written down in the backlog.
        // * rebar3, `act`, pre-commit, Puppeteer — under `~/.cache`, never seen on this
        //   Mac. System Caches lists each as a row of its own, safe only on its tool's
        //   `CACHEDIR.TAG`, which is where a cache nobody has looked at belongs.
    ]

    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var entries: [FileEntry] = []
        var totalBytes: Int64 = 0
        var unreadableCount = 0

        for root in Self.roots {
            try Task.checkCancellation()

            let url = root.url(relativeTo: home)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let lastOpened = lastOpenedDate(for: url)
            // Folder and pattern exclusions apply, and no date does. A cache is
            // written every time its app runs, so "touched in the last 30 days"
            // describes every cache worth showing — a recency filter hid exactly
            // the largest ones (Chrome's, an active IDE's) and left only the stale
            // caches of abandoned apps. The cost of removal here is regeneration,
            // not loss, which is what the category's `safe` badge tells the user.
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
            // See `SizeMeasurement.containsProtectedPattern`.
            guard !measured.containsProtectedPattern else { continue }

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

        // Old extension versions an editor has itself marked for removal — see
        // `EditorExtensionStores`. Here and not in a category of their own because
        // that is what they are: packages from a registry, superseded, that the tool
        // which fetched them will delete. Safe on the editor's word, with one
        // condition the editor's word does not cover: an update waiting for a reload
        // leaves the old version running in the open window, so a row under an open
        // editor is held like any cache under its owner.
        for extensionFolder in EditorExtensionStores.obsolete(home: home) {
            try Task.checkCancellation()
            let url = extensionFolder.url
            guard !context.isExcluded(url) else { continue }
            let measured = try await context.measurer.measure(url)
            unreadableCount += measured.unreadableCount
            guard !measured.containsProtectedPattern, measured.allocatedBytes > 0 else { continue }

            let editor = extensionFolder.editor
            entries.append(FileEntry(
                url: url,
                displayName: EditorExtensionStores.displayName(forFolder: url.lastPathComponent),
                parentDisplay: "\(editor.name) marked this version for removal · "
                    + FileEntry.abbreviate(url.deletingLastPathComponent().path),
                kind: .cache,
                allocatedBytes: measured.allocatedBytes,
                lastOpened: lastOpenedDate(for: url),
                isRegenerable: true,
                inUseBy: context.runningOwner(bundleIdentifier: editor.bundleIdentifier)
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
