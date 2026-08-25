import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Application uninstall planning")
struct AppUninstallPlannerTests {

    private final class Sandbox {
        let root: URL
        let home: URL
        let applications: URL
        let userApplications: URL
        let systemLibrary: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("maccleaner-uninstall-\(UUID().uuidString)", isDirectory: true)
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
        func application(
            _ name: String,
            identifier: String,
            under root: URL? = nil
        ) throws -> URL {
            let url = (root ?? applications).appendingPathComponent("\(name).app", isDirectory: true)
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
        func write(_ relativePath: String, bytes: Int = 4_096) throws -> URL {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        func planner() -> AppUninstallPlanner {
            AppUninstallPlanner(
                home: home,
                systemLibrary: systemLibrary,
                applicationRoots: [applications, userApplications],
                darwinCache: nil,
                darwinTemp: nil
            )
        }
    }

    @Test("exact bundle paths are classified without prefix or group-container guesses")
    func exactCandidatesOnly() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let support = try sandbox.write("Library/Application Support/com.vendor.editor/account.db")
            .deletingLastPathComponent()
        let preference = try sandbox.write("Library/Preferences/com.vendor.editor.plist")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.helper.plist")
        let sharedGroup = try sandbox.write(
            "Library/Group Containers/group.com.vendor.editor/shared.db"
        ).deletingLastPathComponent()
        let launchAgent = try sandbox.write("Library/LaunchAgents/com.vendor.editor.plist")

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let paths = Set(plan.items.map(\.id))

        #expect(paths.contains(app.path))
        #expect(paths.contains(cache.path))
        #expect(paths.contains(support.path))
        #expect(paths.contains(preference.path))
        #expect(paths.contains(launchAgent.path))
        #expect(!paths.contains { $0.contains("editor.helper.plist") })
        #expect(!paths.contains { $0.contains("Group Containers") })
        #expect(plan.preservedPaths.contains(sharedGroup))
    }

    @Test("another installed copy keeps every shared bundle-owned path")
    func duplicateApplicationPreservesSharedData() async throws {
        let sandbox = try Sandbox()
        let selected = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.application("Editor Copy", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.plist")

        let plan = try await sandbox.planner().plan(applicationURL: selected)

        #expect(plan.items.map(\.id) == [selected.path])
    }

    @Test("Homebrew ownership requires one exact app artifact target")
    func homebrewOwnershipIsExact() throws {
        let data = Data(#"""
        {
          "casks": [
            {
              "token": "editor",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications/Editor.app" }
              ]
            },
            {
              "token": "editor-beta",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications Beta/Editor.app" }
              ]
            }
          ]
        }
        """#.utf8)

        let package = try #require(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Editor.app"),
            executable: "/opt/homebrew/bin/brew"
        ))

        #expect(package.name == "editor")
        #expect(package.manager == .homebrew)
        #expect(package.uninstallCommand
            == "/opt/homebrew/bin/brew uninstall --cask editor")
        #expect(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Other.app"),
            executable: "/opt/homebrew/bin/brew"
        ) == nil)
    }

    @Test("an embedded helper contributes only its exact identifier")
    func embeddedHelperIdentifiers() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let helpers = app.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        _ = try sandbox.application(
            "Background", identifier: "com.vendor.editor.background", under: helpers
        )
        let helperCache = try sandbox.write("Library/Caches/com.vendor.editor.background/blob")
            .deletingLastPathComponent()
        _ = try sandbox.write("Library/Caches/com.unrelated.helper/blob")

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(plan.items.contains { $0.url == helperCache })
        #expect(!plan.items.contains { $0.url.path.contains("com.unrelated.helper") })
    }

    @Test("known nonstandard Electron roots split caches from profiles")
    func knownCurationIsSharedWithTheScanner() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Visual Studio Code", identifier: "com.microsoft.VSCode")
        let cache = try sandbox.write("Library/Application Support/Code/Code Cache/index")
            .deletingLastPathComponent()
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        _ = try sandbox.write("Library/Application Support/Code/User/settings.json")

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let cacheItem = try #require(plan.items.first { $0.url == cache })
        let remainder = try #require(plan.items.first {
            $0.url == support && $0.content == .userData
        })

        #expect(cacheItem.content == .regenerable)
        #expect(remainder.displayName == "Visual Studio Code settings and data")

        // Moving the real support root necessarily carries anything nested inside
        // it. The plan moves the child first so both rows receive honest receipts.
        let order = plan.removalOrder()
        let cacheIndex = try #require(order.firstIndex(of: cacheItem))
        let remainderIndex = try #require(order.firstIndex(of: remainder))
        #expect(cacheIndex < remainderIndex)
    }

    @Test("an excluded related path is preserved and disclosed")
    func exclusionsRemainAbsolute() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let context = ScanContext(excludedPaths: [cache.path])

        let plan = try await sandbox.planner().plan(applicationURL: app, context: context)

        #expect(!plan.items.contains { $0.url == cache })
        #expect(plan.preservedPaths == [cache])
    }

    @Test("the app bundle is always first, before protected data")
    func removalOrderStartsWithApplication() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Application Support/com.vendor.editor/profile.db")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        let plan = try await sandbox.planner().plan(applicationURL: app)

        let order = plan.removalOrder()

        #expect(order.first?.url == app)
        #expect(order.dropFirst().contains { $0.content == .userData })
    }

    @Test("a replacement at a reviewed path is refused by filesystem identity")
    func replacementPathIsNotTheReviewedItem() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/old")
            .deletingLastPathComponent()
        let plan = try await sandbox.planner().plan(applicationURL: app)
        let item = try #require(plan.items.first { $0.url == cache })

        try FileManager.default.removeItem(at: cache)
        _ = try sandbox.write("Library/Caches/com.vendor.editor/replacement")
        let exclusive = AppUninstallPlanner.exclusiveBundleIdentifiers(
            candidates: plan.candidateBundleIdentifiers,
            selectedApplication: plan.applicationURL,
            applicationRoots: plan.applicationRoots
        )

        #expect(!AppUninstallPlanner.removalIsStillSafe(
            item, in: plan, exclusiveBundleIdentifiers: exclusive
        ))
    }

    @Test("a changed app bundle stops the uninstall before related data")
    func applicationFailureIsATransactionGate() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let supportFile = try sandbox.write(
            "Library/Application Support/com.vendor.editor/profile.db"
        )
        let plan = try await sandbox.planner().plan(applicationURL: app)

        // Replace the reviewed bundle at the same path. The location still looks
        // right, but it is no longer the filesystem object the user reviewed.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("reviewed-bundle")
        )
        _ = try sandbox.application("Editor", identifier: "com.vendor.editor")

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [app.path])
        #expect(FileManager.default.fileExists(atPath: supportFile.path))
    }

    @Test("a failed child cannot be carried away by its containing parent")
    func changedChildProtectsItsContainingFolder() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application(
            "Visual Studio Code", identifier: "com.microsoft.VSCode"
        )
        let cache = try sandbox.write(
            "Library/Application Support/Code/Code Cache/index"
        ).deletingLastPathComponent()
        let settings = try sandbox.write(
            "Library/Application Support/Code/User/settings.json"
        )
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        let plan = try await sandbox.planner().plan(applicationURL: app)
        #expect(plan.items.contains {
            $0.url == support && $0.content == .userData
        })

        // A missing app already satisfies the requested app-removal state, but a
        // replacement inside the reviewed support tree is a different object and
        // must survive even when the containing remainder is part of the plan.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("already-removed-app")
        )
        try FileManager.default.moveItem(
            at: cache, to: sandbox.root.appendingPathComponent("reviewed-cache")
        )
        let replacement = try sandbox.write(
            "Library/Application Support/Code/Code Cache/replacement"
        )

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed.contains(cache.path))
        #expect(outcome.failed.contains(support.path))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }

    @Test("system identifiers and symbolic-link applications are refused")
    func protectedAndSymbolicApplicationsAreRefused() async throws {
        let sandbox = try Sandbox()
        let system = try sandbox.application("System", identifier: "com.apple.systemtool")
        await #expect(throws: AppUninstallPlanningError.protectedApplication) {
            _ = try await sandbox.planner().plan(applicationURL: system)
        }

        let real = try sandbox.application("Real", identifier: "com.vendor.real")
        let link = sandbox.applications.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: AppUninstallPlanningError.symbolicLink) {
            _ = try await sandbox.planner().plan(applicationURL: link)
        }
    }
}
