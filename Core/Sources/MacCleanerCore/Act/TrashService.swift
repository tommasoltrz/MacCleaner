import Foundation

/// One thing sitting in the Trash.
public struct TrashItem: Sendable, Identifiable, Equatable {
    /// The path inside the Trash, which is also the row's selection identity.
    public var id: String
    public var url: URL
    public var name: String
    public var bytes: Int64
    /// When it landed in the Trash, from `.addedToDirectoryDateKey`. `nil` renders as
    /// a row with no "Deleted n days ago" caption rather than an invented date.
    public var deletedAt: Date?
    /// Whether the Put Back button is enabled — see the policy note on ``TrashService``.
    public var canPutBack: Bool

    /// Public so views can build preview fixtures without a Trash on disk.
    public init(
        url: URL,
        name: String? = nil,
        bytes: Int64,
        deletedAt: Date? = nil,
        canPutBack: Bool = false
    ) {
        self.id = url.path
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.bytes = bytes
        self.deletedAt = deletedAt
        self.canPutBack = canPutBack
    }
}

/// The Trash screen's header figures plus the rows it shows.
///
/// `totalBytes` and `itemCount` describe the whole Trash; `items` is only the
/// largest few, which is why the design's footer reads "214 items · 8.42 GB ·
/// showing the 4 largest". Measuring everything and listing everything are separate
/// decisions.
public struct TrashSummary: Sendable, Equatable {
    public var totalBytes: Int64
    public var itemCount: Int
    /// Largest first, capped at the requested limit.
    public var items: [TrashItem]

    public init(totalBytes: Int64 = 0, itemCount: Int = 0, items: [TrashItem] = []) {
        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.items = items
    }
}

public enum TrashError: Error, Equatable {
    /// Nothing in ``RemovalLog`` records where this item came from.
    case putBackUnavailable(String)
    /// Something already occupies the original path.
    case destinationOccupied(String)
    /// The Trash exists but macOS refused to let this process read it — in practice,
    /// Full Disk Access has not been granted. Distinct from an empty Trash.
    case unreadable(String)
}

/// Reads, empties and restores `~/.Trash`.
///
/// ### Nothing here scripts Finder
///
/// "Empty Trash" is one AppleScript line away, and the predecessor used it. Sending
/// Finder an Apple event makes macOS raise an Automation consent prompt naming
/// another app — a dialog that is indistinguishable from malware behaviour to a user
/// who just clicked a button in *this* app, and one that permanently disables the
/// feature if they decline. Removing the Trash's contents through `FileManager`
/// needs no consent beyond the files already being the user's own.
///
/// ### Why Put Back has no public API
///
/// Finder's Put Back works because Finder itself wrote down where each item came
/// from, in a private record it does not publish; macOS exposes no API for reading a
/// trashed item's original location. The two ways to reach it are both refused here:
/// scripting Finder brings back the Automation prompt above, and reverse-engineering
/// its private store would break on any macOS release.
///
/// So MacCleaner restores only what MacCleaner trashed. ``RemovalLog`` already
/// records the original path of everything this app removes, and that record is the
/// entire basis for Put Back: `canPutBack` is true only where a logged `trashed`
/// removal matches the item, and ``putBack(_:)`` resolves the destination from the
/// same log. For an item the user dragged in from Finder there is no entry, the flag
/// stays false, and the UI disables the button — which is the honest outcome. An
/// enabled button that cannot know where the file belongs would either guess or
/// fail, and both are worse than being told up front that Finder owns this one.
///
/// Matching is by file name, because that is what survives the move into the Trash.
/// When macOS renames on a collision — a second `Report.pdf` becoming
/// `Report 2.pdf` — the names no longer agree and the item is treated as
/// unrecoverable rather than restored over the top of an unrelated file.
public struct TrashService: Sendable {

    private let home: URL
    private let log: RemovalLog
    private let measurer: AllocatedSizeMeasurer

    /// `home` is injectable for the same reason ``HiddenDataScanner``'s is: so tests
    /// exercise a Trash of their own instead of the user's.
    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        log: RemovalLog = RemovalLog(),
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer()
    ) {
        self.home = home
        self.log = log
        self.measurer = measurer
    }

    public var trashURL: URL {
        home.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Every Trash Finder folds into the one it shows: the user's own, each mounted
    /// volume's, and iCloud Drive's. Items admin-deleted from /Applications land in
    /// a volume trash and iCloud deletions in CloudDocs, which is how files can sit
    /// in Finder's Trash while `~/.Trash` reads empty.
    private func trashDirectories() -> [URL] {
        var directories = [trashURL]

        let cloudTrash = home.appendingPathComponent(
            "Library/Mobile Documents/.Trash", isDirectory: true
        )
        if FileManager.default.fileExists(atPath: cloudTrash.path) {
            directories.append(cloudTrash)
        }

        // Volume trashes are only meaningful for the real user. With an injected
        // test home, `url(for: .trashDirectory, appropriateFor:)` would resolve to
        // the *actual* user's Trash and leak real files into an isolated fixture —
        // which is exactly how the test suite caught this.
        guard home.path == NSHomeDirectory() else { return directories }

        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            if let trash = try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask,
                appropriateFor: volume, create: false
            ), !directories.contains(where: { $0.path == trash.path }) {
                directories.append(trash)
            }
        }
        return directories
    }

    /// How far back Put Back looks. Far enough to cover any Trash the user has not
    /// emptied in months, short of parsing a log that has been growing for years.
    private static let putBackLookback = 5_000

    // MARK: - Reading

    /// - Parameter limit: how many rows to return. The totals always cover the whole
    ///   Trash regardless of it.
    public func summary(limit: Int = 50) async throws -> TrashSummary {
        // This is the user's real `~/.Trash` — the same one Finder shows. Reading it
        // is TCC-gated, so a denial must THROW rather than collapse to an empty
        // listing: "the Trash is empty" and "the app is not allowed to look" are
        // different facts, and rendering the second as the first is the same lie the
        // old `du`-based scanner told about unreadable folders.
        var contents: [URL] = []
        for directory in trashDirectories() {
            do {
                contents += try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.addedToDirectoryDateKey],
                    // Hidden entries are included: a trashed dotfile is a trashed
                    // item, and silently dropping it would make the totals disagree
                    // with the disk.
                    options: []
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch where directory.path == trashURL.path {
                // Only the user's own Trash being denied is the Full Disk Access
                // signal; a secondary location that refuses is skipped rather than
                // blanking the whole screen.
                throw TrashError.unreadable(trashURL.path)
            } catch {
                continue
            }
        }

        let restorable = originalPaths()
        var items: [TrashItem] = []
        var totalBytes: Int64 = 0

        for url in contents {
            try Task.checkCancellation()
            // Finder metadata, recreated whenever Finder shows the Bin. Listing it
            // makes every "Empty" look like it missed one file. Finder hides it;
            // so do we. `empty()` still removes it.
            if url.lastPathComponent == ".DS_Store" { continue }
            let bytes = try await measurer.measure(url).allocatedBytes
            totalBytes += bytes
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey])
            items.append(TrashItem(
                url: url,
                bytes: bytes,
                deletedAt: values?.addedToDirectoryDate,
                canPutBack: restorable[url.lastPathComponent] != nil
            ))
        }

        items.sort { $0.bytes > $1.bytes }
        return TrashSummary(
            totalBytes: totalBytes,
            itemCount: items.count,
            items: Array(items.prefix(max(0, limit)))
        )
    }

    // MARK: - Emptying

    /// Removes the Trash's *contents* and returns the bytes that went with them.
    ///
    /// The folder itself stays: macOS expects `~/.Trash` to exist and recreating it
    /// with the wrong owner or mode is a worse outcome than leaving it in place.
    ///
    /// An item that refuses to go — a locked file, something a running process still
    /// holds — is skipped rather than aborting, so one stuck file cannot leave the
    /// rest of the Trash behind. Its bytes are simply not counted, which keeps the
    /// returned figure a report of what actually happened.
    @discardableResult
    public func empty(privilegedFallback: Bool = false) async throws -> (freedBytes: Int64, skipped: Int) {
        let fileManager = FileManager.default
        // A denied listing must throw, exactly as in `summary()`. The earlier `try?`
        // here read a Trash the app was not allowed to see as an empty one, removed
        // nothing, and reported "Reclaimed 0 B" as if that were success.
        var contents: [URL] = []
        for directory in trashDirectories() {
            do {
                contents += try fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: []
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch where directory.path == trashURL.path {
                throw TrashError.unreadable(trashURL.path)
            } catch {
                continue
            }
        }

        var freedBytes: Int64 = 0
        var skipped = 0
        // Finder's admin-delete keeps root ownership, so an unprivileged remove of
        // such an item gets EPERM. Queued and erased in one admin pass, so the
        // password prompt appears once however many items are stuck.
        var stuck: [(url: URL, bytes: Int64)] = []
        for url in contents {
            try Task.checkCancellation()
            // Measured first, because after the removal there is nothing left to ask.
            let bytes = try await measurer.measure(url).allocatedBytes
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                if privilegedFallback, PrivilegedShell.isPermissionDenied(error) {
                    stuck.append((url, bytes))
                } else {
                    skipped += 1
                }
                continue
            }
            freedBytes += bytes
        }

        if !stuck.isEmpty {
            let script = stuck
                .map { "rm -rf \(PrivilegedShell.shellQuoted($0.url.path))" }
                .joined(separator: " && ")
            do {
                try await PrivilegedShell.run(script)
                freedBytes += stuck.reduce(0) { $0 + $1.bytes }
            } catch {
                // A declined prompt fails every queued item, honestly.
                skipped += stuck.count
            }
        }
        return (freedBytes, skipped)
    }

    // MARK: - Put Back

    /// Restores an item to the path ``RemovalLog`` recorded for it.
    public func putBack(_ item: TrashItem) async throws {
        guard let originalPath = originalPaths()[item.name] else {
            throw TrashError.putBackUnavailable(item.id)
        }
        let destination = URL(fileURLWithPath: originalPath)

        let fileManager = FileManager.default
        // Never overwrite: something else at that path is the user's current file,
        // and a restore is not worth a silent replacement.
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw TrashError.destinationOccupied(destination.path)
        }
        // The parent may have gone in the same cleanup — an app's leftovers outlive
        // the folder they sat in — so it is recreated rather than failing the restore.
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: item.url, to: destination)
    }

    /// Trash file name → the path it came from, most recent removal winning.
    ///
    /// Only `trashed` removals qualify. A `deleted` one left nothing to put back, and
    /// treating its record as a restore target would offer to recover a file that no
    /// longer exists.
    private func originalPaths() -> [String: String] {
        var byName: [String: String] = [:]
        // `recentEntries` is newest first, so the first sighting of a name is the one
        // that matters and later, older duplicates are ignored.
        for record in log.recentEntries(limit: Self.putBackLookback)
        where record.disposition == .trashed {
            let name = URL(fileURLWithPath: record.originalPath).lastPathComponent
            if byName[name] == nil { byName[name] = record.originalPath }
        }
        return byName
    }
}
