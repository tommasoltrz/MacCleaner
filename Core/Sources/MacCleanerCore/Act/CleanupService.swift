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
    /// The split behind `removedCount`, because the two halves make different
    /// promises: a trashed item can come back, a deleted one cannot, and the
    /// completion message must not say "undo" over bytes that are already gone.
    public var trashedCount: Int
    public var deletedCount: Int
    /// Paths that could not be removed. Reported rather than swallowed so the sheet
    /// can say "freed 3.2 GB, 2 items could not be removed" instead of claiming a
    /// clean run.
    public var failed: [String]
    /// Paths that failed because macOS denied access.
    public var permissionDenied: [String]

    public init(
        freedBytes: Int64 = 0,
        removedCount: Int = 0,
        failed: [String] = [],
        permissionDenied: [String] = [],
        trashedCount: Int = 0,
        deletedCount: Int = 0
    ) {
        self.freedBytes = freedBytes
        self.removedCount = removedCount
        self.failed = failed
        self.permissionDenied = permissionDenied
        self.trashedCount = trashedCount
        self.deletedCount = deletedCount
    }

    public mutating func merge(_ other: CleanupOutcome) {
        freedBytes += other.freedBytes
        removedCount += other.removedCount
        trashedCount += other.trashedCount
        deletedCount += other.deletedCount
        failed.append(contentsOf: other.failed)
        permissionDenied.append(contentsOf: other.permissionDenied)
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
    /// - Parameter keepReceipt: the sheet's "Keep a Put Back receipt" checkbox. Off
    ///   means nothing is written to the removal log — no paths, no destinations —
    ///   and so nothing from this run can be Put Back. That is the trade the user
    ///   chose; silently logging anyway would make the checkbox a lie.
    /// - Parameter userDataRemovalOverrides: protected user-data rows the user
    ///   explicitly unlocked after seeing the destructive warning. Running apps and
    ///   tool-managed rows remain refused even if their IDs appear here.
    /// - Parameter appDataRemovalOverrides: selected application bundles with an
    ///   explicit authorization to include protected related data. Without the exact
    ///   parent ID, cleanup removes the bundle and regenerable children but preserves
    ///   profiles, preferences, containers and other non-regenerable children.
    /// - Parameter expectedIdentities: reviewed identities that must still match.
    public func remove(
        entries: [FileEntry],
        trashFirst: Bool,
        privilegedFallback: Bool = false,
        keepReceipt: Bool = true,
        userDataRemovalOverrides: Set<FileEntry.ID> = [],
        appDataRemovalOverrides: Set<FileEntry.ID> = [],
        expectedIdentities: [FileEntry.ID: String] = [:]
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

            // Belt and braces beneath the UI's locks: a running app, tool-managed
            // row, or user-data row without its exact override is refused here too,
            // and lands in `failed` so the refusal is reported rather than silently
            // absorbed. Recent use is information for the user, not a veto.
            if !Self.removalAllowed(entry, userDataRemovalOverrides: userDataRemovalOverrides) {
                outcome.failed.append(entry.url.path)
                continue
            }

            let disposition: RemovalDisposition =
                (trashFirst || Self.alwaysMovesToTrash(entry)) ? .trashed : .deleted

            var succeeded: [RemovalRecord] = []
            // Children before the bundle. For an app this list is deliberately
            // narrower unless the parent has its exact destructive override:
            // caches go with the app, profiles and settings stay by default.
            for target in Self.removalTargets(
                for: entry,
                removeProtectedAppData: appDataRemovalOverrides.contains(entry.id)
            ) {
                if let expected = expectedIdentities[target.id],
                   FileIdentity.of(target.url) != expected {
                    outcome.failed.append(target.url.path)
                    continue
                }
                // Measured now rather than trusting the scan's figure, which may be
                // hours old. The measurer throws nothing but `CancellationError`, so
                // letting this propagate does not turn an unreadable file into an
                // aborted batch.
                let measured = try await measurer.measure(target.url).allocatedBytes

                if let expected = expectedIdentities[target.id],
                   FileIdentity.of(target.url) != expected {
                    outcome.failed.append(target.url.path)
                    continue
                }

                let landed: URL?
                do {
                    landed = try Self.discard(target.url, disposition: disposition)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone: someone else removed it since the scan. That is
                    // the outcome the user wanted, not a failure — reporting it as
                    // one would keep a ghost row alive for a file that is not there.
                    _ = error
                    continue
                } catch {
                    let permissionDenied = Self.isPermissionDenied(error)
                    if privilegedFallback, permissionDenied,
                       !Self.requiresAppDataAuthorization(target.url) {
                        var queued = target
                        queued.allocatedBytes = measured
                        privileged.append(queued)
                    } else {
                        // One unremovable file must not cost the user the rest of
                        // the batch. The predecessor's cleanup stopped at the first
                        // error and left the remaining selection untouched.
                        outcome.failed.append(target.url.path)
                        if permissionDenied {
                            outcome.permissionDenied.append(target.url.path)
                        }
                    }
                    continue
                }

                outcome.freedBytes += measured
                outcome.removedCount += 1
                if disposition == .trashed { outcome.trashedCount += 1 }
                else { outcome.deletedCount += 1 }

                succeeded.append(RemovalRecord(
                    timestamp: Date(),
                    originalPath: target.url.path,
                    bytes: measured,
                    disposition: disposition,
                    trashedPath: landed?.path,
                    // Read now, while the item is certainly the one just trashed.
                    trashedIdentity: landed.flatMap(FileIdentity.of)
                ))
            }

            // Written per entry rather than once at the end, so a cancelled run leaves
            // no trashed item without the log line its Put Back depends on.
            //
            // A failed write is not promoted to a removal failure: the bytes are
            // already gone, and reporting a successful removal as failed would be a
            // lie in the other direction. The cost is that those items lose Put Back,
            // which is the state every item the app did not trash is in anyway.
            if keepReceipt { try? log.append(succeeded) }
        }

        if !privileged.isEmpty {
            await Self.removeWithPrivileges(
                privileged, log: keepReceipt ? log : nil, outcome: &outcome
            )
        }

        return outcome
    }

    /// Executes a dedicated application uninstall plan.
    ///
    /// This path intentionally differs from aggregate cleanup in one crucial way:
    /// the application bundle moves first. If that move fails or the administrator
    /// prompt is cancelled, no cache, preference, profile, or helper is touched.
    /// Once the bundle is safely in the Trash, each reviewed related item follows
    /// independently and any survivor is reported in ``CleanupOutcome/failed``.
    /// Every item always goes to the Trash, regardless of the global cleanup
    /// preference.
    public func uninstall(
        _ plan: AppUninstallPlan,
        privilegedFallback: Bool = false,
        keepReceipt: Bool = true
    ) async throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard plan.managedPackage == nil else {
            // Trashing only a cask's app artifact leaves Homebrew's package receipt
            // inconsistent. A future delegated workflow must remove both together;
            // this direct filesystem path deliberately refuses to split them.
            outcome.failed = [plan.applicationURL.path]
            return outcome
        }
        var failedSubtrees = Set<String>()
        let removalOrder = plan.removalOrder()
        guard !removalOrder.isEmpty else { return outcome }

        func recordFailure(_ item: AppUninstallPlan.Item) {
            failedSubtrees.insert(item.url.path)
            if !outcome.failed.contains(item.url.path) {
                outcome.failed.append(item.url.path)
            }
        }

        // Re-run the ownership oracle immediately before removal. A second copy may
        // have been installed while the review sheet was open; its shared data then
        // stops being ours to remove, even though it was valid at scan time.
        let exclusiveBundleIdentifiers = AppUninstallPlanner.exclusiveBundleIdentifiers(
            candidates: plan.candidateBundleIdentifiers,
            selectedApplication: plan.applicationURL,
            applicationRoots: plan.applicationRoots
        )

        for (index, item) in removalOrder.enumerated() {
            try Task.checkCancellation()
            // A planned containing folder must not smuggle through a descendant
            // that just failed its own identity, ownership, or permission check.
            // Leave the whole subtree where it is and report both review rows.
            if failedSubtrees.contains(where: {
                $0.hasPrefix(item.url.path + "/")
            }) {
                recordFailure(item)
                continue
            }
            guard AppUninstallPlanner.removalIsStillSafe(
                item, in: plan, exclusiveBundleIdentifiers: exclusiveBundleIdentifiers
            ) else {
                recordFailure(item)
                // The bundle is the transaction gate. Nothing related moves when
                // the app itself no longer matches the reviewed plan.
                if index == 0 { return outcome }
                continue
            }

            let measured = try await measurer.measure(item.url).allocatedBytes
            do {
                let landed = try Self.discard(item.url, disposition: .trashed)
                outcome.freedBytes += measured
                outcome.removedCount += 1
                outcome.trashedCount += 1
                if keepReceipt {
                    try? log.append([RemovalRecord(
                        timestamp: Date(),
                        originalPath: item.url.path,
                        bytes: measured,
                        disposition: .trashed,
                        trashedPath: landed?.path,
                        trashedIdentity: landed.flatMap(FileIdentity.of)
                    )])
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Finder or an updater removed it after planning. For the app bundle
                // this still opens the gate: the requested state has been reached.
                _ = error
                continue
            } catch {
                guard privilegedFallback, Self.isPermissionDenied(error) else {
                    recordFailure(item)
                    if index == 0 { return outcome }
                    continue
                }

                var privilegedEntry = item.fileEntry
                privilegedEntry.allocatedBytes = measured
                let removedBefore = outcome.removedCount
                await Self.removeWithPrivileges(
                    [privilegedEntry], log: keepReceipt ? log : nil, outcome: &outcome
                )
                if outcome.removedCount == removedBefore {
                    recordFailure(item)
                    if index == 0 { return outcome }
                }
            }
        }

        return outcome
    }

    /// Moves selected application leftovers to the Trash after a second owner check.
    public func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan,
        bundleIdentifiers: Set<String>,
        itemPaths: Set<String>? = nil,
        registeredApplicationBundleIdentifiers: Set<String> = [],
        privilegedFallback: Bool = false,
        keepReceipt: Bool = true
    ) async throws -> CleanupOutcome {
        var installed = AppUninstallPlanner.installedBundleIdentifiers(
            in: plan.applicationRoots
        )
        installed.formUnion(registeredApplicationBundleIdentifiers)
        let selected = plan.items(for: bundleIdentifiers, itemPaths: itemPaths)
        var outcome = CleanupOutcome()
        var safeEntries: [FileEntry] = []

        for item in selected {
            try Task.checkCancellation()
            guard OrphanedAppLeftoverPlan.removalIsStillSafe(
                item, in: plan, installedBundleIdentifiers: installed
            ) else {
                outcome.failed.append(item.url.path)
                continue
            }
            safeEntries.append(item.fileEntry)
        }

        guard !safeEntries.isEmpty else { return outcome }
        let removed = try await remove(
            entries: safeEntries,
            trashFirst: true,
            privilegedFallback: privilegedFallback,
            keepReceipt: keepReceipt,
            userDataRemovalOverrides: Set(safeEntries.map(\.id))
        )
        outcome.merge(removed)
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

    /// An administrator cannot override the privacy decision for another app's
    /// sandbox data. macOS must authorize the signed MacCleaner application.
    private static func requiresAppDataAuthorization(_ url: URL) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        return ["Containers", "Group Containers"].contains { name in
            let root = library.appendingPathComponent(name, isDirectory: true)
                .standardizedFileURL.path
            let path = url.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// Moves root-owned items to the user's Trash with admin rights, in one batch so
    /// the password prompt appears once. The items are chowned to the user
    /// afterwards, or the Trash would inherit files that emptying cannot remove.
    /// A declined prompt fails every queued item, honestly.
    ///
    /// Every move stands alone. Chaining them with `&&` meant one failure abandoned
    /// the rest *and* reported the items already moved as failures, leaving them in
    /// the Trash with no receipt and so no Put Back. Each item now runs guarded by
    /// its own `[ ! -e ]` test — `mv` would otherwise overwrite a file or nest a
    /// directory inside an existing one — and prints a marker only when it really
    /// moved. The script always exits 0; what happened is read from the markers,
    /// never from the exit status.
    ///
    /// Destinations are also reserved as they are planned, so two items with the
    /// same basename cannot be handed the same path.
    private static func removeWithPrivileges(
        _ targets: [FileEntry],
        log: RemovalLog?,
        outcome: inout CleanupOutcome
    ) async {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        let user = NSUserName()

        func shellQuoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        var statements: [String] = []
        var destinations: [String] = []
        var reserved: Set<String> = []
        for (index, target) in targets.enumerated() {
            let destination = Self.freeTrashPath(
                for: target.url, in: trash, reserved: &reserved
            )
            destinations.append(destination.path)
            let quoted = shellQuoted(destination.path)
            // `-e` follows symlinks, so a dangling link at the destination reads as
            // absent and `mv` would quietly replace it; `-L` catches it.
            //
            // The marker is printed the moment the move succeeds, before the chown.
            // Reporting them together meant a failed chown described a file that had
            // already moved into the Trash as "could not be removed" — and wrote it
            // no receipt, so it could not be put back either. Ownership is a repair
            // to the Trash, not part of whether the item went.
            statements.append(
                "if [ ! -e \(quoted) ] && [ ! -L \(quoted) ]; then"
                + " if mv \(shellQuoted(target.url.path)) \(quoted); then"
                + " echo \(Self.moveMarker)\(index);"
                + " /usr/sbin/chown -R \(shellQuoted(user)) \(quoted) || true;"
                + " fi; fi"
            )
        }
        // `; ` between statements, and a final `exit 0`: one item's failure must
        // not abandon the batch, and the exit status is not the report.
        let script = (statements + ["exit 0"]).joined(separator: "; ")
        let output: String
        do {
            output = try await PrivilegedShell.run(script)
        } catch {
            // Declined prompt, or the shell never ran: nothing moved.
            outcome.failed.append(contentsOf: targets.map(\.url.path))
            outcome.permissionDenied.append(contentsOf: targets.map(\.url.path))
            return
        }

        let moved = Set(output.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(Self.moveMarker) else { return nil }
            return Int(trimmed.dropFirst(Self.moveMarker.count))
        })

        var records: [RemovalRecord] = []
        for (index, target) in targets.enumerated() {
            guard moved.contains(index) else {
                // Every item here was queued *because* the unprivileged attempt
                // was denied. Root failing too means the denial is a privacy
                // decision, not ownership — the one remedy is the access alert,
                // which fires only for paths listed as permission-denied.
                outcome.failed.append(target.url.path)
                outcome.permissionDenied.append(target.url.path)
                continue
            }
            outcome.freedBytes += target.allocatedBytes
            outcome.removedCount += 1
            outcome.trashedCount += 1
            let destination = destinations[index]
            records.append(RemovalRecord(
                timestamp: Date(),
                originalPath: target.url.path,
                bytes: target.allocatedBytes,
                disposition: .trashed,
                trashedPath: destination,
                trashedIdentity: FileIdentity.of(URL(fileURLWithPath: destination))
            ))
        }
        // Receipts for exactly what moved — never for an item that stayed put, and
        // never withheld from one that went.
        if !records.isEmpty { try? log?.append(records) }
    }

    // MARK: - Disposition

    /// The concrete paths one selected row will remove.
    ///
    /// Non-application aggregates retain their original all-children semantics. An
    /// application is different: its non-regenerable children are user state, so
    /// they survive unless that exact app has explicit complete-removal authorization.
    /// A running or tool-managed child is never smuggled through by the parent.
    public static func removalTargets(
        for entry: FileEntry,
        removeProtectedAppData: Bool
    ) -> [FileEntry] {
        guard entry.kind == .appBundle else { return entry.children + [entry] }

        let children = entry.children.filter { child in
            if child.manualRemoval != nil || child.protectionReason == .running {
                return false
            }
            return child.isRegenerable || removeProtectedAppData
        }
        return children + [entry]
    }

    /// The service-side gate beneath the UI. Only a user-data lock can be
    /// deliberately overridden; a running process or a tool-managed aggregate is a
    /// real inability to remove the row safely, not merely a caution.
    static func removalAllowed(
        _ entry: FileEntry,
        userDataRemovalOverrides: Set<FileEntry.ID>
    ) -> Bool {
        if entry.manualRemoval != nil || entry.protectionReason == .running { return false }
        if entry.protectionReason == .userData {
            return userDataRemovalOverrides.contains(entry.id)
        }
        return true
    }

    /// `FileEntry` does not carry the category it came from, and cleanup needs
    /// two conservative rules: applications follow
    /// ``CategoryID/alwaysMovesToTrash``, and an individually unlocked user-data row
    /// always gets the same recovery path. A bundle's children inherit the bundle's
    /// disposition, since they are removed as part of it.
    public static func alwaysMovesToTrash(_ entry: FileEntry) -> Bool {
        (entry.kind == .appBundle && CategoryID.applications.alwaysMovesToTrash)
            || entry.protectionReason == .userData
    }

    /// Printed by the privileged script for each item that really moved.
    private static let moveMarker = "MacCleaner-moved:"

    /// A path in the Trash that is free on disk *and* not already promised to
    /// another item in this batch. `Report.pdf`, `Report 2.pdf`, `Report 3.pdf`…,
    /// which is also what Finder does.
    static func freeTrashPath(
        for source: URL, in trash: URL, reserved: inout Set<String>
    ) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func candidate(_ suffix: String) -> URL {
            let name = base + suffix
            let url = trash.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var attempt = candidate("")
        var counter = 2
        // `lstat`, not `fileExists`: the latter follows symlinks, so a dangling
        // link in the Trash looked like a free name and the move would have
        // replaced it.
        func occupied(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        while reserved.contains(attempt.path) || occupied(attempt) {
            attempt = candidate(" \(counter)")
            counter += 1
        }
        reserved.insert(attempt.path)
        return attempt
    }

    /// Returns where a trashed item landed; `nil` for a permanent deletion.
    private static func discard(_ url: URL, disposition: RemovalDisposition) throws -> URL? {
        switch disposition {
        case .trashed:
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return landed as URL?
        case .deleted:
            try FileManager.default.removeItem(at: url)
            return nil
        case .restored:
            // Never a removal instruction — `restored` exists only as a log
            // tombstone written by Put Back.
            return nil
        }
    }
}
