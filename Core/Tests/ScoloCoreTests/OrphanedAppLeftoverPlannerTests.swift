import Foundation
import Testing
@testable import ScoloCore

@Suite("Application leftover planning")
struct OrphanedAppLeftoverPlannerTests {
    private final class Sandbox {
        let root: URL
        let home: URL
        let applications: URL
        let userApplications: URL
        let systemLibrary: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("scolo-orphans-\(UUID().uuidString)")
            home = root.appendingPathComponent("home", isDirectory: true)
            applications = root.appendingPathComponent("Applications", isDirectory: true)
            userApplications = home.appendingPathComponent("Applications", isDirectory: true)
            systemLibrary = root.appendingPathComponent("Library", isDirectory: true)
            for directory in [home, applications, userApplications, systemLibrary] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func application(_ name: String, identifier: String) throws -> URL {
            let url = applications.appendingPathComponent("\(name).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }

        @discardableResult
        func write(_ relativePath: String) throws -> URL {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: 4_096).write(to: url)
            return url
        }

        /// Writes at an absolute location — the system library, for instance.
        @discardableResult
        func writeAbsolute(_ url: URL) throws -> URL {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: 4_096).write(to: url)
            return url
        }

        /// The evidence the planner requires before it believes an identifier was
        /// ever an application: saved window state, which macOS writes for
        /// applications and nothing else. Returns the `.savedState` directory,
        /// which the plan will list as a regenerable item.
        @discardableResult
        func evidence(for identifier: String) throws -> URL {
            try write("Library/Saved Application State/\(identifier).savedState/windows.plist")
                .deletingLastPathComponent()
        }

        func appPlanner() -> AppUninstallPlanner {
            AppUninstallPlanner(
                home: home,
                systemLibrary: systemLibrary,
                applicationRoots: [applications, userApplications],
                darwinCache: nil,
                darwinTemp: nil
            )
        }

        func planner(
            directoryNames: @escaping @Sendable (URL) throws -> [String] = { url in
                try FileManager.default.contentsOfDirectory(atPath: url.path)
            },
            candidatePathStatus: @escaping @Sendable (URL) ->
                OrphanedAppLeftoverPlanner.CandidatePathStatus = { url in
                    FileManager.default.fileExists(atPath: url.path) ? .present : .missing
                },
            teams: [String: String] = [:]
        ) -> OrphanedAppLeftoverPlanner {
            OrphanedAppLeftoverPlanner(
                pathPlanner: appPlanner(),
                directoryNames: directoryNames,
                candidatePathStatus: candidatePathStatus,
                // A fixture bundle is not signed, so the team it would be signed by
                // is stated: application name → Team ID.
                teamIdentifier: { url in teams[url.deletingPathExtension().lastPathComponent] }
            )
        }
    }

    private func sharedPlanner(_ box: Sandbox) -> OrphanedAppLeftoverPlanner {
        OrphanedAppLeftoverPlanner(pathPlanner: box.appPlanner(), sharedRoot: box.root.appendingPathComponent("Shared"))
    }

    @discardableResult
    private func sharedBundle(_ box: Sandbox, path: String, identifier: String) throws -> URL {
        let bundle = box.root.appendingPathComponent("Shared/" + path)
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleVersion": "1"],
            format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    @Test("verified shared leftovers appear under Safe to Remove without claiming other folders")
    func sharedLeftoversAreSafe() async throws {
        let box = try Sandbox()
        let game = box.root.appendingPathComponent("Shared/Epic Games/Fortnite")
        try box.writeAbsolute(game.appendingPathComponent(".egstore/download"))
        try box.writeAbsolute(box.root.appendingPathComponent("Shared/Epic Games/Personal/files"))
        try box.writeAbsolute(box.root.appendingPathComponent("Shared/Adobe/settings"))
        try sharedBundle(box, path: "UnrealEngine/Launcher/SelfUpdateStaging/Install/Epic Games Launcher.app", identifier: SharedApplicationData.epicLauncher)
        let planner = sharedPlanner(box)
        let result = try await ApplicationLeftoversScanner(planner: planner).scan(context: ScanContext())
        let plan = try #require(result.applicationLeftoverPlan)
        let group = try #require(plan.groups.first)
        #expect(group.displayName == "Epic Games")
        #expect(group.items.count == 2)
        #expect(group.items.contains { $0.url.path == game.path })
        #expect(group.items.allSatisfy { $0.content == .userData })
        #expect(result.tileRows(safeToRemove: true).count == 1)
        #expect(result.tileRows(safeToRemove: false).isEmpty)
        #expect(group.items.allSatisfy { OrphanedAppLeftoverPlan.removalIsStillSafe($0, in: plan, installedBundleIdentifiers: []) })
    }

    @Test("installed launcher and game owners protect shared data during scan and removal")
    func sharedOwners() async throws {
        let box = try Sandbox()
        let game = box.root.appendingPathComponent("Shared/Epic Games/Game")
        try box.writeAbsolute(game.appendingPathComponent(".egstore/download"))
        try sharedBundle(box, path: "Epic Games/Game/Game.app", identifier: "com.vendor.game")
        let planner = sharedPlanner(box)
        let scan = planner.scanCandidates()
        #expect(scan.identifiers.contains("com.vendor.game"))
        let plan = try await planner.plan(candidates: scan)
        #expect(plan.ownerBundleIdentifiers.contains("com.vendor.game"))
        #expect(plan.itemCount == 1)
        for owner in [SharedApplicationData.epicLauncher, "com.vendor.game"] {
            let protected = try await planner.plan(registeredApplicationBundleIdentifiers: [owner])
            #expect(protected.itemCount == 0)
            let outcome = try await CleanupService(log: RemovalLog(directory: box.root.appendingPathComponent("log")))
                .removeOrphanedAppLeftovers(plan, bundleIdentifiers: [SharedApplicationData.epicLauncher], registeredApplicationBundleIdentifiers: [owner])
            #expect(outcome.removedCount == 0)
            #expect(outcome.failed == [game.path])
        }
        _ = try box.application("Epic", identifier: SharedApplicationData.epicLauncher)
        #expect(try await planner.plan().itemCount == 0)
    }

    @Test("shared data keeps exclusions and rejects changed ownership markers")
    func sharedExclusionsAndChanges() async throws {
        let box = try Sandbox()
        let game = box.root.appendingPathComponent("Shared/Epic Games/Game")
        let marker = game.appendingPathComponent(".egstore")
        try box.writeAbsolute(marker.appendingPathComponent("download"))
        let planner = sharedPlanner(box)
        let excluded = try await planner.plan(context: ScanContext(excludedPaths: [marker.path]))
        #expect(excluded.itemCount == 0)
        let plan = try await planner.plan()
        let item = try #require(plan.groups.first?.items.first)
        try FileManager.default.removeItem(at: marker)
        #expect(!OrphanedAppLeftoverPlan.removalIsStillSafe(item, in: plan, installedBundleIdentifiers: []))
        try box.writeAbsolute(game.appendingPathComponent(".egstore/secret.keychain"))
        #expect(try await planner.plan(context: ScanContext(excludedPatterns: ["*.keychain"])).itemCount == 0)
    }

    @Test("shared path symbolic links never become removal candidates")
    func sharedSymlinks() async throws {
        let box = try Sandbox()
        let real = box.root.appendingPathComponent("Personal/Game")
        try box.writeAbsolute(real.appendingPathComponent(".egstore/download"))
        let games = box.root.appendingPathComponent("Shared/Epic Games")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: games.appendingPathComponent("Game"), withDestinationURL: real)
        #expect(try await sharedPlanner(box).plan().itemCount == 0)
    }

    @Test("a staged launcher is not an installed owner but a real or running app still is")
    func stagedRegistration() async throws {
        let box = try Sandbox()
        let staged = try sharedBundle(box, path: "UnrealEngine/Launcher/SelfUpdateStaging/Install/Epic Games Launcher.app", identifier: SharedApplicationData.epicLauncher)
        let scan = sharedPlanner(box).scanCandidates()
        #expect(scan.stagedApplicationRoots.count == 1)
        #expect(!OrphanedAppLeftoverPlanner.registeredApplicationIsOwner(at: staged, stagedApplicationRoots: scan.stagedApplicationRoots))
        let installed = try box.application("Epic", identifier: SharedApplicationData.epicLauncher)
        #expect(OrphanedAppLeftoverPlanner.registeredApplicationIsOwner(at: installed, stagedApplicationRoots: scan.stagedApplicationRoots))
        let running = OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: scan.identifiers, running: [SharedApplicationData.epicLauncher], isInstalled: { _ in false }
        )
        #expect(running.contains(SharedApplicationData.epicLauncher))
    }

    @Test("only exact bundle-identifier paths become leftovers")
    func exactIdentifiersOnly() async throws {
        let sandbox = try Sandbox()
        let state = try sandbox.evidence(for: "com.vendor.old")
        let cache = try sandbox.write("Library/Caches/com.vendor.old/blob")
            .deletingLastPathComponent()
        let preference = try sandbox.write("Library/Preferences/com.vendor.old.plist")
        _ = try sandbox.write("Library/Application Support/Old Editor/profile.db")
        _ = try sandbox.write("Library/Group Containers/group.com.vendor.old/shared.db")

        let plan = try await sandbox.planner().plan()
        let group = try #require(plan.groups.first { $0.id == "com.vendor.old" })

        #expect(Set(group.items.map(\.url)) == [cache, preference, state])
        #expect(!plan.groups.flatMap(\.items).contains {
            $0.url.path.contains("Old Editor") || $0.url.path.contains("Group Containers")
        })
    }

    /// An application that came from iOS, or was built with Catalyst, gets a
    /// container named by a UUID. The folder's name says nothing; macOS writes who
    /// it belongs to inside it. Seen on the owner's Mac on 20 Sep 2026: 57 MB of a
    /// removed PokerStars in `~/Library/Containers/94F36404-…`, which the classifier
    /// walked past because it read identifiers off folder names.
    @Test("a UUID-named container is a leftover on the identifier macOS wrote inside it")
    func uuidNamedContainers() async throws {
        let sandbox = try Sandbox()
        func container(_ uuid: String, identifier: String?) throws -> URL {
            let folder = sandbox.home.appendingPathComponent("Library/Containers/\(uuid)")
            _ = try sandbox.write("Library/Containers/\(uuid)/Data/Documents/save.db")
            if let identifier {
                try PropertyListSerialization.data(
                    fromPropertyList: ["MCMMetadataIdentifier": identifier, "MCMMetadataVersion": 1],
                    format: .binary, options: 0
                ).write(to: folder.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
            }
            return folder
        }
        let gone = try container("94F36404-A18D-4D25-934C-60BF64DCB120",
                                 identifier: "it.vendor.pokerclient")
        // Its application is still installed: the container is a live app's data.
        _ = try sandbox.application("Kept", identifier: "com.vendor.kept")
        let kept = try container("11111111-2222-3333-4444-555555555555",
                                 identifier: "com.vendor.kept")
        // An extension of the installed application, named beneath it.
        let extensionOfKept = try container("66666666-7777-8888-9999-000000000000",
                                            identifier: "com.vendor.kept.NotificationExt")
        // The system's own, and one with nothing written inside it.
        let apple = try container("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                                  identifier: "com.apple.something")
        let silent = try container("FFFFFFFF-0000-1111-2222-333333333333", identifier: nil)

        // The other layout in use: the identifier nested under `MCMMetadataInfo`.
        let nested = sandbox.home.appendingPathComponent(
            "Library/Containers/ABABABAB-1111-2222-3333-444444444444"
        )
        _ = try sandbox.write("Library/Containers/ABABABAB-1111-2222-3333-444444444444/Data/save.db")
        try PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataInfo": ["MCMMetadataIdentifier": "org.vendor.nested"]],
            format: .binary, options: 0
        ).write(to: nested.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))

        let plan = try await sandbox.planner().plan()

        #expect(plan.groups.contains { $0.id == "org.vendor.nested" })
        let group = try #require(plan.groups.first { $0.id == "it.vendor.pokerclient" })
        #expect(group.items.map(\.url.standardizedFileURL.path) == [gone.standardizedFileURL.path])
        #expect(group.items.first?.isProtectedUserData == true)
        let offered = Set(plan.groups.flatMap(\.items).map(\.url.standardizedFileURL.path))
        for url in [kept, extensionOfKept, apple, silent] {
            #expect(!offered.contains(url.standardizedFileURL.path), "\(url.lastPathComponent)")
        }
    }

    /// A group container's name is whatever its developer chose, so it cannot be
    /// matched to a bundle identifier: Surfshark is `com.surfshark.vpnclient.macos
    /// .direct` and keeps its group at `YHUG37CKN8.com.surfshark.vpn.direct`. Purge
    /// matched by name and offered that, a working VPN's configuration, as a
    /// leftover. What the name does carry is the Team ID, and every installed
    /// application is signed by one.
    @Test("a group container is a leftover only when no installed application is signed by its team")
    func groupContainersFollowTheirTeam() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.application("Surfshark", identifier: "com.surfshark.vpnclient.macos.direct")
        let live = try sandbox.write(
            "Library/Group Containers/YHUG37CKN8.com.surfshark.vpn.direct/config.db"
        ).deletingLastPathComponent()
        let orphan = try sandbox.write(
            "Library/Group Containers/SY64MV22J9.com.raycast.macos.shared/state.db"
        ).deletingLastPathComponent()
        // No team in the name, so nothing says whose it is: never offered.
        let teamless = try sandbox.write(
            "Library/Group Containers/group.com.gone.app/shared.db"
        ).deletingLastPathComponent()
        // A team and a remainder that is not an identifier: not an application's name.
        let odd = try sandbox.write("Library/Group Containers/22MMUN2RN5.lv/blob")
            .deletingLastPathComponent()

        // A Team ID is ten characters. Three capitals and a dot are somebody's name.
        let short = try sandbox.write("Library/Group Containers/ABC.com.vendor.thing/blob")
            .deletingLastPathComponent()

        let plan = try await sandbox.planner(teams: ["Surfshark": "YHUG37CKN8"]).plan()

        let group = try #require(plan.groups.first { $0.id == "com.raycast.macos.shared" })
        #expect(group.items.map(\.url.standardizedFileURL.path) == [orphan.standardizedFileURL.path])
        #expect(group.items.first?.isProtectedUserData == true)
        let offered = Set(plan.groups.flatMap(\.items).map(\.url.standardizedFileURL.path))
        for url in [live, teamless, odd, short] {
            #expect(!offered.contains(url.standardizedFileURL.path), "\(url.lastPathComponent)")
        }
    }

    /// `net.scribus` is a real application's identifier, and it has two parts. The
    /// check wanted three, so Scribus' saved state was nobody's.
    @Test("a two-part identifier is an identifier; a bare word is not")
    func twoPartIdentifiers() async throws {
        let sandbox = try Sandbox()
        let state = try sandbox.evidence(for: "net.scribus")
        _ = try sandbox.evidence(for: "scribus")

        let plan = try await sandbox.planner().plan()

        #expect(plan.groups.map(\.id) == ["net.scribus"])
        #expect(plan.groups.first?.items.map(\.url.standardizedFileURL.path)
            == [state.standardizedFileURL.path])
    }

    /// macOS gives a sandbox container the name of its application — that is why
    /// Finder shows "PokerStars" for `~/Library/Containers/94F36404-…`. It is the
    /// system's name for the folder, not a guess about an application that is gone.
    /// Read off the owner's Mac on 20 Sep 2026, WhatsApp's came back with a
    /// left-to-right mark in front of it.
    @Test("a leftover is named by what macOS calls its container, or not at all")
    func systemNames() {
        let name = OrphanedAppLeftoverPlanner.usableSystemName
        #expect(name("PokerStars", "94F36404-A18D-4D25-934C-60BF64DCB120") == "PokerStars")
        #expect(name("\u{200E}WhatsApp", "net.whatsapp.WhatsApp") == "WhatsApp")
        // No name of its own: the system hands back the folder's.
        #expect(name("352FF1C8-7400-43BF-8E27-9D4C6D56748B", "352FF1C8-7400-43BF-8E27-9D4C6D56748B") == nil)
        #expect(name("net.scribus.savedState", "net.scribus.savedState") == nil)
        #expect(name("11111111-2222-3333-4444-555555555555", "other-folder") == nil)
        #expect(name("  ", "folder") == nil)
    }

    @Test("an installed owner protects its identifier and helper identifiers")
    func installedOwnersAreProtected() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.application("Live", identifier: "com.vendor.live")
        for identifier in ["com.vendor.live", "com.vendor.live.helper", "com.vendor.old"] {
            try sandbox.evidence(for: identifier)
            _ = try sandbox.write("Library/Caches/\(identifier)/blob")
        }

        let plan = try await sandbox.planner().plan()
        let identifiers = Set(plan.groups.map(\.bundleIdentifier))

        #expect(identifiers == ["com.vendor.old"])
    }

    @Test("a registered owner outside the configured roots stays protected")
    func registeredOwnerStaysProtected() async throws {
        let sandbox = try Sandbox()
        try sandbox.evidence(for: "com.vendor.external.helper")
        _ = try sandbox.write("Library/Caches/com.vendor.external.helper/blob")

        let plan = try await sandbox.planner().plan(
            registeredApplicationBundleIdentifiers: ["com.vendor.external"]
        )

        #expect(plan.groups.isEmpty)
    }

    @Test("the scanner groups verified application leftovers under Safe to Remove")
    func scannerGroupsLeftovers() async throws {
        let sandbox = try Sandbox()
        let state = try sandbox.evidence(for: "com.vendor.old")
        let cache = try sandbox.write("Library/Caches/com.vendor.old/blob")
            .deletingLastPathComponent()
        let scanner = ApplicationLeftoversScanner(planner: sandbox.planner())

        let result = try await scanner.scan(context: ScanContext())
        let entry = try #require(result.entries.first)

        #expect(result.categoryID == .applicationLeftovers)
        #expect(entry.orphanedApplicationBundleIdentifier == "com.vendor.old")
        #expect(Set(entry.children.map(\.url)) == [cache, state])
        #expect(entry.displayBytes == result.totalBytes)
        #expect(result.safeToRemoveBytes == result.totalBytes)
        #expect(result.needsReviewBytes == 0)
        #expect(result.filteringNoise(below: Int64.max).entries.count == 1)
    }

    @Test("an unreadable application-data root does not look empty")
    func unreadableRootIsUnavailable() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write("Library/Containers/com.vendor.old/blob")
        let deniedRoot = sandbox.home.appendingPathComponent("Library/Containers")
        let planner = sandbox.planner { url in
            if url.standardizedFileURL == deniedRoot.standardizedFileURL {
                throw CocoaError(.fileReadNoPermission)
            }
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        let scanner = ApplicationLeftoversScanner(planner: planner)

        let result = try await scanner.scan(context: ScanContext())

        #expect(result.entries.isEmpty)
        #expect(result.unreadableCount == 1)
        guard case .unavailable(let reason) = result.availability else {
            Issue.record("The scanner reported an empty category")
            return
        }
        #expect(reason.contains("other application data"))
    }

    @Test("an unreadable candidate does not look absent")
    func unreadableCandidateIsUnavailable() async throws {
        let sandbox = try Sandbox()
        let container = try sandbox.write("Library/Containers/com.vendor.old/blob")
            .deletingLastPathComponent()
        let planner = sandbox.planner { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        } candidatePathStatus: { url in
            url.standardizedFileURL == container.standardizedFileURL
                ? .unreadable
                : (FileManager.default.fileExists(atPath: url.path) ? .present : .missing)
        }
        let scanner = ApplicationLeftoversScanner(planner: planner)

        let result = try await scanner.scan(context: ScanContext())

        #expect(result.entries.isEmpty)
        #expect(result.unreadableCount == 1)
        guard case .unavailable = result.availability else {
            Issue.record("The scanner reported an empty category")
            return
        }
    }

    @Test("a repeated review uses only the leftover paths that remain")
    func repeatedReviewUsesRemainingPaths() async throws {
        let sandbox = try Sandbox()
        try sandbox.evidence(for: "com.vendor.old")
        let cache = try sandbox.write("Library/Caches/com.vendor.old/blob")
            .deletingLastPathComponent()
        _ = try sandbox.write("Library/Preferences/com.vendor.old.plist")
        let plan = try await sandbox.planner().plan()

        let items = plan.items(
            for: ["com.vendor.old"],
            itemPaths: [cache.path]
        )

        #expect(items.map(\.url) == [cache])
    }

    @Test("a curated root needs its exact application rule")
    func curatedRootUsesExactRule() async throws {
        let sandbox = try Sandbox()
        let codeRoot = try sandbox.write(
            "Library/Application Support/Code/User/settings.json"
        ).deletingLastPathComponent().deletingLastPathComponent()

        let orphanPlan = try await sandbox.planner().plan()
        let group = try #require(orphanPlan.groups.first { $0.id == "com.microsoft.VSCode" })
        #expect(group.items.contains { $0.url == codeRoot })

        _ = try sandbox.application("Visual Studio Code", identifier: "com.microsoft.VSCode")
        let installedPlan = try await sandbox.planner().plan()
        #expect(!installedPlan.groups.contains { $0.id == "com.microsoft.VSCode" })
    }

    @Test("exclusions and keychains stay protected")
    func protectedPathsStayOnDisk() async throws {
        let sandbox = try Sandbox()
        let state = try sandbox.evidence(for: "com.vendor.old")
        let cache = try sandbox.write("Library/Caches/com.vendor.old/blob")
            .deletingLastPathComponent()
        let support = try sandbox.write(
            "Library/Application Support/com.vendor.old/Secrets.keychain-db"
        ).deletingLastPathComponent()
        let context = ScanContext(
            excludedPaths: [cache.path, state.path],
            excludedPatterns: ["*.keychain-db"]
        )

        let plan = try await sandbox.planner().plan(context: context)

        #expect(plan.groups.isEmpty)
        #expect(Set(plan.preservedPaths) == [cache, state, support])
    }

    /// The regression behind the rule: `/Library/Preferences/org.cups.printers.plist`
    /// is the user's printer configuration, shaped exactly like a bundle identifier,
    /// and an earlier planner offered it as "safe to delete".
    @Test("a reverse-DNS name in the system library alone is not an application")
    func systemPreferencesAreNotEvidence() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeAbsolute(
            sandbox.systemLibrary.appendingPathComponent("Preferences/org.cups.printers.plist")
        )
        try sandbox.writeAbsolute(
            sandbox.systemLibrary.appendingPathComponent("LaunchAgents/com.vendor.agent.plist")
        )
        // A build tool's cache, named like an app, owned by no app.
        _ = try sandbox.write("Library/Caches/org.swift.swiftpm/manifests")
        _ = try sandbox.write("Library/Preferences/com.vendor.tool.plist")

        let plan = try await sandbox.planner().plan()

        #expect(plan.groups.isEmpty, "none of these ever belonged to an application")
    }

    @Test("application evidence turns the same paths into leftovers")
    func evidenceQualifiesTheIdentifier() async throws {
        let sandbox = try Sandbox()
        let preference = try sandbox.write("Library/Preferences/com.vendor.gone.plist")
        let before = try await sandbox.planner().plan()
        #expect(before.groups.isEmpty)

        // Now macOS has, at some point, saved this identifier's window state.
        let state = try sandbox.evidence(for: "com.vendor.gone")
        let after = try await sandbox.planner().plan()
        let group = try #require(after.groups.first { $0.id == "com.vendor.gone" })
        #expect(Set(group.items.map(\.url)) == [preference, state],
                "once established, its preferences are collected too")
    }

    @Test("the owner walk credits a helper to its installed parent")
    func ownerWalkFindsParent() {
        let registered = OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: ["com.vendor.app.helper", "com.other.gone.helper"],
            running: ["com.running.app"],
            isInstalled: { $0 == "com.vendor.app" }
        )
        #expect(registered == ["com.vendor.app", "com.running.app"])
        // And the planner treats the parent as owning the helper.
        #expect(AppUninstallPlanner.ownerIsInstalled(
            "com.vendor.app.helper", installedBundleIdentifiers: registered
        ))
        #expect(!AppUninstallPlanner.ownerIsInstalled(
            "com.other.gone.helper", installedBundleIdentifiers: registered
        ))
    }

    @Test("a cookie file yields one identifier, not a phantom second one")
    func cookiesAreNotAnIdentifier() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write("Library/HTTPStorages/com.vendor.gone.binarycookies")

        let candidates = sandbox.planner().candidateBundleIdentifiers()

        #expect(candidates == ["com.vendor.gone"])
    }

    @Test("a replacement at a reviewed path fails the identity check")
    func replacementFailsReviewIdentity() async throws {
        let sandbox = try Sandbox()
        try sandbox.evidence(for: "com.vendor.old")
        let cache = try sandbox.write("Library/Caches/com.vendor.old/blob")
            .deletingLastPathComponent()
        let plan = try await sandbox.planner().plan()
        let item = try #require(plan.groups.first?.items.first { $0.url == cache })

        try FileManager.default.removeItem(at: cache)
        _ = try sandbox.write("Library/Caches/com.vendor.old/replacement")

        #expect(!OrphanedAppLeftoverPlan.removalIsStillSafe(
            item, in: plan, installedBundleIdentifiers: []
        ))
    }

    @Test("an application installed after review stops leftover removal")
    func newOwnerStopsRemoval() async throws {
        let sandbox = try Sandbox()
        try sandbox.evidence(for: "com.vendor.old")
        let cacheFile = try sandbox.write("Library/Caches/com.vendor.old/blob")
        let cache = cacheFile.deletingLastPathComponent()
        let plan = try await sandbox.planner().plan()
        _ = try sandbox.application("Old", identifier: "com.vendor.old")

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).removeOrphanedAppLeftovers(
            plan, bundleIdentifiers: ["com.vendor.old"], itemPaths: [cache.path]
        )

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [cache.path])
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test("a newly registered owner outside the configured roots stops removal")
    func newRegisteredOwnerStopsRemoval() async throws {
        let sandbox = try Sandbox()
        try sandbox.evidence(for: "com.vendor.external")
        let cacheFile = try sandbox.write("Library/Caches/com.vendor.external/blob")
        let cache = cacheFile.deletingLastPathComponent()
        let plan = try await sandbox.planner().plan()

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).removeOrphanedAppLeftovers(
            plan,
            bundleIdentifiers: ["com.vendor.external"],
            itemPaths: [cache.path],
            registeredApplicationBundleIdentifiers: ["com.vendor.external"]
        )

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [cache.path])
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }
}
