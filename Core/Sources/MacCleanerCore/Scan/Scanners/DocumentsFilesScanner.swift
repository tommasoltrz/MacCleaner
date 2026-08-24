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

    public init() {}

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
        let home = URL(fileURLWithPath: NSHomeDirectory())

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

                let lastOpened = lastOpenedDate(for: candidate.url)
                guard !context.isExcluded(candidate.url, lastOpened: lastOpened) else { continue }

                let measured = try await measure(candidate, context: context)
                unreadableCount += measured.unreadableCount
                // See `SizeMeasurement.containsProtectedPattern`.
                guard !measured.containsProtectedPattern else { continue }

                let minimum = candidate.isDirectory
                    ? Self.minimumFolderBytes
                    : Self.minimumFileBytes
                guard measured.bytes >= minimum else { continue }

                entries.append(Self.entry(
                    for: candidate,
                    bytes: measured.bytes,
                    lastOpened: lastOpened,
                    childCount: measured.childCount
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
        // Every entry is a disjoint top-level item, so the sum is exactly what
        // removing all of them would free.
        let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.allocatedBytes }

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
    }

    /// Sizes one top-level item.
    ///
    /// The original's `scanChildren` also returned one level of nested entries, which
    /// this port deliberately drops — do not reinstate it. `FileEntry.children` means
    /// "further files removed *alongside* this one", the leftovers `ApplicationsScanner`
    /// attaches to an app bundle, and `totalBytesIncludingChildren` adds them to the
    /// parent on exactly that basis. Contained children would be counted twice by the
    /// same accessor, and a removal total that overstates what deleting frees is the
    /// class of bug this rewrite exists to end. The design agrees: file rows are
    /// leaves, with an empty slot where a disclosure triangle would sit.
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
        childCount: Int?
    ) -> FileEntry {
        let isRegenerable = candidate.isDirectory && Self.isRegenerable(candidate.url)
        return FileEntry(
            url: candidate.url,
            kind: kind(for: candidate, isRegenerable: isRegenerable),
            allocatedBytes: bytes,
            lastOpened: lastOpened,
            isRegenerable: isRegenerable,
            childCount: childCount
        )
    }

    private static func kind(for candidate: Candidate, isRegenerable: Bool) -> FileEntry.Kind {
        let ext = candidate.url.pathExtension.lowercased()
        // Checked before the directory branch: a `.sparsebundle` is a folder on disk
        // but a disk image to the user.
        if diskImageExtensions.contains(ext) { return .diskImage }
        if candidate.isDirectory {
            if ext == "app" { return .appBundle }
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
