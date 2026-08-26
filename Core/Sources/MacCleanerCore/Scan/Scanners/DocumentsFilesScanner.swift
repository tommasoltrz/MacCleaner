import Foundation

/// **Documents & Files** — the largest things sitting in the six user folders the
/// design names: Documents, Downloads, Desktop, Movies, Pictures and Music.
///
/// A port of the Electron `largeFiles.ts`, whose sizing carried the worst bug in the
/// old app: every total came from `du -sk`, and `du` exits non-zero the moment it
/// meets a directory it cannot read. The `catch` around it returned `0`, so a single
/// permission-denied folder anywhere under `~/Documents` silently zeroed the entire
/// category. Everything here is sized through `context.measurer`, which counts what
/// it could not read and reports it rather than throwing the total away.
///
/// The walk is also half the work the original did. `du` ran twice over the same
/// bytes — once batched over a root's subdirectories, then again over the children of
/// each of them, to build a level of nested rows. Sizes here come from a single walk
/// per top-level item, and the list is flat: one row per candidate, as the design's
/// leaf file rows require. See `measure(_:context:)` for why the nesting is gone and
/// must not come back.
public struct DocumentsFilesScanner: CategoryScanner {

    public let id: CategoryID = .documentsAndFiles

    /// Injectable so a test can lay out a home of its own.
    private let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    // MARK: - Roots

    /// `SCAN_ROOTS`, carried over unchanged.
    private static let rootNames = [
        "Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music"
    ]

    /// `ATOMIC_DIR_NAMES`: dependency, build and history trees that mean something
    /// only as a whole. They are measured and reported as one entry and never
    /// expanded — a `node_modules` broken into 900 rows buries the finding instead of
    /// surfacing it.
    ///
    /// Most of these begin with a dot and are already dropped by the hidden-item
    /// filter; the list is kept whole so the guard still holds if that filter is ever
    /// relaxed.
    private static let atomicDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "vendor",
        ".venv", "venv", "env", "__pycache__", ".tox",
        "Pods", ".gradle", "bower_components", "jspm_packages",
        ".pnpm", ".yarn", ".cargo", "target", "dist", "build"
    ]

    /// The subset of the atomic list that a tool rebuilds from a manifest or from
    /// source. These get the design's `· regenerable` qualifier and the purple folder
    /// icon, which is information the Electron version never surfaced.
    ///
    /// `.git`, `.svn`, `.hg` and `vendor` are deliberately absent: deleting those
    /// destroys history or committed code, and labelling them regenerable would be a
    /// lie with expensive consequences.
    private static let regenerableDirectoryNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "Pods",
        "__pycache__", ".venv", "venv", ".tox", ".gradle",
        "target", "dist", "build"
    ]

    /// Adobe preview caches — the design's own example of a regenerable folder
    /// (`Lightroom Previews.lrdata`).
    private static let regenerableDirectoryExtensions: Set<String> = ["lrdata", "lrprev"]

    /// Apple's own media libraries, which are never offered.
    ///
    /// `~/Pictures/Photos Library.photoslibrary` *is* the user's photographs, and
    /// the Music and TV folders are what those apps manage. Removing one from here
    /// is not cleanup, it is data loss with a friendly checkbox — and each app has
    /// its own way to reclaim space (Optimize Mac Storage, remove downloads). The
    /// recency badge used to keep these out by accident, since a library is touched
    /// constantly; now that recency is information rather than a filter, the rule
    /// has to be explicit. The list itself is `AppleMediaLibrary`, shared with the
    /// Storage Explorer so the two cannot disagree about what a library is.
    static func isMediaLibrary(_ url: URL, home: URL) -> Bool {
        AppleMediaLibrary.contains(url, home: home)
    }

    // MARK: - Thresholds

    /// `MIN_ITEM_BYTES`. The original's comment claims this is the floor for all
    /// top-level items, but it only ever applied it to directories — top-level files
    /// were held to `MIN_FILE_BYTES`. That split is kept.
    private static let minimumFolderBytes: Int64 = 1 * 1024 * 1024

    /// `MIN_FILE_BYTES`. Files are held to a far higher bar than folders because a
    /// 1 MB file is never the reason a disk is full, while a 1 MB folder can still be
    /// a useful thing to notice.
    ///
    /// The original's third threshold, `MIN_CHILD_BYTES` (512 KB), governed nested
    /// children only and went with the expansion — see `measure(_:context:)`.
    private static let minimumFileBytes: Int64 = 10 * 1024 * 1024

    /// `MAX_CHILDREN_SCAN`. Still load-bearing without the expansion: it is what keeps
    /// `measureChildren(of:)` from materialising a dictionary entry per direct child
    /// of a pathologically wide folder.
    private static let maximumChildrenToMeasureIndividually = 300

    // MARK: - Kinds

    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "xip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "7z", "rar", "zst", "lz4", "cpgz"
    ]

    private static let diskImageExtensions: Set<String> = [
        "dmg", "iso", "img", "cdr", "sparseimage", "sparsebundle"
    ]

    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var entries: [FileEntry] = []
        var unreadableCount = 0
        var presentRoots = 0
        var readableRoots = 0

        for name in Self.rootNames {
            try Task.checkCancellation()

            let root = home.appendingPathComponent(name)
            guard Self.isDirectory(root) else { continue }
            presentRoots += 1

            // Excluding a whole root should make the scan faster, not merely quieter,
            // so the check happens before anything is walked. No `lastOpened` here:
            // recency protects individual items, never an entire folder.
            guard !context.isWithinExclusion(root) else { continue }

            guard let listing = Self.listing(of: root) else {
                // Where a TCC denial on ~/Desktop, ~/Documents or ~/Downloads lands.
                unreadableCount += 1
                continue
            }
            readableRoots += 1

            for candidate in listing.candidates {
                try Task.checkCancellation()

                // Recency is a badge, not a filter — see `ScanContext.protectRecentDays`.
                // This loop used to `continue` on a recent item, which hid the
                // largest folder on the disk because it had been built that morning.
                let lastOpened = lastOpenedDate(for: candidate.url)
                guard !context.isExcluded(candidate.url) else { continue }
                guard !Self.isMediaLibrary(candidate.url, home: home) else { continue }

                let measured = try await measure(candidate, context: context)
                unreadableCount += measured.unreadableCount
                // See `SizeMeasurement.containsProtectedPattern`.
                guard !measured.containsProtectedPattern else { continue }

                // Keep dependency stores under their project. The parent shows its
                // complete size. The child lets the user remove dependencies while
                // the source stays in place.
                let dependencyChildren = measured.carved.compactMap { carved -> FileEntry? in
                    guard !carved.root.kind.isXcodeOutput,
                          !carved.measurement.containsProtectedPattern
                    else { return nil }
                    return FileEntry(
                        url: carved.root.url,
                        parentDisplay: FileEntry.abbreviate(
                            carved.root.url.deletingLastPathComponent().path
                        ) + " · " + carved.root.kind.label,
                        kind: .cache,
                        allocatedBytes: carved.measurement.allocatedBytes,
                        lastOpened: lastOpenedDate(for: carved.root.url),
                        isRegenerable: true,
                        childCount: (try? FileManager.default.contentsOfDirectory(
                            atPath: carved.root.url.path
                        ))?.count
                    )
                }

                let minimum = candidate.isDirectory
                    ? Self.minimumFolderBytes
                    : Self.minimumFileBytes
                let completeBytes = measured.bytes + dependencyChildren.reduce(0) {
                    $0 + $1.allocatedBytes
                }
                guard completeBytes >= minimum else { continue }

                entries.append(Self.entry(
                    for: candidate,
                    bytes: measured.bytes,
                    lastOpened: lastOpened,
                    isRecent: context.isRecencyProtected(lastOpened),
                    childCount: measured.childCount,
                    children: dependencyChildren
                ))
            }
        }

        if presentRoots > 0 && readableRoots == 0 {
            return ScanCategoryResult(
                categoryID: id,
                availability: .unavailable(reason: "MacCleaner cannot read Documents, "
                    + "Downloads or Desktop. Grant it Full Disk Access in System Settings → "
                    + "Privacy & Security, then scan again."),
                unreadableCount: unreadableCount
            )
        }

        let sorted = Self.sortedBySize(entries)
        // Each parent owns its disclosed dependency children. Display bytes include
        // each child once and match the complete removal plan.
        let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.displayBytes }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: totalBytes,
            entries: sorted,
            availability: sorted.isEmpty ? .empty : .available,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Measuring one top-level candidate

    private struct Measured {
        var bytes: Int64 = 0
        var unreadableCount = 0
        /// `· N items` for folders, `nil` for files.
        var childCount: Int?
        /// See `SizeMeasurement.containsProtectedPattern`. A candidate carrying
        /// this is never emitted: the row would offer to remove a vault with it.
        var containsProtectedPattern = false
        /// Build output and dependency stores found inside a project folder and
        /// subtracted from `bytes`. Dependency stores become disclosed children.
        /// Xcode output is listed by `XcodeScanner`.
        var carved: [Carved] = []
    }

    private struct Carved {
        let root: BuildOutputDetector.Root
        let measurement: SizeMeasurement
    }

    /// Sizes one top-level item.
    ///
    /// The original's `scanChildren` returned ordinary nested files. This port does
    /// not restore that expansion. It attaches only recognized dependency stores.
    /// Their bytes leave the parent remainder before they become children. Thus,
    /// removal totals count each byte once.
    private func measure(_ candidate: Candidate, context: ScanContext) async throws -> Measured {
        guard candidate.isDirectory else {
            // A plain file has no subtree, so the "one traversal, not N" rule that
            // makes `measureChildren` the right tool for folders does not apply: this
            // is a single resource-value read.
            let measurement = try await context.measurer.measure(candidate.url)
            return Measured(
                bytes: measurement.allocatedBytes,
                unreadableCount: measurement.unreadableCount,
                containsProtectedPattern: measurement.containsProtectedPattern
            )
        }

        guard let listing = Self.listing(of: candidate.url) else {
            // The measurer's enumerator will fail on the same directory for the same
            // reason and count it, so no extra tally here — one unreadable folder is
            // one unreadable entry, not two.
            let measurement = try await context.measurer.measure(candidate.url)
            return Measured(
                bytes: measurement.allocatedBytes,
                unreadableCount: measurement.unreadableCount,
                containsProtectedPattern: measurement.containsProtectedPattern
            )
        }

        var result = Measured(childCount: listing.totalCount)

        // An atomic tree is reported whole, so there is nothing to gain from resolving
        // it child by child; a pathologically wide folder would cost a dictionary
        // entry per child for the same single number. Both take the plain walk, which
        // returns an identical total.
        let isAtomic = Self.atomicDirectoryNames.contains(candidate.url.lastPathComponent)
        let isTooWide = listing.candidates.count > Self.maximumChildrenToMeasureIndividually

        guard !isAtomic, !isTooWide, !listing.candidates.isEmpty else {
            let measurement = try await context.measurer.measure(candidate.url)
            result.bytes = measurement.allocatedBytes
            result.unreadableCount = measurement.unreadableCount
            result.containsProtectedPattern = measurement.containsProtectedPattern
            return result
        }

        // Still one traversal, not one per child: `measureChildren` walks the folder
        // once and returns a full recursive total for each immediate child, sharing a
        // hard-link deduplicator across them so the parts sum to the whole exactly.
        // The original needed a second batched `du` to learn the same thing.
        let measured = try await context.measurer.measureChildren(of: candidate.url)
        for measurement in measured.values {
            result.bytes += measurement.allocatedBytes
            result.unreadableCount += measurement.unreadableCount
            result.containsProtectedPattern =
                result.containsProtectedPattern || measurement.containsProtectedPattern
        }

        // Build output and dependency stores inside a project are not the
        // project. Each becomes a row of its own — Xcode output under the Xcode
        // category, `node_modules` and its kind right here — so the bytes leave
        // this row: a `Renewals` row that still counted its 11 GB `build` folder
        // would offer the same space twice, and offer it as documents. The project
        // keeps its own size — sources, assets, whatever the user actually made.
        // An excluded root is neither carved nor listed: the user said hands off,
        // and its bytes stay where they are, inside the project.
        for output in BuildOutputDetector.roots(under: candidate.url)
        where !context.isExcluded(output.url) {
            try Task.checkCancellation()
            let carved = try await context.measurer.measure(output.url)
            if !output.kind.isXcodeOutput,
               carved.allocatedBytes < Self.minimumFolderBytes {
                continue
            }
            result.bytes = max(0, result.bytes - carved.allocatedBytes)
            result.carved.append(Carved(root: output, measurement: carved))
        }
        return result
    }

    // MARK: - Entries

    /// Builds the entry from an already-known size.
    ///
    /// Deliberately not `makeEntry(url:kind:context:)`: that convenience runs its own
    /// `measure` per item, which would undo the batching above and walk every subtree
    /// a second time.
    private static func entry(
        for candidate: Candidate,
        bytes: Int64,
        lastOpened: Date?,
        isRecent: Bool,
        childCount: Int?,
        children: [FileEntry]
    ) -> FileEntry {
        let isRegenerable = candidate.isDirectory && Self.isRegenerable(candidate.url)
        return FileEntry(
            url: candidate.url,
            kind: kind(for: candidate, isRegenerable: isRegenerable),
            allocatedBytes: bytes,
            lastOpened: lastOpened,
            isRegenerable: isRegenerable,
            protectionReason: isRecent ? .recentUse : nil,
            childCount: childCount,
            children: children
        )
    }

    private static func kind(for candidate: Candidate, isRegenerable: Bool) -> FileEntry.Kind {
        let ext = candidate.url.pathExtension.lowercased()
        // Checked before the directory branch: a `.sparsebundle` is a folder on disk
        // but a disk image to the user.
        if diskImageExtensions.contains(ext) { return .diskImage }
        if candidate.isDirectory {
            // A bundle here is a download, not an installation — see `Kind.downloadedApp`.
            if ext == "app" { return .downloadedApp }
            // `.cache` is the design's purple folder icon, used for anything
            // regenerable rather than only for literal cache directories.
            return isRegenerable ? .cache : .folder
        }
        if archiveExtensions.contains(ext) { return .archive }
        return .file
    }

    private static func isRegenerable(_ url: URL) -> Bool {
        if regenerableDirectoryNames.contains(url.lastPathComponent) { return true }
        return regenerableDirectoryExtensions.contains(url.pathExtension.lowercased())
    }

    /// Largest first, path as the tie-break so repeated scans of an unchanged disk
    /// produce an identical list.
    private static func sortedBySize(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            $0.allocatedBytes == $1.allocatedBytes
                ? $0.url.path < $1.url.path
                : $0.allocatedBytes > $1.allocatedBytes
        }
    }

    // MARK: - Directory listing

    private struct Candidate: Sendable {
        var url: URL
        var isDirectory: Bool
    }

    private struct DirectoryListing: Sendable {
        /// Every entry, hidden ones included — this is what `· N items` reports, and
        /// what the size already accounts for.
        var totalCount: Int
        /// Non-hidden, non-symlink entries: the only things offered for removal.
        var candidates: [Candidate]
    }

    private static let listingKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

    /// `nil` when the directory could not be read at all, which is a fact the caller
    /// has to record rather than treat as "empty".
    private static func listing(of directory: URL) -> DirectoryListing? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: listingKeys,
            options: []
        ) else { return nil }

        var candidates: [Candidate] = []
        for url in contents {
            if url.lastPathComponent.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: Set(listingKeys))
            // The original filtered on `Dirent`, which reports a symlink as neither a
            // file nor a directory, so links never appeared. That is worth keeping:
            // a link into a huge tree must not be offered as though removing it
            // freed that tree.
            if values?.isSymbolicLink == true { continue }
            guard let isDirectory = values?.isDirectory else { continue }
            candidates.append(Candidate(url: url, isDirectory: isDirectory))
        }
        return DirectoryListing(totalCount: contents.count, candidates: candidates)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
