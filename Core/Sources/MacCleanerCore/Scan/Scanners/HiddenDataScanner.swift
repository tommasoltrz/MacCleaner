import Foundation

/// **Hidden & System Data** — the Trash, iOS device backups, Mail, cloud mirrors,
/// large hidden dot-directories in `$HOME`, and oversized archive/VM images.
///
/// Ports `electron/cleaners/hiddenData.ts`, keeping its roots and thresholds and
/// dropping the three things that made it wrong:
///
/// * **`du -sk` sizing.** `du` exits non-zero on the first unreadable directory and
///   the predecessor's `catch { return 0 }` turned that into a zero, so one
///   permission-denied folder silently emptied the whole category. Nothing here
///   sizes anything except `context.measurer`, and every measurement's
///   `unreadableCount` is summed into the result instead of being swallowed.
/// * **`find` for discovery.** The archive sweep used a shelled-out `find` with a
///   15-second timeout; a slow disk simply produced no results, indistinguishable
///   from a clean machine. It is a `FileManager` enumeration now, cancellable and
///   honest about what it could not read.
/// * **Snapshots — see below.**
///
/// ### Snapshots are deliberately not scanned here
///
/// The predecessor emitted one zero-size pseudo-entry per APFS snapshot into this
/// category (`path: "snapshot:<name>"`, `size: 0`), and its cleaner deleted them by
/// name through `tmutil`. Snapshots are now owned entirely by ``SnapshotService``,
/// which enumerates only the Data volume and can mint a `DeletableSnapshot` for
/// nothing else — so the sealed boot snapshot macOS is running from can never be
/// offered for deletion. Listing snapshots here again, in a category whose entries
/// are plain paths, would route them around that guard and reintroduce exactly the
/// bug that work removed. The Dashboard's own snapshot disclosure row is the only
/// place they appear.
///
/// Nothing in this category is regenerable-by-definition, so `CategoryID.isSafe` is
/// `false` for it: every entry here needs a human to look at it before removal.
public struct HiddenDataScanner: CategoryScanner {

    public let id: CategoryID = .hiddenSystemData

    private let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    // MARK: - Thresholds

    /// Carried over verbatim from the Electron module.
    private enum Threshold {
        /// The predecessor's `size > 0` tests, expressed for a `>=` comparison.
        static let any: Int64 = 1
        /// `scanHiddenDirs`: a dot-directory in `$HOME` had to exceed 5 MB.
        static let hiddenDirectory: Int64 = 5 * 1024 * 1024
        /// iCloud Drive and CloudKit had to exceed 10 MB.
        static let cloudMirror: Int64 = 10 * 1024 * 1024
        /// `find -size +250000k` — 250,000 blocks of 1024 bytes, not 250 × 2²⁰.
        static let largeArchive: Int64 = 250_000 * 1024
    }

    // MARK: - Roots

    private enum Root {
        static let trash = [".Trash"]
        static let mobileSyncBackup = ["Library", "Application Support", "MobileSync", "Backup"]
        static let mailStore = ["Library", "Mail"]
        /// Sandboxed Mail keeps opened attachments here; the second path survives on
        /// machines upgraded from before Mail was sandboxed.
        static let mailDownloads: [[String]] = [
            ["Library", "Containers", "com.apple.mail", "Data", "Library", "Mail Downloads"],
            ["Library", "Mail Downloads"]
        ]
        static let dotCache = [".cache"]
        static let mobileDocuments = ["Library", "Mobile Documents"]
        static let cloudKit = ["Library", "CloudKit"]
        static let photosLibrary = ["Pictures", "Photos Library.photoslibrary"]
        /// Thumbnail and preview pyramids, which Photos rebuilds on demand.
        static let photosCaches: [[String]] = [
            photosLibrary + ["resources", "derivatives"],
            photosLibrary + ["resources", "renders"]
        ]
    }

    /// `scanHiddenDirs` skipped these: `.Trash` and `.cache` are listed in their own
    /// right below, and the rest belong to the package-manager category.
    private static let dotDirectorySkipList: Set<String> = [
        ".Trash", ".cache", ".npm", ".yarn", ".gradle", ".local"
    ]

    private static let diskImageExtensions: Set<String> = ["dmg", "iso", "vmdk", "vhd", "qcow2"]
    private static let archiveExtensions: Set<String> = ["pkg", "zip", "tar", "gz", "ova"]

    /// `find "$HOME" -maxdepth 6`.
    private static let maximumSearchDepth = 6
    private static let cancellationCheckInterval = 512

    // MARK: - Scanning

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var found = Found()

        // Paths whose bytes are already offered under some entry above. The archive
        // sweep skips them, so a 2 GB disk image sitting in the Trash is not counted
        // once inside `~/.Trash` and again as a file of its own — a double count the
        // predecessor made every time.
        var claimed = context.excludedPaths

        // 1. Trash. One row for the folder, not one per item: `FileEntry` sums its
        // children into `totalBytesIncludingChildren`, so attaching per-item children
        // to a folder already measured whole would double its size. The Trash view
        // owns per-item detail.
        let trash = url(Root.trash)
        claimed.append(trash.path)
        try await measureAndAppend(trash, kind: .folder, minimumBytes: Threshold.any,
                                   context: context, to: &found)

        // 2. iOS/iPadOS backups, one row per device backup so a single stale device
        // can be removed without touching the others.
        try await appendMobileSyncBackups(context: context, to: &found, claiming: &claimed)

        // 3. Mail. The store itself is real mail, never regenerable — it is listed
        // because it is often gigabytes, and this category is review-only.
        let mailStore = url(Root.mailStore)
        claimed.append(mailStore.path)
        try await measureAndAppend(mailStore, kind: .folder, minimumBytes: Threshold.any,
                                   context: context, to: &found)
        for components in Root.mailDownloads {
            let downloads = url(components)
            claimed.append(downloads.path)
            try await measureAndAppend(downloads, kind: .folder, minimumBytes: Threshold.any,
                                       context: context, to: &found)
        }

        // 4. The XDG-style dot-cache.
        let dotCache = url(Root.dotCache)
        claimed.append(dotCache.path)
        try await measureAndAppend(dotCache, kind: .cache, minimumBytes: Threshold.any,
                                   isRegenerable: true, context: context, to: &found)

        // 5/6. Local cloud mirrors. Not marked regenerable: a file that has not
        // finished uploading exists only here.
        for components in [Root.mobileDocuments, Root.cloudKit] {
            let mirror = url(components)
            claimed.append(mirror.path)
            try await measureAndAppend(mirror, kind: .folder, minimumBytes: Threshold.cloudMirror,
                                       context: context, to: &found)
        }

        // 7. Photos. The predecessor offered the entire `.photoslibrary` — every
        // original the user owns — as a removal candidate. Only the rebuildable
        // derivative caches inside it are offered here; the library as a whole is
        // claimed so the archive sweep does not walk back into it either.
        claimed.append(url(Root.photosLibrary).path)
        for components in Root.photosCaches {
            try await measureAndAppend(url(components), kind: .cache,
                                       minimumBytes: Threshold.any, isRegenerable: true,
                                       context: context, to: &found)
        }

        // 8. Large hidden dot-directories in $HOME.
        try await appendHiddenDirectories(context: context, to: &found, claiming: &claimed)

        // 9. Large archives and VM images.
        try await appendLargeArchives(skipping: claimed, context: context, to: &found)

        found.entries.sort { $0.allocatedBytes > $1.allocatedBytes }
        let total = found.entries.reduce(Int64(0)) { $0 + $1.allocatedBytes }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: total,
            entries: found.entries,
            availability: Self.availability(for: found),
            unreadableCount: found.unreadableCount
        )
    }

    /// Finding nothing while failing to read things is not the same as finding
    /// nothing, and the difference is one the user can act on.
    private static func availability(for found: Found) -> CategoryAvailability {
        if !found.entries.isEmpty { return .available }
        if found.unreadableCount > 0 {
            return .unavailable(reason: """
                Nothing here could be read. Grant Full Disk Access in System Settings \
                → Privacy & Security so the Trash, iOS backups and Mail can be measured.
                """)
        }
        return .empty
    }

    // MARK: - Sections

    private func appendMobileSyncBackups(
        context: ScanContext,
        to found: inout Found,
        claiming claimed: inout [String]
    ) async throws {
        let backupRoot = url(Root.mobileSyncBackup)
        claimed.append(backupRoot.path)
        guard FileManager.default.fileExists(atPath: backupRoot.path) else { return }

        // One traversal for every backup, rather than one `du` per device.
        let children = try await context.measurer.measureChildren(of: backupRoot)
        let backups = children.filter { child, _ in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }

        guard !backups.isEmpty else {
            try await measureAndAppend(backupRoot, kind: .folder, minimumBytes: Threshold.any,
                                       context: context, to: &found)
            return
        }
        for (backup, measurement) in backups {
            append(backup, kind: .folder, measurement: measurement,
                   lastOpened: lastOpenedDate(for: backup), minimumBytes: Threshold.any,
                   context: context, to: &found)
        }
    }

    private func appendHiddenDirectories(
        context: ScanContext,
        to found: inout Found,
        claiming claimed: inout [String]
    ) async throws {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []

        for child in contents.sorted(by: { $0.path < $1.path }) {
            let name = child.lastPathComponent
            guard name.hasPrefix("."), !Self.dotDirectorySkipList.contains(name) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            claimed.append(child.path)
            try await measureAndAppend(child, kind: .folder,
                                       minimumBytes: Threshold.hiddenDirectory,
                                       context: context, to: &found)
        }
    }

    private func appendLargeArchives(
        skipping skipPrefixes: [String],
        context: ScanContext,
        to found: inout Found
    ) async throws {
        let root = home
        let state = WalkState()

        let candidates: [URL] = try await withTaskCancellationHandler {
            // `Task.detached` keeps the blocking enumeration off the cooperative pool
            // but does not inherit cancellation, which is what `state` bridges.
            try await Task.detached(priority: .utility) {
                try Self.discoverLargeArchives(below: root, skipping: skipPrefixes, state: state)
            }.value
        } onCancel: {
            state.cancel()
        }
        found.unreadableCount += state.unreadableCount

        for candidate in candidates {
            // `makeEntry` measures through `context.measurer` and applies the
            // exclusion list. A regular file's measurement has no unreadable count to
            // lose, so the protocol's helper is lossless here.
            guard let entry = try await makeEntry(
                url: candidate, kind: Self.kind(for: candidate), context: context
            ) else { continue }
            // Re-checked against the measured size: the shortlist below used the
            // enumerator's cached resource values, and the measurer is the authority.
            guard entry.allocatedBytes >= Threshold.largeArchive else { continue }
            found.entries.append(entry)
        }
    }

    // MARK: - Archive discovery

    /// Shortlists archive and VM-image files at least `Threshold.largeArchive` in
    /// size, to a depth of `maximumSearchDepth` below `root`.
    ///
    /// Sizes read here are a filter and nothing else — every byte shown to the user
    /// comes back from `context.measurer`. Measuring each of the tens of thousands of
    /// files under `$HOME` individually would cost more than the rest of the scan
    /// combined, so the enumerator's prefetched resource values pick the candidates.
    private static func discoverLargeArchives(
        below root: URL,
        skipping skipPrefixes: [String],
        state: WalkState
    ) throws -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileSizeKey
        ]
        let standardRoot = root.standardizedFileURL
        let rootDepth = standardRoot.pathComponents.count

        guard let enumerator = FileManager.default.enumerator(
            at: standardRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                // Returning `true` costs one entry rather than aborting the sweep,
                // which is the whole reason this is not `find`.
                state.noteUnreadable()
                return true
            }
        ) else {
            state.noteUnreadable()
            return []
        }

        var candidates: [URL] = []
        var seen = 0

        while let entry = enumerator.nextObject() as? URL {
            seen += 1
            if seen % cancellationCheckInterval == 0, state.isCancelled {
                throw CancellationError()
            }

            let path = entry.path
            if skipPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                state.noteUnreadable()
                continue
            }

            // Symlinks are not followed: a linked build folder would otherwise report
            // the same disk image under two paths.
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if entry.pathComponents.count - rootDepth >= maximumSearchDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  largeFileExtensions.contains(entry.pathExtension.lowercased())
            else { continue }

            let approximateBytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if approximateBytes >= Threshold.largeArchive { candidates.append(entry) }
        }
        return candidates
    }

    private static let largeFileExtensions = diskImageExtensions.union(archiveExtensions)

    private static func kind(for url: URL) -> FileEntry.Kind {
        diskImageExtensions.contains(url.pathExtension.lowercased()) ? .diskImage : .archive
    }

    // MARK: - Entry construction

    /// Entries plus the tally of what could not be read.
    private struct Found {
        var entries: [FileEntry] = []
        var unreadableCount = 0
    }

    private func url(_ components: [String]) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1) }
    }

    private func measureAndAppend(
        _ url: URL,
        kind: FileEntry.Kind,
        minimumBytes: Int64,
        isRegenerable: Bool = false,
        context: ScanContext,
        to found: inout Found
    ) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let lastOpened = lastOpenedDate(for: url)
        // Checked before measuring as well as before emitting: an excluded root is
        // not worth walking. Recency is not exclusion — it becomes a badge below.
        guard !context.isExcluded(url) else { return }

        let measurement = try await context.measurer.measure(url)
        append(url, kind: kind, measurement: measurement, lastOpened: lastOpened,
               minimumBytes: minimumBytes, isRegenerable: isRegenerable,
               context: context, to: &found)
    }

    /// Records a measurement that has already been taken.
    ///
    /// The protocol's `makeEntry(url:kind:context:isRegenerable:)` does the same job
    /// but discards `SizeMeasurement.unreadableCount`. This category reaches into the
    /// Trash, iOS backups and Mail — the places a run without Full Disk Access cannot
    /// read — so that count is precisely what must survive.
    private func append(
        _ url: URL,
        kind: FileEntry.Kind,
        measurement: SizeMeasurement,
        lastOpened: Date?,
        minimumBytes: Int64,
        isRegenerable: Bool = false,
        context: ScanContext,
        to found: inout Found
    ) {
        // Counted even when the entry is dropped below: a folder that measured zero
        // *because* it could not be read is the case this number exists for.
        found.unreadableCount += measurement.unreadableCount

        guard measurement.allocatedBytes >= minimumBytes else { return }
        guard !context.isExcluded(url) else { return }
        // See `SizeMeasurement.containsProtectedPattern`.
        guard !measurement.containsProtectedPattern else { return }

        found.entries.append(FileEntry(
            url: url,
            kind: kind,
            allocatedBytes: measurement.allocatedBytes,
            lastOpened: lastOpened,
            isRegenerable: isRegenerable,
            // Information, not a veto — see `ScanContext.protectRecentDays`.
            protectionReason: context.isRecencyProtected(lastOpened) ? .recentUse : nil,
            childCount: (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
        ))
    }
}

// MARK: - Support

/// Bridges structured-concurrency cancellation into the detached archive sweep and
/// gives the enumerator's `@Sendable` error handler somewhere safe to record what it
/// could not read.
private final class WalkState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    private var unreadable = 0

    func cancel() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelledFlag
    }

    func noteUnreadable() {
        lock.lock(); unreadable += 1; lock.unlock()
    }

    var unreadableCount: Int {
        lock.lock(); defer { lock.unlock() }; return unreadable
    }
}
