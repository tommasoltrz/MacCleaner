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
                // walked, not listed, not counted. Recency is handled separately
                // below — it *protects* rather than hides.
                guard !context.isExcluded(appURL) else { continue }

                let bundleID = Bundle(url: appURL)?.bundleIdentifier
                let baseName = String(name.dropLast(".app".count))

                // Curation, where it applies, takes over the whole support folder:
                // it splits those bytes into cache entries plus one locked
                // remainder. The plain leftover row for the same folder is dropped,
                // because listing both would offer the same bytes twice.
                let curation = Self.curation(bundleID: bundleID, baseName: baseName, home: home)
                let curatedRoot = curation.map {
                    home.appendingPathComponent($0.root).standardizedFileURL.path
                }

                var children: [FileEntry] = []
                for candidate in Self.leftoverCandidates(
                    baseName: baseName, bundleID: bundleID, library: library
                ) {
                    if let curatedRoot,
                       Self.overlaps(candidate.url.standardizedFileURL.path, curatedRoot) {
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
                // fact (the set comes from NSWorkspace via the app layer); recent
                // activity is the user's Preferences window doing its job. Either
                // way the row still appears — the useful fact that a daily app has
                // grown gigabytes survives — with its own checkbox locked.
                let reason: FileEntry.ProtectionReason? =
                    context.runningApplicationPaths.contains(appURL.path) ? .running
                    : context.isRecencyProtected(lastActivity) ? .recentUse
                    : nil

                // A preference, container or support folder is user data whether
                // the app ran today or four years ago. Recency controls the parent
                // app row; it must never decide whether deleting a child alone gets
                // a destructive warning.
                for index in children.indices where !children[index].isRegenerable {
                    children[index].protectionReason = .userData
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
    struct AppDataCuration: Sendable, Equatable {

        /// The app's support folder, relative to the home directory.
        let root: String

        /// Subpaths under `root` that the app rebuilds by itself.
        ///
        /// One component may be a glob, matched against the folder's real
        /// contents. That is how per-profile caches are reached without this
        /// table knowing profile names: Chrome writes a cache set inside every
        /// `Default` and `Profile N` folder, and the user decides how many of
        /// those exist.
        let regenerable: [String]

        /// Name for the single locked entry holding everything else.
        let remainderName: String
    }

    /// Apps whose layout the Electron rule below does not describe.
    ///
    /// Kept small on purpose. Every line is a claim about a real folder on a real
    /// disk, so a path goes in only after it has been seen there.
    static let curations: [String: AppDataCuration] = [
        // Chrome mixes multi-gigabyte regenerable trees with the user's logins,
        // history and bookmarks, and the generic leftover candidates cannot see
        // the difference. The on-device models are routinely the largest single
        // item in the folder.
        "com.google.Chrome": AppDataCuration(
            root: "Library/Application Support/Google/Chrome",
            regenerable: [
                "OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel",
                "optimization_guide_model_store", "component_crx_cache",
                "SODA", "SODALanguagePacks", "screen_ai", "WasmTtsEngine",
                "GrShaderCache", "ShaderCache", "Crashpad",
                // Per-profile caches. The caches inside a profile regenerate, the
                // databases beside them are the user's life.
                //
                // `Service Worker` holds three things and only two of them are
                // cache: `CacheStorage` (what a site stored for offline use),
                // `ScriptCache` (the compiled worker scripts, re-fetched on the
                // next registration) and `Database`, which is the registration
                // itself and stays. `Shared Dictionary` is the compression
                // dictionaries the browser downloaded, and costs a re-download.
                // Measured across this Mac's eight Chrome profiles: ScriptCache
                // 72.8 MB, Shared Dictionary 52.2 MB, both of which used to sit
                // in the locked remainder as though they were the user's data.
                "Default/Service Worker/CacheStorage",
                "Default/Service Worker/ScriptCache",
                "Default/Shared Dictionary",
                "Default/Code Cache",
                "Default/GPUCache",
                "Profile */Service Worker/CacheStorage",
                "Profile */Service Worker/ScriptCache",
                "Profile */Shared Dictionary",
                "Profile */Code Cache",
                "Profile */GPUCache"
            ],
            remainderName: "Chrome profiles and settings"
        ),

        // Claude Desktop is Electron, but it keeps its renderers in per-feature
        // partitions, so its Chromium caches sit one level down and the marker
        // test below never sees them at the top of the folder. Verified against a
        // real install.
        //
        // `claude-code` and `claude-code-vm` are the two largest items here and
        // are deliberately left in the locked remainder: an installed CLI and its
        // VM image are not caches, and nothing observed says the app rebuilds
        // them on demand.
        "com.anthropic.claudefordesktop": AppDataCuration(
            root: "Library/Application Support/Claude",
            regenerable: ["Crashpad", "Partitions/*/Cache", "Partitions/*/Code Cache"],
            remainderName: "Claude settings and data"
        ),

        // VS Code uses the historical product name `Code` rather than either its
        // display name or bundle identifier, so the generic Electron lookup cannot
        // reach it. `User`, workspaceStorage, History and extensions deliberately
        // remain in the protected remainder.
        "com.microsoft.VSCode": AppDataCuration(
            root: "Library/Application Support/Code",
            regenerable: electronRegenerable + [
                "CachedData", "CachedExtensions", "CachedExtensionVSIXs",
                "CachedProfilesData", "CachedConfigurations"
            ],
            remainderName: "Visual Studio Code settings and data"
        ),

        // The ChatGPT desktop bundle currently identifies as `com.openai.codex`
        // and stores its Chromium profile under `Codex`; neither identifier nor
        // display name points to that folder.
        "com.openai.codex": AppDataCuration(
            root: "Library/Application Support/Codex",
            regenerable: electronRegenerable + [
                "Default/Cache", "Default/Code Cache", "Default/GPUCache",
                "Default/Service Worker/CacheStorage"
            ],
            remainderName: "ChatGPT profiles and settings"
        ),

        // Figma keeps one Chromium profile per desktop engine version. Old engine
        // caches are often the bulk of the folder, while the files beside them and
        // the bundled agents are installation/user state.
        "com.figma.Desktop": AppDataCuration(
            root: "Library/Application Support/Figma",
            regenerable: [
                "DesktopProfile/*/Cache", "DesktopProfile/*/Code Cache",
                "DesktopProfile/*/GPUCache", "DesktopProfile/*/Crashpad"
            ],
            remainderName: "Figma settings and data"
        ),

        // Ferdium has normal Electron caches at the root plus a Chromium partition
        // per configured messaging service. Recipes, configuration, cookies and
        // sessions remain protected.
        "org.ferdium.ferdium-app": AppDataCuration(
            root: "Library/Application Support/Ferdium",
            regenerable: electronRegenerable + [
                "Partitions/*/Cache", "Partitions/*/Code Cache",
                "Partitions/*/GPUCache", "Partitions/*/Service Worker/CacheStorage"
            ],
            remainderName: "Ferdium accounts and settings"
        ),

        // Tor Browser deliberately separates disposable browser caches from the
        // profile and Tor keys. The whole profile root must never be called cache.
        "org.torproject.torbrowser": AppDataCuration(
            root: "Library/Application Support/TorBrowser-Data",
            regenerable: ["Browser/Caches"],
            remainderName: "Tor Browser profile and settings"
        )
    ]

    // MARK: - The Electron rule

    /// Either of these at the top of a support folder means a Chromium renderer
    /// lives there, which is what every Electron app ships. VS Code, Slack,
    /// Discord, Notion and hundreds more write the identical layout, so one rule
    /// covers all of them and the table above stays short.
    static let electronMarkers = ["Code Cache", "GPUCache"]

    /// The regenerable set shared by every Electron app.
    ///
    /// All of it is Chromium scratch space: compiled script, GPU shaders, the
    /// service-worker response cache, crash dumps waiting to upload. Deleting any
    /// of it costs one slower launch.
    ///
    /// `Session Storage` is not in this list even though it looks like one more
    /// cache. It holds live per-window state, not a cache, and removing it loses
    /// what the user had open. `blob_storage`, `Partitions` and `Local State` are
    /// left out for the same reason.
    static let electronRegenerable = [
        "Cache", "Code Cache", "GPUCache",
        "DawnWebGPUCache", "DawnGraphiteCache", "DawnCache",
        // `ScriptCache` sits beside `CacheStorage` and is a cache in the same
        // sense — compiled worker scripts, re-fetched on the next registration.
        // `Service Worker/Database` is the registration itself and is not listed.
        // Both of these, and `Shared Dictionary`, were seen in Electron apps on
        // this Mac (VS Code, Cursor, Ferdium) before being listed here.
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
        "Shared Dictionary", "Crashpad", "component_crx_cache"
    ]

    /// Name for the locked entry an Electron app gets for everything else.
    ///
    /// What sits in there is `Cookies`, `Local Storage`, `IndexedDB` and
    /// `Preferences`: the user's logins, their open sessions, their settings.
    /// That is why the entry is locked rather than merely unchecked. Removing it
    /// signs the user out of the app, and the row exists to say so plainly rather
    /// than to hide bytes the user can see in Finder.
    static func electronRemainderName(for appName: String) -> String {
        "\(appName) settings and data"
    }

    /// The curation for one app, if there is one.
    ///
    /// Explicit table first: an app listed there has been looked at, and the
    /// generic rule must not override that judgement. Otherwise the support
    /// folder is found exactly the way `leftoverCandidates` finds it, by bundle
    /// identifier and then by app name, and the Electron rule decides.
    static func curation(bundleID: String?, baseName: String, home: URL) -> AppDataCuration? {
        let fileManager = FileManager.default

        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: home.appendingPathComponent(relative).path)
        }

        // A table entry names a path that need not exist on this Mac.
        if let bundleID, let explicit = curations[bundleID] {
            return exists(explicit.root) ? explicit : nil
        }

        // An empty identifier would name `Application Support` itself.
        for name in [bundleID, baseName].compactMap({ $0 }) where !name.isEmpty {
            let relative = "Library/Application Support/\(name)"
            guard electronMarkers.contains(where: { exists("\(relative)/\($0)") }) else { continue }
            return AppDataCuration(
                root: relative,
                regenerable: electronRegenerable,
                remainderName: electronRemainderName(for: baseName)
            )
        }
        return nil
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
                entries.append(FileEntry(
                    url: url,
                    kind: .cache,
                    allocatedBytes: size.allocatedBytes,
                    lastOpened: nil,
                    isRegenerable: true
                ))
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
            entries.append(FileEntry(
                url: root,
                displayName: curation.remainderName,
                kind: .folder,
                allocatedBytes: preserveBytes,
                lastOpened: nil,
                protectionReason: .userData,
                childCount: remaining.count
            ))
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
        var urls = [root]
        for component in subpath.split(separator: "/").map(String.init) {
            guard component.contains(where: { "*?[".contains($0) }) else {
                urls = urls.map { $0.appendingPathComponent(component) }
                continue
            }
            urls = urls.flatMap { base in
                ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
                    .filter { fnmatch(component, $0, 0) == 0 }
                    // Directory order is undefined; sort so two scans of an
                    // unchanged disk produce the same list.
                    .sorted()
                    .map { base.appendingPathComponent($0) }
            }
        }
        return urls
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
