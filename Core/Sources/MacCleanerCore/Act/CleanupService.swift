import Foundation

/// What a cleanup actually did.
public struct CleanupOutcome: Sendable, Equatable {

    /// The sum of what each item measured immediately before it was removed.
    ///
    /// **An upper bound, not a promise.** APFS clones share blocks between distinct
    /// files and no per-file API can see that sharing, so two 16 MB clones measure
    /// 32 MB while removing both recovers 16 MB. The same applies to any
    /// content-addressable store built on `clonefile` — a pnpm or Homebrew cache
    /// frees less than the sum of its entries. There is no correction to apply here:
    /// the only honest number available per file is its allocated size, and the
    /// figure this reports is exactly the one ``AllocatedSizeMeasurer`` documents as
    /// an upper bound. Volume free space is the authority on what was reclaimed.
    public var freedBytes: Int64
    public var removedCount: Int
    /// Paths that could not be removed. Reported rather than swallowed so the sheet
    /// can say "freed 3.2 GB, 2 items could not be removed" instead of claiming a
    /// clean run.
    public var failed: [String]

    public init(freedBytes: Int64 = 0, removedCount: Int = 0, failed: [String] = []) {
        self.freedBytes = freedBytes
        self.removedCount = removedCount
        self.failed = failed
    }
}

/// Removes selected entries, to the Trash or permanently.
///
/// Every removal is measured first and logged after, which is what separates this
/// from the predecessor's cleanup: that one summed the sizes recorded during the
/// scan, so a cache that had been rebuilt since the scan was reported as freed
/// anyway, and nothing was written down afterwards — leaving no record of what the
/// app had done to the user's disk.
public struct CleanupService: Sendable {

    private let measurer: AllocatedSizeMeasurer
    private let log: RemovalLog

    public init(
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer(),
        log: RemovalLog = RemovalLog()
    ) {
        self.measurer = measurer
        self.log = log
    }

    /// - Parameters:
    ///   - entries: what to remove. An entry's `children` go with it.
    ///   - trashFirst: Preferences › General "Always move to Trash". Some categories
    ///     insist on it regardless — see ``alwaysMovesToTrash(_:)``.
    /// - Parameter privilegedFallback: whether a permission-denied removal may be
    ///   retried with an administrator prompt. Off by default so no headless caller
    ///   (tests, the CLI) can ever raise a password dialog; the app opts in.
    public func remove(
        entries: [FileEntry],
        trashFirst: Bool,
        privilegedFallback: Bool = false
    ) async throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        // Targets refused for lack of permission, retried below in one privileged
        // pass. App Store installs (iMovie, Pages) are owned by root:wheel, so an
        // unprivileged `trashItem` cannot touch them even though Finder can, via
        // exactly the admin prompt this fallback raises.
        var privileged: [FileEntry] = []

        for entry in entries {
            // Between entries, never mid-item: a half-removed app bundle is worse
            // than one more removal after the user pressed stop.
            try Task.checkCancellation()

            // Belt and braces beneath the UI's locked checkboxes: a locked entry
            // (running app, user data) is refused here too, and lands in `failed`
            // so the refusal is reported rather than silently absorbed. Recent use
            // does not lock: it is information for the user, not a veto.
            if entry.isRemovalLocked {
                outcome.failed.append(entry.url.path)
                continue
            }

            let disposition: RemovalDisposition =
                (trashFirst || Self.alwaysMovesToTrash(entry)) ? .trashed : .deleted

            var succeeded: [FileEntry] = []
            // Children before the bundle: an app's caches, containers and preferences
            // are useless once the bundle is gone, and removing the bundle first would
            // orphan them behind a row that has already disappeared from the table.
            for target in entry.children + [entry] {
                // Measured now rather than trusting the scan's figure, which may be
                // hours old. The measurer throws nothing but `CancellationError`, so
                // letting this propagate does not turn an unreadable file into an
                // aborted batch.
                let measured = try await measurer.measure(target.url).allocatedBytes

                do {
                    try Self.discard(target.url, disposition: disposition)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone: someone else removed it since the scan. That is
                    // the outcome the user wanted, not a failure — reporting it as
                    // one would keep a ghost row alive for a file that is not there.
                    _ = error
                    continue
                } catch {
                    if privilegedFallback, Self.isPermissionDenied(error) {
                        var queued = target
                        queued.allocatedBytes = measured
                        privileged.append(queued)
                    } else {
                        // One unremovable file must not cost the user the rest of
                        // the batch. The predecessor's cleanup stopped at the first
                        // error and left the remaining selection untouched.
                        outcome.failed.append(target.url.path)
                    }
                    continue
                }

                outcome.freedBytes += measured
                outcome.removedCount += 1

                var record = target
                record.allocatedBytes = measured
                succeeded.append(record)
            }

            // Written per entry rather than once at the end, so a cancelled run leaves
            // no trashed item without the log line its Put Back depends on.
            //
            // A failed write is not promoted to a removal failure: the bytes are
            // already gone, and reporting a successful removal as failed would be a
            // lie in the other direction. The cost is that those items lose Put Back,
            // which is the state every item the app did not trash is in anyway.
            try? log.append(entries: succeeded, disposition: disposition)
        }

        if !privileged.isEmpty {
            await Self.removeWithPrivileges(privileged, log: log, outcome: &outcome)
        }

        return outcome
    }

    // MARK: - Privileged fallback

    /// True for the errors an admin retry can actually cure.
    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain
            && (underlying?.code == 1 || underlying?.code == 13)   // EPERM, EACCES
    }

    /// Moves root-owned items to the user's Trash with admin rights, in one batch so
    /// the password prompt appears once. The items are chowned to the user
    /// afterwards, or the Trash would inherit files that emptying cannot remove.
    /// A declined prompt fails every queued item, honestly.
    private static func removeWithPrivileges(
        _ targets: [FileEntry],
        log: RemovalLog,
        outcome: inout CleanupOutcome
    ) async {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        let user = NSUserName()

        func shellQuoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var moves: [String] = []
        var destinations: [String] = []
        for target in targets {
            var destination = trash.appendingPathComponent(target.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                destination = trash.appendingPathComponent(
                    "\(target.url.deletingPathExtension().lastPathComponent) \(stamp)"
                ).appendingPathExtension(target.url.pathExtension)
            }
            moves.append("mv \(shellQuoted(target.url.path)) \(shellQuoted(destination.path))")
            destinations.append(destination.path)
        }
        let script = (moves + ["/usr/sbin/chown -R \(shellQuoted(user)) "
            + destinations.map(shellQuoted).joined(separator: " ")])
            .joined(separator: " && ")
        do {
            try await PrivilegedShell.run(script)
            for target in targets {
                outcome.freedBytes += target.allocatedBytes
                outcome.removedCount += 1
            }
            try? log.append(entries: targets, disposition: .trashed)
        } catch {
            outcome.failed.append(contentsOf: targets.map(\.url.path))
        }
    }

    // MARK: - Disposition

    /// `FileEntry` does not carry the category it came from, and cleanup needs
    /// exactly one category-level rule: ``CategoryID/alwaysMovesToTrash``.
    /// Applications is the only category that sets it, and `.appBundle` is the only
    /// kind ``ApplicationsScanner`` emits, so the kind stands in for the category
    /// while the rule itself is still read from `CategoryID` rather than restated
    /// here. A bundle's children inherit the bundle's disposition, since they are
    /// removed as part of it.
    static func alwaysMovesToTrash(_ entry: FileEntry) -> Bool {
        entry.kind == .appBundle && CategoryID.applications.alwaysMovesToTrash
    }

    private static func discard(_ url: URL, disposition: RemovalDisposition) throws {
        switch disposition {
        case .trashed:
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .deleted:
            try FileManager.default.removeItem(at: url)
        }
    }
}
