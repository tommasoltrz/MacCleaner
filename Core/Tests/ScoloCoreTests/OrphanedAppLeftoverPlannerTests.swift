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
                }
        ) -> OrphanedAppLeftoverPlanner {
            OrphanedAppLeftoverPlanner(
                pathPlanner: appPlanner(),
                directoryNames: directoryNames,
                candidatePathStatus: candidatePathStatus
            )
        }
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

        let plan = try await sandbox.planner().plan()

        let group = try #require(plan.groups.first { $0.id == "it.vendor.pokerclient" })
        #expect(group.items.map(\.url.standardizedFileURL.path) == [gone.standardizedFileURL.path])
        #expect(group.items.first?.isProtectedUserData == true)
        let offered = Set(plan.groups.flatMap(\.items).map(\.url.standardizedFileURL.path))
        for url in [kept, extensionOfKept, apple, silent] {
            #expect(!offered.contains(url.standardizedFileURL.path), "\(url.lastPathComponent)")
        }
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

    @Test("the scanner groups application leftovers as rows that need review")
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
        // Whose removal is the user's to decide — see `CategoryID.isSafe`.
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.needsReviewBytes == result.totalBytes)
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
