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

    public init() {}

    // MARK: - Search roots

    /// Exactly where the original looked. `/System/Applications` is deliberately not
    /// added: those bundles live on the sealed system volume and cannot be removed,
    /// so listing them would only offer the user an action that always fails.
    private static let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
    ]

    private static let library = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library", isDirectory: true)

    // MARK: - Scanning

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fileManager = FileManager.default
        var entries: [FileEntry] = []
        var unreadableCount = 0
        var readAnyDirectory = false

        for directory in Self.applicationDirectories {
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
                // walked, not listed, not counted. Recency is handled separately
                // below — it *protects* rather than hides.
                guard !context.isExcluded(appURL) else { continue }

                let bundleID = Bundle(url: appURL)?.bundleIdentifier
                let baseName = String(name.dropLast(".app".count))

                var children: [FileEntry] = []
                for candidate in Self.leftoverCandidates(baseName: baseName, bundleID: bundleID) {
                    // A leftover can be excluded on its own — an explicit exclusion
                    // path means "never touch this". Such a file is simply skipped.
                    guard !context.isExcluded(candidate.url) else { continue }
                    let childOpened = lastOpenedDate(for: candidate.url)
                    let size = try await context.measurer.measure(candidate.url)
                    guard size.allocatedBytes > 0 else { continue }

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

                if let curated = try await Self.curatedChildren(
                    bundleID: bundleID, home: home, context: context
                ) {
                    children.append(contentsOf: curated)
                }

                let bundleSize = try await context.measurer.measure(appURL)
                guard bundleSize.allocatedBytes > 0 else { continue }
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
                // fact (the set comes from NSWorkspace via the app layer); recent
                // activity is the user's Preferences window doing its job. Either
                // way the row still appears — the useful fact that a daily app has
                // grown gigabytes survives — with its own checkbox locked. Leftovers
                // stay individually removable, except the non-regenerable ones
                // (profiles, user data), which inherit the lock.
                let reason: FileEntry.ProtectionReason? =
                    context.runningApplicationPaths.contains(appURL.path) ? .running
                    : context.isRecencyProtected(lastActivity) ? .recentUse
                    : nil
                if reason != nil {
                    // The non-regenerable leftovers are the app's user data; that is
                    // their own reason, not the parent's.
                    for index in children.indices where !children[index].isRegenerable {
                        children[index].protectionReason = .userData
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
                    + "exists and that MacCleaner has Full Disk Access in System Settings › "
                    + "Privacy & Security."
            )
        } else if entries.isEmpty {
            availability = .empty
        } else {
            availability = .available
        }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.reclaimableBytes },
            entries: entries,
            availability: availability,
            unreadableCount: unreadableCount
        )
    }

    // MARK: - Measuring

    /// The mandatory sequence for one path: read the Spotlight date, consult the
    /// exclusion rules, and only then measure — so an excluded or recency-protected
    /// tree is never walked. `nil` means "do not emit this path".
    ///
    /// `makeEntry(url:kind:context:isRegenerable:)` does the same three steps but
    /// discards `SizeMeasurement.unreadableCount`, and this category has to report it,
    /// so the sequence is repeated here and the measurement returned intact.
    private func measureIfIncluded(
        _ url: URL,
        context: ScanContext
    ) async throws -> (lastOpened: Date?, size: SizeMeasurement)? {
        let lastOpened = lastOpenedDate(for: url)
        guard !context.isExcluded(url, lastOpened: lastOpened) else { return nil }

        // Any `CancellationError` from the walk propagates untouched.
        let size = try await context.measurer.measure(url)
        // Matching the original, which only recorded an associated file when its size
        // came back above zero. Nothing is freed by trashing an empty path.
        guard size.allocatedBytes > 0 else { return nil }

        return (lastOpened, size)
    }

    private static func itemCount(of url: URL) -> Int? {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
    }


    // MARK: - Curated app data

    /// Per-app knowledge of which support data is disposable and which must never
    /// go by accident.
    ///
    /// This is inherently per-app work, so it is done only where the payoff is
    /// large. Chrome is first: its support folder mixes multi-gigabyte regenerable
    /// caches (on-device models, shader caches, service-worker storage) with the
    /// user's logins, history and bookmarks, and the generic leftover candidates
    /// cannot see the difference. Everything is measured, split into removable
    /// cache entries and one locked "profiles and settings" entry for the rest.
    private static func curatedChildren(
        bundleID: String?,
        home: URL,
        context: ScanContext
    ) async throws -> [FileEntry]? {
        guard bundleID == "com.google.Chrome" else { return nil }
        let fileManager = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        guard fileManager.fileExists(atPath: root.path) else { return nil }

        // Fixed regenerable trees at the top of Chrome's support folder. The
        // on-device model is routinely the single largest item in it.
        var cachePaths = [
            "OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel",
            "optimization_guide_model_store", "component_crx_cache",
            "SODA", "SODALanguagePacks", "screen_ai", "WasmTtsEngine",
            "GrShaderCache", "ShaderCache", "Crashpad"
        ].map { root.appendingPathComponent($0) }

        // Per-profile caches. Profiles are "Default" and "Profile N"; the caches
        // inside them regenerate, the databases beside them are the user's life.
        let profiles = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        for profile in profiles {
            let base = root.appendingPathComponent(profile)
            cachePaths.append(base.appendingPathComponent("Service Worker/CacheStorage"))
            cachePaths.append(base.appendingPathComponent("Code Cache"))
            cachePaths.append(base.appendingPathComponent("GPUCache"))
        }

        var entries: [FileEntry] = []
        var curatedBytes: Int64 = 0
        for url in cachePaths where fileManager.fileExists(atPath: url.path) {
            guard !context.isExcluded(url) else { continue }
            let size = try await context.measurer.measure(url)
            guard size.allocatedBytes > 0 else { continue }
            curatedBytes += size.allocatedBytes
            entries.append(FileEntry(
                url: url,
                kind: .cache,
                allocatedBytes: size.allocatedBytes,
                lastOpened: nil,
                isRegenerable: true
            ))
        }

        // Everything else in the folder is treated as the user's data. The figure
        // is the measured remainder, and the entry is locked: it goes only when
        // the whole app goes.
        let total = try await context.measurer.measure(root)
        let preserveBytes = max(0, total.allocatedBytes - curatedBytes)
        if preserveBytes > 0 {
            entries.append(FileEntry(
                url: root,
                displayName: "Chrome profiles and settings",
                kind: .folder,
                allocatedBytes: preserveBytes,
                lastOpened: nil,
                protectionReason: .userData,
                childCount: profiles.count
            ))
        }
        return entries.isEmpty ? nil : entries
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
    private static func leftoverCandidates(baseName: String, bundleID: String?) -> [Candidate] {
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
