import Foundation

// Existing layouts retain their path boundaries and recorded exclusions.
extension StorageRuleRegistry {
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
        var ownerIdentifier: String? = nil
        var ownerName: String? = nil
        var evidence: StorageRule.Evidence = .init(basis: .unverified, reference: "No evidence recorded")

        func owned(by identifier: String?, name: String) -> Self {
            var copy = self
            copy.ownerIdentifier = identifier
            copy.ownerName = name
            return copy
        }
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
                // Nothing under `Service Worker` is offered — not `CacheStorage`,
                // not `ScriptCache`, not `Database`. It reads like three folders
                // and behaves like one: `Database` holds the registration, and the
                // registration addresses script bodies in `ScriptCache` by resource
                // id. An installed worker's script is served from there and is
                // *not* re-fetched on the next visit, so taking the caches while
                // the registration survives leaves Chrome pointing at resources
                // that are gone.
                //
                // Scolo took 721.5 MB of `CacheStorage` and 72.8 MB of `ScriptCache`
                // out of this Mac's Chrome profiles on 30 Aug 2026 and left
                // `Database` behind; the wreckage was a `CacheStorage` bucket with
                // no `index.txt` beside Instagram's and YouTube's, which still had
                // theirs. `www.reddit.com` went black at the same time and this
                // was blamed for it — wrongly, as far as anyone has shown:
                // clearing the site's data changed nothing. The fault that was
                // later caught by name is the dictionary one below.
                //
                // Chrome's own "Clear browsing data" removes the three together.
                // Scolo removes none of them: a site's offline data belongs in the
                // locked remainder next to the cookies that go with it.
                //
                // `Shared Dictionary` is withheld too, and it was the one that
                // could be seen failing. It was offered because it is
                // self-contained on disk — index and dictionaries in one folder —
                // and that was the wrong test: a running Chrome holds the index in
                // memory. Remove the folder under it and Chrome goes on sending
                // `Available-Dictionary` for bodies that are gone; the server
                // answers with a response only that dictionary can decode, and
                // the document fails with `net::ERR_DICTIONARY_LOAD_FAILED`.
                // Seen on 19 Sep 2026: `www.reddit.com` blank after a Safe to
                // Remove sweep, unmoved by "Clear site data", cured by
                // relaunching Chrome. 52.2 MB across eight profiles is not worth
                // a site that will not load.
                "Default/Code Cache",
                "Default/GPUCache",
                "Profile */Code Cache",
                "Profile */GPUCache"
            ],
            remainderName: "Chrome profiles and settings", evidence: inheritedEvidence
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
            remainderName: "Claude settings and data", evidence: inheritedEvidence
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
            remainderName: "Visual Studio Code settings and data", evidence: inheritedEvidence
        ),

        // The ChatGPT desktop bundle currently identifies as `com.openai.codex`
        // and stores its Chromium profile under `Codex`; neither identifier nor
        // display name points to that folder.
        "com.openai.codex": AppDataCuration(
            root: "Library/Application Support/Codex",
            regenerable: electronRegenerable + [
                "Default/Cache", "Default/Code Cache", "Default/GPUCache"
            ],
            remainderName: "ChatGPT profiles and settings", evidence: inheritedEvidence
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
            remainderName: "Figma settings and data", evidence: inheritedEvidence
        ),

        // Ferdium has normal Electron caches at the root plus a Chromium partition
        // per configured messaging service. Recipes, configuration, cookies and
        // sessions remain protected.
        "org.ferdium.ferdium-app": AppDataCuration(
            root: "Library/Application Support/Ferdium",
            regenerable: electronRegenerable + [
                "Partitions/*/Cache", "Partitions/*/Code Cache",
                "Partitions/*/GPUCache"
            ],
            remainderName: "Ferdium accounts and settings", evidence: inheritedEvidence
        ),

        // Tor Browser deliberately separates disposable browser caches from the
        // profile and Tor keys. The whole profile root must never be called cache.
        "org.torproject.torbrowser": AppDataCuration(
            root: "Library/Application Support/TorBrowser-Data",
            regenerable: ["Browser/Caches"],
            remainderName: "Tor Browser profile and settings", evidence: inheritedEvidence
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
    /// All of it is Chromium scratch space: compiled script, GPU shaders, crash
    /// dumps waiting to upload. Deleting any of it costs one slower launch.
    ///
    /// `Session Storage` is not in this list even though it looks like one more
    /// cache. It holds live per-window state, not a cache, and removing it loses
    /// what the user had open. `blob_storage`, `Partitions` and `Local State` are
    /// left out for the same reason.
    ///
    /// Neither is `Service Worker`, in any of its three parts, for the reason
    /// spelled out against Chrome above: the registration in `Database` addresses
    /// script bodies in `ScriptCache`, so removing one under the other leaves a
    /// worker that cannot load. Electron ships the same Chromium and the same
    /// fault — the 30 Aug 2026 sweep took 184.5 MB out of Ferdium's per-service
    /// partitions and 4.3 MB out of VS Code the same way it broke Chrome's.
    ///
    /// Nor `Shared Dictionary`: a running renderer keeps the dictionary index in
    /// memory and goes on advertising dictionaries whose bodies were removed, so
    /// pages fail with `ERR_DICTIONARY_LOAD_FAILED` until the app is relaunched.
    static let electronRegenerable = [
        "Cache", "Code Cache", "GPUCache",
        "DawnWebGPUCache", "DawnGraphiteCache", "DawnCache",
        "Crashpad", "component_crx_cache"
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
            return exists(explicit.root) ? explicit.owned(by: bundleID, name: baseName) : nil
        }

        // An empty identifier would name `Application Support` itself.
        for name in [bundleID, baseName].compactMap({ $0 }) where !name.isEmpty {
            let relative = "Library/Application Support/\(name)"
            guard electronMarkers.contains(where: { exists("\(relative)/\($0)") }) else { continue }
            return AppDataCuration(
                root: relative,
                regenerable: electronRegenerable,
                remainderName: electronRemainderName(for: baseName), evidence: inheritedEvidence
            ).owned(by: bundleID, name: baseName)
        }
        return nil
    }

    // MARK: - The sandbox rule

    /// The split for a sandboxed app's container, if it has one with a cache in it.
    ///
    /// A sandboxed app cannot write to `~/Library/Caches`. Its `NSCachesDirectory`
    /// is `~/Library/Containers/<bundle id>/Data/Library/Caches`, so everything
    /// System Caches offers for an ordinary app sat, for a sandboxed one, inside the
    /// container — one locked `userData` row, cache and documents alike. This is not
    /// a name being trusted: the sandbox fixes the layout, and the path is where the
    /// system itself sends a request for the caches directory.
    ///
    /// The cache's *children* are offered, never `Caches` itself. The container's
    /// skeleton is laid down when the container is created, and nothing observed
    /// says it is laid down again for an app that finds the folder gone. Removing
    /// what is in it asks for no such promise.
    ///
    /// Not measured here: the shell has no Full Disk Access and `du` answers zero
    /// for a container it may not read. The figures have to come from the app.
    static func containerCuration(
        bundleID: String?, baseName: String, home: URL
    ) -> AppDataCuration? {
        // An empty identifier would name `Containers` itself.
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let root = "Library/Containers/\(bundleID)"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: home.appendingPathComponent("\(root)/\(containerCachePath)").path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return AppDataCuration(
            root: root,
            regenerable: ["\(containerCachePath)/*"],
            remainderName: "\(baseName) container", evidence: sandboxEvidence
        ).owned(by: bundleID, name: baseName)
    }

    /// Where the sandbox puts `NSCachesDirectory`, relative to the container.
    static let containerCachePath = "Data/Library/Caches"


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

}
