import Foundation

/// Installed applications, each carrying the support files it left around the system.
///
/// Ports `electron/cleaners/applications.ts`. The three subprocesses the original ran
/// **per application** are gone, and each removal fixes a defect rather than merely
/// changing implementation:
///
/// * **`du -sk` → `context.measurer`.** `du` exits non-zero the moment it meets a
///   directory it cannot read, and the old `catch` turned that into `0`. A single
///   permission-denied folder inside an app's container silently reported the whole
///   app as weightless. The measurer counts the unreadable entry and keeps walking,
///   and this scanner sums those counts into `unreadableCount` so the gap is visible
///   instead of swallowed.
/// * **`mdls -name kMDItemLastUsedDate -raw` → `MDItemCopyAttribute`.** The original
///   parsed a formatted date string out of stdout. `MDItemCopyAttribute` hands back a
///   `Date`, so nothing depends on the process locale or on `mdls` output formatting.
/// * **`PlistBuddy -c "Print CFBundleIdentifier"` → `Bundle(url:)`.** Reading the
///   identifier through `Bundle` also gets it right for bundles that keep `Info.plist`
///   somewhere other than `Contents/Info.plist`, which the hard-coded path missed.
///
/// Every application is emitted as one `.appBundle` entry whose `children` are its
/// leftovers, because cleanup trashes the children first and the bundle last; the
/// row's headline figure is `FileEntry.totalBytesIncludingChildren`. Removal here
/// always moves to the Trash (`CategoryID.alwaysMovesToTrash`) — an application is
/// never unlinked, so a wrong guess stays recoverable.
public struct ApplicationsScanner: CategoryScanner {

    public let id: CategoryID = .applications

    /// Where installed applications are looked for, and the home whose `Library`
    /// holds their leftovers.
    ///
    /// Injectable for the reason `XcodeScanner`'s roots are: absolute paths compiled
    /// into a scanner make its own rules untestable, and this scanner holds the ones
    /// worth testing most — an excluded app is not walked, an app whose data holds a
    /// protected pattern is not offered at all, and the curated remainder travels
    /// with the bundle. Production passes nothing and gets the two real directories.
    ///
    /// A fixture must pass **both**: `home` alone would leave `/Applications` in the
    /// search, and the machine's own applications back in the test.
    private let applicationDirectories: [URL]
    private let home: URL

    /// - Parameters:
    ///   - applicationDirectories: where to look for `.app` bundles. Defaults to
    ///     `/Applications` and `<home>/Applications`. `/System/Applications` is
    ///     deliberately absent: those bundles live on the sealed system volume and
    ///     cannot be removed, so listing them would offer an action that always fails.
    ///   - home: the home folder whose `Library` is searched for each app's leftovers.
    public init(applicationDirectories: [URL]? = nil,
                home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.home = home
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: - Scanning

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let fileManager = FileManager.default
        var entries: [FileEntry] = []
        var unreadableCount = 0
        var readAnyDirectory = false

        for directory in applicationDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            readAnyDirectory = true

            for name in names where name.hasSuffix(".app") {
                // Apps skipped by the exclusion rules never reach the measurer, so the
                // loop can run for a long time without one — check here too.
                try Task.checkCancellation()

                let appURL = directory.appendingPathComponent(name)
                // Explicit rules are absolute: an app on the exclusion list is not
                // walked, not listed, not counted. A running app is handled
                // separately below — that *protects* rather than hides.
                guard !context.isExcluded(appURL) else { continue }

                let bundleID = Bundle(url: appURL)?.bundleIdentifier
                let baseName = String(name.dropLast(".app".count))

                // Curation, where it applies, takes over the whole support folder:
                // it splits those bytes into cache entries plus one locked
                // remainder. The plain leftover row for the same folder is dropped,
                // because listing both would offer the same bytes twice.
                let curation = Self.curation(bundleID: bundleID, baseName: baseName, home: home)
                // A sandboxed app's container gets the same split, by the sandbox's
                // own layout rather than by a table — see `containerCuration`.
                let containerCuration = Self.containerCuration(
                    bundleID: bundleID, baseName: baseName, home: home
                )
                let curatedRoots = [curation, containerCuration].compactMap { $0 }.map {
                    home.appendingPathComponent($0.root).standardizedFileURL.path
                }

                var children: [FileEntry] = []
                for candidate in Self.leftoverCandidates(
                    baseName: baseName, bundleID: bundleID, library: library
                ) {
                    let candidatePath = candidate.url.standardizedFileURL.path
                    if curatedRoots.contains(where: { Self.overlaps(candidatePath, $0) }) {
                        continue
                    }
                    // A leftover can be excluded on its own — an explicit exclusion
                    // path means "never touch this". Such a file is simply skipped.
                    guard !context.isExcluded(candidate.url) else { continue }
                    let childOpened = lastOpenedDate(for: candidate.url)
                    let size = try await context.measurer.measure(candidate.url)
                    guard size.allocatedBytes > 0 else { continue }
                    // See `SizeMeasurement.containsProtectedPattern`.
                    guard !size.containsProtectedPattern else { continue }

                    unreadableCount += size.unreadableCount
                    children.append(FileEntry(
                        url: candidate.url,
                        kind: candidate.kind,
                        allocatedBytes: size.allocatedBytes,
                        lastOpened: childOpened,
                        isRegenerable: candidate.isRegenerable,
                        childCount: Self.itemCount(of: candidate.url)
                    ))
                }

                var supportIsProtected = false
                if let curation,
                   let curated = try await Self.curatedChildren(
                       curation, home: home, context: context
                   ) {
                    unreadableCount += curated.unreadableCount
                    supportIsProtected = curated.holdsProtectedContent
                    children.append(contentsOf: curated.entries)
                }
                // See `SizeMeasurement.containsProtectedPattern`. Both halves of
                // the app matter: the bundle itself can ship a keychain, and so can
                // its support folder — and removing the app row takes both.
                guard !supportIsProtected else { continue }

                // A container that holds protected content is left off the list and
                // the application stays, which is what the plain leftover rule did
                // for it before the split existed. Nothing can remove the container
                // through this row: a child that is not listed is not removed.
                // `curatedChildren` hands back no entries for such a folder, so
                // `holdsProtectedContent` is deliberately not consulted here — it is
                // what withdraws the whole application, and that is the other rule.
                if let containerCuration,
                   let curated = try await Self.curatedChildren(
                       containerCuration, home: home, context: context
                   ) {
                    unreadableCount += curated.unreadableCount
                    children.append(contentsOf: curated.entries)
                }

                let bundleSize = try await context.measurer.measure(appURL)
                guard bundleSize.allocatedBytes > 0 else { continue }
                guard !bundleSize.containsProtectedPattern else { continue }
                unreadableCount += bundleSize.unreadableCount

                // The bundle's own dates lie in both directions: Spotlight's
                // last-used is usually null, and an auto-updater rewrites the bundle
                // whether or not the user ever opens it. The app's *usage traces* are
                // stronger — caches and saved window state are only written by
                // actually running it — so last activity is the newest date across
                // the bundle and its regenerable leftovers.
                let lastActivity = ([lastOpenedDate(for: appURL)]
                    + children.filter(\.isRegenerable).map(\.lastOpened))
                    .compactMap { $0 }
                    .max()

                // Protection, not exclusion. A running app is in use as a matter of
                // fact (the set comes from NSWorkspace via the app layer). The row
                // still appears — the useful fact that a daily app has grown
                // gigabytes survives — with its own checkbox locked. `lastActivity`
                // is shown as a date and sorts the list; it locks and labels nothing.
                let reason: FileEntry.ProtectionReason? =
                    context.runningApplicationPaths.contains(appURL.path) ? .running : nil

                // A preference, container or support folder is user data whether
                // the app ran today or four years ago. No date decides whether
                // deleting a child alone gets a destructive warning.
                for index in children.indices where !children[index].isRegenerable {
                    children[index].protectionReason = .userData
                }

                let ownerRules: [FileEntry.OwnerRule] = [.bundlePath(appURL.path)]
                    + (bundleID.map { [.bundleIdentifier($0)] } ?? [])
                for index in children.indices {
                    children[index].ownerRules = ownerRules
                }

                // A running app's caches stay listed and removable, but are not
                // called safe while it runs — see `FileEntry.inUseBy`.
                if reason == .running {
                    let owner = context.runningOwner(atBundlePath: appURL.path)
                        ?? FileEntry.RunningOwner(
                            name: baseName, bundleIdentifier: bundleID,
                            bundlePath: appURL.path
                        )
                    for index in children.indices where children[index].isRegenerable {
                        children[index].inUseBy = owner
                    }
                }

                entries.append(FileEntry(
                    url: appURL,
                    // Finder hides the `.app` extension, so the row should too.
                    displayName: baseName,
                    kind: .appBundle,
                    allocatedBytes: bundleSize.allocatedBytes,
                    lastOpened: lastActivity,
                    protectionReason: reason,
                    ownerRules: ownerRules,
                    // An `.app` contains exactly one item — `Contents` — so counting
                    // its directory entries says nothing. The number worth showing on
                    // an application row is how many leftovers come with it.
                    childCount: children.isEmpty ? nil : children.count,
                    children: children
                ))
            }
        }

        // Least recently used first. A `nil` date is "never opened", the strongest
        // signal that a bundle is dead weight, so it sorts ahead of every dated app —
        // the same position the original's `lastUsed ?? 0` gave it.
        entries.sort { lhs, rhs in
            let left = lhs.lastOpened ?? .distantPast
            let right = rhs.lastOpened ?? .distantPast
            if left != right { return left < right }
            // Directory enumeration order is not defined; break ties by name so two
            // scans of an unchanged disk produce the same list.
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        let availability: CategoryAvailability
        if !readAnyDirectory {
            availability = .unavailable(
                reason: "No application folder could be read. Check that /Applications "
                    + "exists and that Scolo has Full Disk Access in System Settings › "
                    + "Privacy & Security."
            )
        } else if entries.isEmpty {
            availability = .empty
        } else {
            availability = .available
        }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.displayBytes },
            entries: entries,
            availability: availability,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Measuring


    private static func itemCount(of url: URL) -> Int? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
    }


    // MARK: - Curated app data

    /// Which parts of one app's support folder are disposable, and which are the
    /// user's account.
    ///
    /// Nothing here is inferred from a name. A folder called `Local Storage` holds
    /// the user's session and a folder called `Code Cache` holds compiled
    /// JavaScript, and only knowledge of the app tells them apart. So the split is
    /// a table: paths named here regenerate on next launch and get their own
    /// checkbox, and everything not named here is folded into one locked entry.
    /// The asymmetry is deliberate. Missing a cache costs the user some disk;
    /// mistaking their logins for a cache costs them their logins.
    typealias AppDataCuration = StorageRuleRegistry.AppDataCuration
    static let curations = StorageRuleRegistry.curations
    static let electronMarkers = StorageRuleRegistry.electronMarkers
    static let electronRegenerable = StorageRuleRegistry.electronRegenerable
    static let containerCachePath = StorageRuleRegistry.containerCachePath

    static func curation(bundleID: String?, baseName: String, home: URL) -> AppDataCuration? {
        StorageRuleRegistry.curation(bundleID: bundleID, baseName: baseName, home: home)
    }

    static func containerCuration(bundleID: String?, baseName: String, home: URL) -> AppDataCuration? {
        StorageRuleRegistry.containerCuration(bundleID: bundleID, baseName: baseName, home: home)
    }

    // MARK: - Applying a curation

    /// Curated entries plus the measurement gaps found on the way, which the
    /// category reports rather than swallows.
    struct CuratedData {
        var entries: [FileEntry]
        var unreadableCount: Int
        /// The support folder holds something that must not be removed — a
        /// protected glob, or an explicit exclusion the user added. The app row is
        /// dropped entirely when this is set. A partial uninstall would keep the
        /// remainder, but a complete uninstall can carry it with the bundle; an
        /// explicit exclusion must remain absolute under either choice.
        var holdsProtectedContent = false
    }

    /// Measures one curated folder and splits it into cache entries plus the
    /// locked remainder.
    ///
    /// The remainder is arithmetic, never an estimate: the measured folder minus
    /// exactly the bytes carved out of it, floored at zero. That is what keeps the
    /// two halves from double-counting, and it stays true when a cache path is
    /// skipped, because a skipped path adds nothing to the curated total and so
    /// its bytes stay inside the remainder where they still are on disk.
    static func curatedChildren(
        _ curation: AppDataCuration,
        home: URL,
        context: ScanContext
    ) async throws -> CuratedData? {
        let fileManager = FileManager.default
        let root = home.appendingPathComponent(curation.root)
        guard fileManager.fileExists(atPath: root.path) else { return nil }

        // An explicit exclusion anywhere inside the support folder protects the
        // whole application. Only the curated cache paths were checked before, so
        // an excluded path elsewhere in the folder stayed in the locked remainder,
        // where complete removal could still reach it. `isExcluded` answers true
        // for a directory that merely *contains* an exclusion, which is exactly the
        // question here.
        guard !context.isExcluded(root) else {
            return CuratedData(entries: [], unreadableCount: 0, holdsProtectedContent: true)
        }

        let registry = StorageRuleRegistry(rules: StorageRuleRegistry.applicationRules(
            curation, identifier: curation.ownerIdentifier,
            name: curation.ownerName ?? curation.remainderName
        ))
        var entries: [FileEntry] = []
        var curatedBytes: Int64 = 0
        var seen = Set<String>()
        // Top-level items swallowed whole by a cache entry. They are the only ones
        // that stop being part of the remainder.
        var curatedTopLevel = Set<String>()

        for subpath in curation.regenerable {
            for url in expand(subpath, under: root) {
                // Expanding globs and skipping absent paths can run for a while
                // without reaching the measurer, which is the other place that
                // notices cancellation.
                try Task.checkCancellation()

                let path = url.standardizedFileURL.path
                // Two rules could name one path; measuring it twice would inflate
                // the curated total and shrink the remainder below the truth.
                guard seen.insert(path).inserted else { continue }
                guard fileManager.fileExists(atPath: path) else { continue }
                // An explicit exclusion means "never touch this" and outranks
                // everything this table knows.
                guard !context.isExcluded(url) else { continue }

                let size = try await context.measurer.measure(url)
                guard size.allocatedBytes > 0 else { continue }
                // See `SizeMeasurement.containsProtectedPattern`. Skipped rather
                // than carved out, so the bytes stay inside the locked remainder.
                guard !size.containsProtectedPattern else { continue }

                curatedBytes += size.allocatedBytes
                if url.deletingLastPathComponent().standardizedFileURL.path
                    == root.standardizedFileURL.path {
                    curatedTopLevel.insert(url.lastPathComponent)
                }
                entries.append(registry.classify(FileEntry(
                    url: url,
                    kind: .cache,
                    allocatedBytes: size.allocatedBytes,
                    // Never `nil` for want of asking. A missing date renders as the
                    // orange "Never opened", the strongest hint the design has that
                    // a row is safe to remove, and every carved cache wore it —
                    // WhatsApp's, Pages', Chrome's — because no date was passed.
                    lastOpened: lastOpenedDate(for: url)
                ), home: home, context: context))
            }
        }

        // Everything else is the user's data. The entry is listed so the bytes are
        // visible and locked by default; the app can authorize this exact row only
        // after showing the destructive warning.
        let total = try await context.measurer.measure(root)
        let preserveBytes = max(0, total.allocatedBytes - curatedBytes)
        if preserveBytes > 0 {
            // The remaining items, which is what `· N items` is supposed to mean.
            // Measuring the root already walked the curated subtrees, so its
            // `unreadableCount` covers them too and adding theirs would count the
            // same gaps twice.
            let remaining = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { !curatedTopLevel.contains($0) }
            entries.append(registry.classify(FileEntry(
                url: root,
                displayName: curation.remainderName,
                kind: .folder,
                allocatedBytes: preserveBytes,
                lastOpened: lastOpenedDate(for: root),
                protectionReason: .userData,
                childCount: remaining.count
            ), home: home, context: context))
        }
        // `total` measured the whole support root, so its flag covers every part
        // of it — including the bytes inside the locked remainder.
        guard !total.containsProtectedPattern else {
            return CuratedData(
                entries: [], unreadableCount: total.unreadableCount,
                holdsProtectedContent: true
            )
        }
        return entries.isEmpty
            ? nil
            : CuratedData(entries: entries, unreadableCount: total.unreadableCount)
    }

    /// Expands one regenerable subpath into the paths it actually names.
    ///
    /// A component containing a glob character is matched against the folder's
    /// real contents; every other component is appended as written, so the common
    /// case reads no directories at all.
    static func expand(_ subpath: String, under root: URL) -> [URL] {
        StorageRuleRegistry.expand(subpath, under: root)
    }

    /// True when one path contains the other, in either direction.
    ///
    /// Either way round is a double count: the curated folder and a leftover
    /// candidate would both claim the same bytes. The test is component-aware, so
    /// `…/Chrome` does not claim `…/ChromeBeta`.
    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    // MARK: - Leftovers

    private struct Candidate {
        let url: URL
        let kind: FileEntry.Kind

        /// Caches, saved window state and web storage all come back on next launch, so
        /// they carry the `· regenerable` qualifier. Containers, Application Support
        /// and preferences hold the user's actual data and do not.
        var isRegenerable: Bool { kind == .cache }
    }

    /// Every support-file location the original checked, in the same order: the
    /// bundle-identifier matches first, then the looser app-name matches that catch
    /// apps which do not name their folders after their identifier.
    ///
    /// Only paths that exist are returned, and each path appears once even when two
    /// rules match it.
    private static func leftoverCandidates(
        baseName: String, bundleID: String?, library: URL
    ) -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        var seen = Set<String>()

        func inLibrary(_ folder: String, _ name: String) -> URL {
            library.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(name)
        }

        func add(_ url: URL, _ kind: FileEntry.Kind) {
            let path = url.standardizedFileURL.path
            guard fileManager.fileExists(atPath: path), seen.insert(path).inserted else { return }
            candidates.append(Candidate(url: url, kind: kind))
        }

        // An empty identifier would make the `contains` test below true for every
        // group container on the system, attaching the entire folder to one app.
        if let bundleID, !bundleID.isEmpty {
            add(inLibrary("Caches", bundleID), .cache)
            add(inLibrary("Containers", bundleID), .folder)
            add(inLibrary("Application Support", bundleID), .folder)
            add(inLibrary("Application Scripts", bundleID), .folder)
            add(inLibrary("Saved Application State", "\(bundleID).savedState"), .cache)
            add(inLibrary("WebKit", bundleID), .cache)
            add(inLibrary("HTTPStorages", bundleID), .cache)

            // Preferences fan out into suffixed siblings — `<id>.plist`,
            // `<id>.helper.plist`, `<id>.LSSharedFileList.plist` — so the identifier is
            // a prefix test, not an exact filename.
            let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: preferences.path)) ?? []
            where name.hasPrefix(bundleID) && name.hasSuffix(".plist") {
                add(preferences.appendingPathComponent(name), .file)
            }

            // Group containers are prefixed, never bare: `group.com.company.app` or the
            // team-ID form `ABCDE12345.com.company.app`. A prefix test would match
            // neither, so the original tests for containment and, failing that, for the
            // identifier with its leading component dropped — which catches a group id
            // written as `group.company.app` against a bundle id of `com.company.app`.
            let groups = library.appendingPathComponent("Group Containers", isDirectory: true)
            let components = bundleID.split(separator: ".")
            let withoutLeadingComponent = components.count > 2
                ? components.dropFirst().joined(separator: ".")
                : nil
            for name in (try? fileManager.contentsOfDirectory(atPath: groups.path)) ?? [] {
                let matches = name.contains(bundleID)
                    || (withoutLeadingComponent.map { name.hasSuffix($0) } ?? false)
                guard matches else { continue }
                add(groups.appendingPathComponent(name), .folder)
            }
        }

        add(inLibrary("Application Support", baseName), .folder)
        add(inLibrary("Caches", baseName), .cache)
        add(inLibrary("Logs", baseName), .cache)

        return candidates
    }
}
